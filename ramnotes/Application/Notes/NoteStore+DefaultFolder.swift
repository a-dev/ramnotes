import ramnotesDomain
import Foundation

/// Holds the destination folder grant until editors and metadata finish flushing.
/// Publishes nothing and does not change the catalog.
struct PreparedDefaultFolderChange: Sendable {
    struct Member: Sendable {
        let id: NoteID
        let path: String
        let revision: LocationRevision
        let parentResource: String?
    }
    let token: CollectionToken
    let previousDecision: UUID
    let oldFolder: URL?
    let oldResource: String?
    let destination: any FolderGrant
    let destinationResource: String
    let members: [Member]
    let moveExisting: Bool
    let unchanged: Bool
}

private struct DefaultFolderFilenameCandidates {
    private let original: String
    private let stem: String
    private let ext: String
    private var suffix = 1

    init(original: String) {
        self.original = original
        self.stem = String(original.dropLast(4))
        self.ext = String(original.suffix(4))
    }

    mutating func next() -> String {
        defer { suffix += 1 }
        return suffix == 1 ? original : "\(stem) (\(suffix))\(ext)"
    }
}

extension NoteStore {
    func prepareDefaultFolder(to requested: URL, moveExisting: Bool,
                              from token: CollectionToken) throws -> PreparedDefaultFolderChange {
        try validate(token)
        try Task.checkCancellation()
        try fault(.folderAccess)
        let acquired = try folderAccess.acquire(requested)
        let resource = try StorageFiles.resourceID(acquired.url)
        let unchanged = folder.map { Self.sameDirectory($0, acquired.url) } ?? false
        // A read failure must stop here, not look like an empty folder.
        // Read only the folder's own note files.
        if !unchanged { _ = try FolderScanner.candidates(in: acquired.url) { try Task.checkCancellation() } }
        let members = identities.mapping.filter { location in
            guard let folder, location.parentResource == activeFolderIdentity else { return false }
            return Self.sameDirectory(URL(fileURLWithPath: location.path).deletingLastPathComponent(), folder)
        }.sorted { $0.path == $1.path ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.path < $1.path }
        try fault(.defaultPrepared)
        return PreparedDefaultFolderChange(token: token, previousDecision: identities.catalog.defaultDecision,
            oldFolder: folder, oldResource: activeFolderIdentity,
            destination: PreparedFolderGrant(lease: acquired, descriptor: try folderAccess.descriptor(for: acquired)), destinationResource: resource,
            members: members.map { .init(id: $0.id, path: $0.path, revision: $0.revision, parentResource: $0.parentResource) }, moveExisting: moveExisting, unchanged: unchanged)
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    func changeDefaultFolder(to requested: URL, moveExisting: Bool,
                             from token: CollectionToken) throws -> DefaultFolderChangeResult {
        let prepared = try prepareDefaultFolder(to: requested, moveExisting: moveExisting, from: token)
        return try commitDefaultFolder(prepared)
    }

    /// Runs in one actor turn, so no other move can interleave. Quit waits for it.
    /// Checks cancellation before the commit and between files.
    func commitDefaultFolder(_ prepared: PreparedDefaultFolderChange) throws -> DefaultFolderChangeResult {
        try validate(prepared.token)
        guard let destination = prepared.destination as? PreparedFolderGrant else { throw NoteOperationError.unavailable }
        guard identities.catalog.defaultDecision == prepared.previousDecision,
              folder == prepared.oldFolder else { throw NoteOperationError.staleLocation }
        if prepared.unchanged {
            return DefaultFolderChangeResult(batch: nil, folder: prepared.destination.url, collectionToken: collectionToken)
        }
        try Task.checkCancellation()
        try flush()
        guard unfinishedLocationOperations().isEmpty else { throw NoteOperationError.locationOperationPending }
        guard try StorageFiles.resourceID(prepared.destination.url) == prepared.destinationResource else { throw NoteOperationError.unavailable }
        let destinationScan = try scanner.run(prepared.destination.url, identities: identities, cache: bodyCache,
            collectionToken: collectionToken, custom: [], check: { try Task.checkCancellation() })
        // The scanner keeps unreadable entries. Require the folder listing to succeed
        // both before and after the editors flush.
        _ = try FolderScanner.candidates(in: prepared.destination.url) { try Task.checkCancellation() }
        var catalog = identities.catalog
        let oldAccess = try lease.map { try folderAccess.descriptor(for: $0) }
        var entries: [DefaultFolderBatch.Entry] = []
        var reserved = Set(try StorageFiles.childNames(prepared.destination.url).map { $0.lowercased() })
        for captured in prepared.members {
            // A flush can replace the file atomically. It must not move the note
            // or change its location revision.
            guard var current = identities.identity(captured.id), current.path == captured.path,
                  current.revision == captured.revision,
                  current.parentResource == captured.parentResource else { throw NoteOperationError.staleLocation }
            if let oldAccess { current.access = oldAccess }
            catalog.notes[current.id] = current
            if prepared.moveExisting {
                let original = URL(fileURLWithPath: current.path).lastPathComponent
                var candidates = DefaultFolderFilenameCandidates(original: original)
                var name = candidates.next()
                while reserved.contains(name.lowercased()) {
                    name = candidates.next()
                }
                reserved.insert(name.lowercased())
                entries.append(DefaultFolderBatch.Entry(source: current,
                    destination: prepared.destination.url.appendingPathComponent(name)))
            }
        }
        // Add every note found in the new folder. Custom and old-default notes stay
        // tracked on disk even if no move starts.
        for var location in destinationScan.discovery.mapping {
            if let previous = identities.identity(location.id), previous.path != location.path,
               let resource = location.resource, previous.resource == resource,
               (try? StorageFiles.fileResourceID(URL(fileURLWithPath: previous.path))) == resource {
                throw NoteOperationError.conflict
            }
            if location.fileAccess == nil || location.fileAccess?.url.path != location.path {
                let url = URL(fileURLWithPath: location.path)
                location.fileAccess = NoteAccessDescriptor(url: url, bookmark: try folderAccess.hooks.bookmark(url), scope: .file)
            }
            catalog.notes[location.id] = location
        }
        let batch = DefaultFolderBatch(id: UUID(), decision: UUID(), sourceFolder: prepared.oldFolder ?? folderAccess.defaultURL,
            sourceResource: prepared.oldResource, destination: destination.descriptor,
            destinationResource: prepared.destinationResource, moveExisting: prepared.moveExisting,
            state: prepared.moveExisting ? .running : .settled, entries: entries)
        catalog.defaultFolder = destination.descriptor
        catalog.defaultDecision = batch.decision
        catalog.defaultBatches[batch.id] = batch
        try Task.checkCancellation()
        // One atomic catalog write saves the new folder and every note to move.
        try fault(.defaultCommit)
        try CatalogPersistence.save(catalog, at: folderAccess.selectionURL)
        installCatalog(catalog)
        if let lease {
            for member in prepared.members where !accessLeases[member.id, default: []].contains(where: { $0 === lease }) {
                accessLeases[member.id, default: []].append(lease)
            }
        }
        lease = destination.lease
        folder = prepared.destination.url
        activeFolderIdentity = prepared.destinationResource
        defaultAccessFailure = nil
        for var note in destinationScan.snapshots {
            note.editRevision = session.completions[note.id]?.revision ?? EditRevision(rawValue: 0)
            let existing = records[note.id] != nil
            records[note.id] = note
            session.knownLocations[note.id] = note.fileURL
            emit(existing ? .changed(note) : .discovered(note))
        }
        startObserving()
        var interruption: NoteOperationError?
        do {
            try fault(.defaultCommitted)
            try runDefaultBatch(batch.id, retryFailures: false)
        } catch {
            // The new default is already saved. Return the batch with the error. Don't fail
            // as if the old folder were still the default.
            if error is CancellationError, var paused = identities.catalog.defaultBatches[batch.id] {
                paused.state = .paused
                try? persistDefaultBatch(paused)
            }
            let failure: NoteOperationError = error is CancellationError ? .cancelled : NoteFailureMapping.operationError(error)
            interruption = failure
            emit(.failed(nil, failure))
        }
        return DefaultFolderChangeResult(batch: identities.catalog.defaultBatches[batch.id]?.applicationResult,
            folder: prepared.destination.url, collectionToken: collectionToken, error: interruption)
    }

    func retryableDefaultFolderBatch() -> DefaultFolderResultBatch? {
        identities.catalog.defaultBatches.values.first { $0.decision == identities.catalog.defaultDecision && $0.entries.contains { $0.state != .moved } }?.applicationResult
    }

    func defaultFolderBatches() -> [DefaultFolderResultBatch] {
        identities.catalog.defaultBatches.values.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.applicationResult)
    }

