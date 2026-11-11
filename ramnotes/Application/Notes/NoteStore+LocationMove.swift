import ramnotesDomain
import Foundation
import os


private extension LocationOperation {
    var domainState: LocationOperationState {
        LocationOperationState(noteID: noteID, sourceID: source.id, sourceResource: source.resource,
            sourceParentResource: source.parentResource, expectedFileRevision: expectedFileRevision,
            destinationParentResource: destinationParentResource, destinationName: destinationName,
            stage: stage, destinationResource: destinationResource)
    }

    func validateForExecution() throws {
        do { try domainState.validateForExecution() }
        catch { throw NoteOperationError.inputOutput(LocalizedStringResource("The interrupted location operation lacks verified identity or revision evidence. Its record was preserved for review.", comment: "Error when an unfinished move cannot be proven safe to resume")) }
    }

    mutating func transition(_ change: (inout LocationOperationState) throws -> Void) throws {
        var state = domainState
        do { try change(&state) }
        catch LocationOperationState.Failure.missingEvidence {
            throw NoteOperationError.inputOutput(LocalizedStringResource("The interrupted location operation lacks verified identity or revision evidence. Its record was preserved for review.", comment: "Error when an unfinished move cannot be proven safe to resume"))
        } catch { throw NoteOperationError.conflict }
        stage = state.stage
        destinationResource = state.destinationResource
    }
}

extension NoteStore {
    /// Runs as one storage transaction. First the caller ends composition, flushes the
    /// editor under its own lock, and then passes the edit revision.
    func moveNote(_ id: NoteID, to destination: URL, collectionToken token: CollectionToken,
                  locationRevision: LocationRevision, editRevision: EditRevision) -> NoteMoveResult {
        let fallback = identities.identity(id) ?? NoteLocationRecord(id: id, resource: nil, path: destination.path)
        var intent: LocationOperation?
        var filesystemWorkStarted = false
        do {
            try validate(token)
            guard identities.identity(id)?.revision == locationRevision else { throw NoteOperationError.staleLocation }
            try requireNoLocationOperation(id)
            try Task.checkCancellation()
            try flush(id)
            guard (session.completions[id]?.revision ?? EditRevision(rawValue: 0)) == editRevision,
                  let note = records[id], note.availability == .available,
                  let source = identities.identity(id), source.revision == locationRevision else { throw NoteOperationError.conflict }
            guard NoteFilename(destination.lastPathComponent) != nil else { throw NoteOperationError.invalidFilename }
            // Default-folder batches retain folder grants; a Save panel grants only its selected file.
            let parent: FolderLease
            let destinationAccess: NoteAccessDescriptor
            if let folder = try? folderAccess.acquire(destination.deletingLastPathComponent()) {
                parent = folder
                destinationAccess = try folderAccess.descriptor(for: folder)
            } else {
                parent = try folderAccess.acquireDestinationFile(destination)
                // macOS cannot bookmark a file until it exists. Keep the live Save panel
                // grant through creation, then checkpoint its bookmark before source removal.
                destinationAccess = NoteAccessDescriptor(url: parent.url, bookmark: nil, scope: .file)
            }
            let target = destination.standardizedFileURL
            let parentURL = target.deletingLastPathComponent()
            let origin = URL(fileURLWithPath: source.path)
            try verifyLocationSource(source, revision: note.fileRevision)
            let sameResource = (try? StorageFiles.fileResourceID(target)) == source.resource
            if sameResource && origin.lastPathComponent == target.lastPathComponent && origin.deletingLastPathComponent().resolvingSymlinksInPath() == target.deletingLastPathComponent().resolvingSymlinksInPath() {
                return NoteMoveResult(noteID: id, location: source.applicationLocation, outcome: .unchanged)
            }
            if StorageFiles.exists(target), !sameResource { throw NoteOperationError.destinationOccupied }
            // The same file under another folder entry is a hard link, not a rename.
            if sameResource, origin.deletingLastPathComponent().resolvingSymlinksInPath() != target.deletingLastPathComponent().resolvingSymlinksInPath() {
                throw NoteOperationError.destinationOccupied
            }
            // File-only moves copy first so the source survives until a destination
            // bookmark is durable, including a crash immediately after creation.
            let crossVolume = try destinationAccess.scope == .file || StorageFiles.volume(origin) != StorageFiles.volume(parentURL)
            var operation = LocationOperation(id: UUID(), noteID: id, source: source,
                destination: destinationAccess, expectedEditRevision: editRevision, stage: .prepared,
                expectedFileRevision: note.fileRevision, destinationParentResource: try StorageFiles.resourceID(parentURL),
                crossVolume: crossVolume, destinationName: target.lastPathComponent)
            try persistLocationOperation(operation)
            intent = operation
            try fault(.movePrepared)
            try Task.checkCancellation()
            filesystemWorkStarted = true
            try performLocationOperation(&operation, parent: parent)
            return NoteMoveResult(noteID: id, location: (identities.identity(id)!).applicationLocation, outcome: .moved)
        } catch {
            let failure: NoteOperationError = error is CancellationError ? .cancelled : NoteFailureMapping.operationError(error)
            Log.move.error("move failed note=\(id.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            if var intent {
                if error is CancellationError, !filesystemWorkStarted,
                   identities.catalog.operations[intent.id]?.stage == .prepared,
                   (try? verifyLocationSource(intent.source, revision: intent.expectedFileRevision)) != nil {
                    if (try? intent.transition { try $0.abandonPrepared() }) != nil,
                       (try? persistLocationOperation(intent)) != nil {
                        return NoteMoveResult(noteID: id, location: intent.source.applicationLocation, outcome: .failed(.cancelled))
                    }
                }
                if NoteFailureMapping.operationError(error) == .destinationOccupied,
                   identities.catalog.operations[intent.id]?.stage == .prepared,
                   (try? verifyLocationSource(intent.source, revision: intent.expectedFileRevision)) != nil {
                    if (try? intent.transition { try $0.abandonPrepared() }) != nil,
                       (try? persistLocationOperation(intent)) != nil {
                        return NoteMoveResult(noteID: id, location: intent.source.applicationLocation, outcome: .failed(.destinationOccupied))
                    }
                }
                // The source may have moved already. Report an interruption, not an untouched source.
                return NoteMoveResult(noteID: id, location: (identities.identity(id) ?? fallback).applicationLocation, outcome: .interrupted(intent.id), error: failure)
            }
            return NoteMoveResult(noteID: id, location: fallback.applicationLocation, outcome: .failed(failure))
        }
    }