    private func persistDefaultBatch(_ batch: DefaultFolderBatch) throws {
        try checkpointMemoryCatalog { $0.defaultBatches[batch.id] = batch }
    }

    func retryDefaultFolderChange(_ id: UUID, from token: CollectionToken) throws -> DefaultFolderChangeResult {
        try validate(token)
        guard let batch = identities.catalog.defaultBatches[id], batch.decision == identities.catalog.defaultDecision,
              let folder else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("The default folder changed again. Choose a destination for the remaining notes.", comment: "Error when the default folder changed during a move of notes"))
        }
        guard session.writing.isEmpty else { throw NoteOperationError.unavailable }
        var interruption: NoteOperationError?
        do { try runDefaultBatch(id, retryFailures: true) }
        catch {
            let failure: NoteOperationError = error is CancellationError ? .cancelled : NoteFailureMapping.operationError(error)
            interruption = failure
            if error is CancellationError, var paused = identities.catalog.defaultBatches[id] {
                paused.state = .paused
                try? persistDefaultBatch(paused)
            }
            emit(.failed(nil, failure))
        }
        return DefaultFolderChangeResult(batch: identities.catalog.defaultBatches[id]?.applicationResult, folder: folder, collectionToken: token, error: interruption)
    }

    private func runDefaultBatch(_ id: UUID, retryFailures: Bool) throws {
        guard var batch = identities.catalog.defaultBatches[id], batch.decision == identities.catalog.defaultDecision else { return }
        if !retryFailures, batch.state != .running { return }
        let (destinationLease, renewed) = try folderAccess.restore(batch.destination)
        guard try StorageFiles.resourceID(destinationLease.url) == batch.destinationResource else { throw NoteOperationError.unavailable }
        batch.destination = renewed
        for index in batch.entries.indices where batch.entries[index].state != .moved {
            batch.entries[index].destination = destinationLease.url.appendingPathComponent(batch.entries[index].destination.lastPathComponent)
        }
        batch.state = .running
        try persistDefaultBatch(batch)
        for index in batch.entries.indices {
            if batch.entries[index].state == .moved { continue }
            if batch.entries[index].state == .failed && !retryFailures { continue }
            if Task.isCancelled {
                batch.state = .paused
                try persistDefaultBatch(batch)
                return
            }
            var entry = batch.entries[index]
            // The app can stop after a note's move is saved but before the batch is.
            // Find the saved operation. Never assume success because the text matches.
            let operation = identities.catalog.operations.values.first {
                ($0.stage != .complete || $0.destinationResource != nil) &&
                $0.noteID == entry.source.id && $0.source.path == entry.source.path &&
                $0.source.revision == entry.source.revision && $0.destinationName == entry.destination.lastPathComponent &&
                $0.destinationParentResource == batch.destinationResource
            }
            do {
                let result: NoteMoveResult
                if let operation {
                    batch.entries[index].operationID = operation.id
                    if operation.stage == .complete {
                        // The saved operation proves the move finished. Later saves or moves
                        // may change the file, but never repeat a finished move.
                        let current = identities.identity(entry.source.id) ?? operation.source
                        result = NoteMoveResult(noteID: current.id, location: current.applicationLocation, outcome: .moved)
                    } else if operation.stage != .complete {
                        result = try retryLocationOperation(operation.id)
                    } else { throw NoteOperationError.conflict }
                } else {
                    guard let current = identities.identity(entry.source.id), current.path == entry.source.path,
                          current.revision == entry.source.revision,
                          current.parentResource == batch.sourceResource,
                          Self.sameDirectory(URL(fileURLWithPath: current.path).deletingLastPathComponent(), batch.sourceFolder) else {
                        throw NoteOperationError.staleLocation
                    }
                    // A new file can take a reserved name after the commit. Save a new
                    // suffix before retrying. Exclusive create still guards the last race.
                    if StorageFiles.exists(entry.destination) {
                        let original = URL(fileURLWithPath: entry.source.path).lastPathComponent
                        var candidates = DefaultFolderFilenameCandidates(original: original)
                        let reserved = Set(batch.entries.enumerated().filter { $0.offset != index }.map { $0.element.destination.lastPathComponent.lowercased() })
                        var name = candidates.next()
                        while reserved.contains(name.lowercased()) || StorageFiles.exists(destinationLease.url.appendingPathComponent(name)) {
                            name = candidates.next()
                        }
                        entry.destination = destinationLease.url.appendingPathComponent(name)
                        batch.entries[index].destination = entry.destination
                        batch.entries[index].operationID = nil
                        try persistDefaultBatch(batch)
                    }
                    try flush(current.id)
                    try fault(.defaultEntry)
                    result = moveNote(current.id, to: entry.destination, collectionToken: collectionToken,
                        locationRevision: current.revision, editRevision: session.completions[current.id]?.revision ?? EditRevision(rawValue: 0))
                }
                switch result.outcome {
                case .moved, .unchanged:
                    batch.entries[index].state = .moved
                    batch.entries[index].message = nil
                    // A resumed move can have newer journaled edits. If this flush fails,
                    // the note shows a save error. The move does not repeat.
                    try? flush(result.noteID)
                case let .failed(error):
                    batch.entries[index].state = .failed
                    batch.entries[index].message = error.localizedDescription
                case let .interrupted(operationID):
                    batch.entries[index].state = .failed
                    batch.entries[index].operationID = operationID
                    batch.entries[index].message = result.error?.localizedDescription ?? String(localized: "The move needs retry or review.", comment: "Reason shown for a note whose default-folder move was interrupted and must be retried")
                }
            } catch {
                batch.entries[index].state = .failed
                batch.entries[index].message = error.localizedDescription
            }
            try fault(.defaultAfterMove)
            try persistDefaultBatch(batch)
            try fault(.defaultCheckpoint)
        }
        batch.state = Task.isCancelled && batch.entries.contains { $0.state != .moved } ? .paused : .settled
        try persistDefaultBatch(batch)
        try fault(.defaultComplete)
    }

    func resumeDefaultFolderChanges() -> [String] {
        var diagnostics: [String] = []
        // Resume only running batches from the current default. Failed or cancelled
        // batches wait for Retry.
        for batch in identities.catalog.defaultBatches.values where batch.state == .running && batch.decision == identities.catalog.defaultDecision {
            do { try runDefaultBatch(batch.id, retryFailures: false) }
            catch { diagnostics.append(String(localized: "Default folder change \(batch.id.uuidString) needs retry: \(error.localizedDescription)", comment: "Diagnostic in the note list. The first value is an internal change identifier, the second is the system error")) }
        }
        return diagnostics
    }
}

extension NoteStore: DefaultFolderChanging {}