    func requireNoLocationOperation(_ id: NoteID) throws {
        guard !unfinishedLocationOperations().contains(where: { $0.noteID == id }) else {
            throw NoteOperationError.locationOperationPending
        }
    }

    func unfinishedLocationOperations() -> [LocationOperation] {
        identities.catalog.operations.values.filter { $0.stage != .complete }
    }

    private func persistLocationOperation(_ operation: LocationOperation, location: NoteLocationRecord? = nil) throws {
        try checkpointDiskCatalog { catalog in
            if let location { catalog.notes[location.id] = location }
            catalog.operations[operation.id] = operation
        }
    }

    func verifyLocationSource(_ source: NoteLocationRecord, revision: FileRevision?) throws {
        try LocationFiles.verifySource(source, revision: revision)
    }

    /// Keeps both access scopes open from the copy through the presenter update.
    private func performLocationOperation(_ operation: inout LocationOperation, parent: FolderLease) throws {
        try operation.validateForExecution()
        let (stage, opID, noteID) = (String(describing: operation.stage), operation.id.uuidString, operation.noteID.rawValue)
        Log.move.notice("move stage=\(stage, privacy: .public) op=\(opID, privacy: .public) note=\(noteID, privacy: .public)")
        let parentURL = operation.destination.scope == .file ? parent.url.deletingLastPathComponent() : parent.url
        guard let name = operation.destinationName,
              try StorageFiles.resourceID(parentURL) == operation.destinationParentResource else { throw NoteOperationError.unavailable }
        guard NoteFilename(name) != nil else { throw NoteOperationError.invalidFilename }
        let source = URL(fileURLWithPath: operation.source.path)
        let target = parentURL.appendingPathComponent(name)
        if operation.stage == .prepared || operation.stage == .destinationVerified {
            try LocationFiles.coordinate(source: source, target: target,
                presenter: fileObservers[operation.noteID] ?? observer) { from, to, coordinator in
                guard try StorageFiles.resourceID(to.deletingLastPathComponent()) == operation.destinationParentResource else { throw NoteOperationError.unavailable }
                if operation.stage == .prepared {
                    let resource = try LocationFiles.createDestination(operation, from: from, to: to,
                        coordinator: coordinator, fault: fault)
                    if operation.destination.scope == .file {
                        let file = try folderAccess.acquireFile(to)
                        operation.destination = try folderAccess.descriptor(for: file, scope: .file)
                    }
                    try operation.transition { try $0.verifyDestination(resource) }
                    try persistLocationOperation(operation)
                    try fault(.moveVerified)
                }
                if operation.stage == .destinationVerified {
                    try LocationFiles.removeSource(operation, from: from, to: to,
                        coordinator: coordinator,
                        syncParentDirectory: operation.source.access != nil ||
                            source.deletingLastPathComponent() == folderAccess.defaultURL ||
                            source.deletingLastPathComponent() == lease?.url,
                        fault: fault)
                    try operation.transition { try $0.advance(to: .sourceRemoved) }
                    try persistLocationOperation(operation)
                    try fault(.moveSourceRemoved)
                }
            }
        }
        try LocationFiles.verifyDestination(operation, at: target)
        let file = try folderAccess.acquireFile(target)
        var location = operation.source
        location.path = target.path
        location.resource = operation.destinationResource
        location.parentResource = operation.destinationParentResource
        location.access = operation.destination.scope == .file ? nil : try folderAccess.descriptor(for: parent)
        location.fileAccess = try folderAccess.descriptor(for: file, scope: .file)
        location.availability = .available
        location.revision = operation.source.revision.advanced()
        if operation.stage == .sourceRemoved {
            try fault(.moveCatalog)
            try operation.transition { try $0.advance(to: .catalogCommitted) }
            try persistLocationOperation(operation, location: location)
        }
        // The user can keep typing after an interrupted move unlocks the UI.
        // Move the journal and the latest pending edit to the new location.
        if let prior = recovery.load().records.first(where: { $0.noteID == location.id && !$0.trackingRemoved }) {
            let rebound = RecoveryRecord(id: prior.id, noteID: prior.noteID, collectionToken: collectionToken,
                originalURL: target, folderIdentity: location.parentResource, originalResourceIdentity: location.resource,
                baseRevision: prior.baseRevision, editRevision: prior.editRevision, text: prior.text,
                createdAt: prior.createdAt, reason: prior.reason, promotedNoteID: prior.promotedNoteID)
            try persistJournal(rebound)
            session.journalRecords[location.id] = rebound
        }
        if let edit = pending[location.id] {
            pending[location.id] = EditSnapshot(id: edit.id, collectionToken: collectionToken, revision: edit.revision,
                baseRevision: edit.baseRevision, text: edit.text, locationRevision: location.revision)
        }
        accessLeases[location.id] = [parent, file]
        if folder != nil {
            var note = snapshot(id: location.id, url: target, collectionToken: collectionToken)
            note.editRevision = session.completions[location.id]?.revision ?? operation.expectedEditRevision
            records[location.id] = note
            session.knownLocations[location.id] = target
            bodyCache[source.path] = nil
            startObserving()
            emit(.changed(note))
        }
        try fault(.moveComplete)
        try operation.transition { try $0.advance(to: .complete) }
        try persistLocationOperation(operation)
        if let edit = pending[location.id] { schedule(edit, delay: timing.saveDebounce) }
    }

    /// Runs before discovery, so a renamed original never gets a second NoteID.
    /// Unverified copies stay visible as interrupted moves. Matching text never allows cleanup.
    func reconcileLocationOperations() -> [LocalizedStringResource] {
        var diagnostics: [LocalizedStringResource] = []
        for var operation in unfinishedLocationOperations() {
            do {
                var retained = accessLeases[operation.noteID] ?? []
                if operation.stage == .prepared || operation.stage == .destinationVerified,
                   let access = operation.source.access {
                    let (sourceLease, _) = try folderAccess.restore(access)
                    retained.append(sourceLease)
                }
                if let access = operation.source.fileAccess, let restored = try? folderAccess.restore(access) { retained.append(restored.0) }
                let (parent, _) = try folderAccess.restore(operation.destination)
                retained.append(parent)
                accessLeases[operation.noteID] = retained
                try performLocationOperation(&operation, parent: parent)
            } catch {
                let id = operation.id.uuidString, reason = error.localizedDescription
                Log.move.error("resume failed op=\(id, privacy: .public) note=\(operation.noteID.rawValue, privacy: .public) stage=\(String(describing: operation.stage), privacy: .public) error=\(reason, privacy: .private)")
                diagnostics.append(LocalizedStringResource("Location operation \(id) needs retry or review: \(reason)", comment: "Value 1 is an operation ID, value 2 is the system error"))
            }
        }
        return diagnostics
    }

    func retryLocationOperation(_ operationID: UUID) throws -> NoteMoveResult {
        guard var operation = identities.catalog.operations[operationID], operation.stage != .complete else { throw NoteOperationError.unavailable }
        let (parent, _) = try folderAccess.restore(operation.destination)
        do {
            try performLocationOperation(&operation, parent: parent)
            return NoteMoveResult(noteID: operation.noteID, location: (identities.identity(operation.noteID)!).applicationLocation, outcome: .moved)
        } catch {
            Log.move.error("retry failed op=\(operationID.uuidString, privacy: .public) note=\(operation.noteID.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return NoteMoveResult(noteID: operation.noteID, location: (identities.identity(operation.noteID) ?? operation.source).applicationLocation, outcome: .interrupted(operationID), error: NoteFailureMapping.operationError(error))
        }
    }
}
