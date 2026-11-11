import ramnotesDomain
import Foundation
import os

extension NoteStore {
    func status(_ id: NoteID) -> StorageSaveStatus? { statuses[id] }
    func hasPendingEdits() -> Bool { !pending.isEmpty }

    /// Journals at once, or within `timing.journalDebounce` while typing fast. Writes the
    /// note file after `timing.saveDebounce`.
    @discardableResult
    func submit(_ edit: EditSnapshot) -> StorageSaveStatus {
        do {
            try validate(edit.collectionToken)
            try validateLocation(edit)
            guard let note = knownNote(edit.id) else { throw NoteOperationError.unavailable }
            guard edit.revision > (session.completions[edit.id]?.revision ?? EditRevision(rawValue: 0)),
                  edit.revision >= (pending[edit.id]?.revision ?? EditRevision(rawValue: 0)) else {
                return statuses[edit.id] ?? .saved(session.completions[edit.id]?.revision ?? edit.revision)
            }
            pending[edit.id] = edit
            let record = journal(for: edit, url: note.fileURL)
            session.journalRecords[edit.id] = record
            do {
                try persistTypingJournal(record)
                setStatus(edit.id, .pending(edit.revision))
            } catch { setStatus(edit.id, .failed(edit.revision, NoteFailureMapping.operationError(error), journaled: false)) }
            schedule(edit, delay: timing.saveDebounce)
        } catch { return .failed(edit.revision, NoteFailureMapping.operationError(error), journaled: false) }
        return statuses[edit.id]!
    }

    func journal(for edit: EditSnapshot, url: URL, verifiedRelocation: Bool = false) -> RecoveryRecord {
        RecoveryPolicy.journal(for: edit, url: url, prior: session.journalRecords[edit.id],
            folderIdentity: identities.identity(edit.id)?.parentResource ?? activeFolderIdentity,
            resourceIdentity: knownResourceIdentity(edit.id), now: clock.now(), verifiedRelocation: verifiedRelocation)
    }

    /// Every journal write goes through here. A direct write supersedes a deferred one.
    func persistJournal(_ record: RecoveryRecord) throws {
        let id = record.noteID
        session.deferredJournals[id] = nil
        session.journalTasks.removeValue(forKey: id)?.cancel()
        try journals.persist(record)
        session.journaledAt[id] = clock.now()
    }

    /// Coalesces typing: writes now if the last journal of the note is older than the
    /// debounce, else keeps only the newest record and writes it when the debounce ends.
    func persistTypingJournal(_ record: RecoveryRecord) throws {
        let id = record.noteID
        let gap = timing.journalDebounce.timeInterval
        let elapsed = session.journaledAt[id].map { clock.now().timeIntervalSince($0) } ?? .infinity
        guard gap > 0, elapsed < gap else { return try persistJournal(record) }
        session.deferredJournals[id] = record
        guard session.journalTasks[id] == nil else { return }
        let delay = Duration.seconds(max(gap - elapsed, 0))
        session.journalTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flushDeferredJournal(id, timerFired: true)
        }
    }

    /// Writes the deferred journal of the note, if any. A failure shows as an unjournaled save failure.
    func flushDeferredJournal(_ id: NoteID, timerFired: Bool = false) {
        if timerFired { session.journalTasks[id] = nil }
        guard let record = session.deferredJournals[id] else { return }
        do { try persistJournal(record) }
        catch { setStatus(id, .failed(record.editRevision, NoteFailureMapping.operationError(error), journaled: false)) }
    }

    func flushDeferredJournals() {
        for id in Array(session.deferredJournals.keys) { flushDeferredJournal(id) }
    }

    /// Removes the finished edit's journal, then forgets its record. The record stays if removal fails.
    func finishEdit(_ edit: EditSnapshot) throws {
        try removeJournal(edit.id, through: edit.revision)
        session.journalRecords[edit.id] = nil
    }

    func removeJournal(_ id: NoteID, through revision: EditRevision) throws {
        session.deferredJournals[id] = nil
        session.journalTasks.removeValue(forKey: id)?.cancel()
        try journals.remove(id, through: revision)
    }

    func schedule(_ edit: EditSnapshot, delay: Duration) {
        session.saveTasks[edit.id]?.cancel()
        session.saveTasks[edit.id] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.save(edit)
        }
    }

    func save(_ edit: EditSnapshot) -> SaveResult {
        guard edit.collectionToken == collectionToken else { return .failed(.staleCollection) }
        do { try validateLocation(edit) } catch { return .failed(NoteFailureMapping.operationError(error)) }
        if unfinishedLocationOperations().contains(where: { $0.noteID == edit.id }) {
            var journaled = false
            if edit.revision > (session.completions[edit.id]?.revision ?? EditRevision(rawValue: 0)),
               edit.revision >= (pending[edit.id]?.revision ?? EditRevision(rawValue: 0)), let note = knownNote(edit.id) {
                pending[edit.id] = edit
                let record = journal(for: edit, url: note.fileURL)
                session.journalRecords[edit.id] = record
                do { try persistJournal(record); journaled = true } catch {}
                setStatus(edit.id, .failed(edit.revision, .locationOperationPending, journaled: journaled))
            }
            return .failed(.locationOperationPending)
        }
        var journaled = false
        do {
            try validate(edit.collectionToken)
            if let saved = session.completions[edit.id]?.revision, edit.revision <= saved, let completed = session.completions[edit.id]?.result {
                if let current = identities.identity(edit.id), current.revision != edit.locationRevision {
                    throw NoteOperationError.staleLocation
                }
                return completed
            }
            try validateLocation(edit)
            if let newer = pending[edit.id], newer.revision > edit.revision { return .failed(.cancelled) }
            guard var note = knownNote(edit.id) else { throw NoteOperationError.unavailable }
            // Journal before scanning, so a lost volume never drops a save request.
            pending[edit.id] = edit
            let record = journal(for: edit, url: note.fileURL)
            session.journalRecords[edit.id] = record
            do { try persistJournal(record); journaled = true }
            catch { setStatus(edit.id, .failed(edit.revision, NoteFailureMapping.operationError(error), journaled: false)) }
            guard let folder else { throw NoteOperationError.unavailable }
            if note.fileURL.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                _ = try customLocations(defaultURL: folder, only: edit.id)
                guard identities.identity(edit.id)?.availability != .trashed else { throw NoteOperationError.unavailable }
                if let failure = accessFailures[edit.id] { throw NoteOperationError.accessFailure(failure) }
            }
            // Autosave checks only its own file. If that file is missing or replaced, reconcile
            // to tell a rename from a replacement.
            let expected = identities.identity(edit.id)
            guard (try? StorageFiles.linkCount(note.fileURL)) ?? 1 <= 1 else { throw NoteOperationError.unavailable }
            let resource = try? StorageFiles.fileResourceID(note.fileURL)
            if expected?.resource != resource,
               note.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                let discovery = try discoverIdentities(in: folder)
                guard discovery.folderIdentity == activeFolderIdentity else { throw NoteOperationError.unavailable }
                guard let target = discovery.mapping.first(where: { $0.id == edit.id }) else {
                    guard StorageFiles.isMissing(note.fileURL) else { throw NoteOperationError.unavailable }
                    return promote(edit, original: note.fileURL, missing: true)
                }
                // Accept an external rename only through a newly published location.
                if target.path != note.fileURL.path {
                    note = NoteSnapshot(id: note.id, collectionToken: collectionToken, fileURL: URL(fileURLWithPath: target.path),
                        fileRevision: note.fileRevision, text: note.text, availability: note.availability,
                        editRevision: note.editRevision, locationRevision: target.revision, createdAt: note.createdAt)
                    var updated = identities
                    _ = updated.remember(target)
                    try writeIdentities(updated)
                    emit(.changed(note))
                }
            }
            if expected?.resource != resource,
               note.fileURL.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                _ = try customLocations(defaultURL: folder, only: edit.id)
                guard let current = identities.identity(edit.id), current.availability == .available else {
                    throw accessFailures[edit.id].map(NoteOperationError.accessFailure) ?? .unavailable
                }
                note = NoteSnapshot(id: edit.id, collectionToken: collectionToken, fileURL: URL(fileURLWithPath: current.path),
                    fileRevision: note.fileRevision, text: note.text, availability: .available,
                    editRevision: note.editRevision, locationRevision: current.revision, createdAt: note.createdAt)
                if note.fileURL.path != expected?.path { emit(.changed(note)) }
            }
            if StorageFiles.isMissing(note.fileURL) {
                if expected?.access != nil { throw NoteOperationError.unavailable }
                return promote(edit, original: note.fileURL, missing: true)
            }
            guard note.availability == .available else { throw (accessFailures[edit.id] ?? note.accessFailure).map(NoteOperationError.accessFailure) ?? .unavailable }
            let currentEdit = EditSnapshot(id: edit.id, collectionToken: edit.collectionToken, revision: edit.revision,
                baseRevision: edit.baseRevision, text: edit.text, locationRevision: note.locationRevision)
            if currentEdit.locationRevision != edit.locationRevision {
                pending[edit.id] = currentEdit
                let relocatedJournal = journal(for: currentEdit, url: note.fileURL, verifiedRelocation: true)
                session.journalRecords[edit.id] = relocatedJournal
                try persistJournal(relocatedJournal)
            }
            try fault(.beforeReplacement)
            if note.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                try rememberIdentity(note)
            }
            session.knownLocations[edit.id] = note.fileURL
            let saved: (text: String, revision: FileRevision, stamp: StorageFiles.Stamp?)
            do {
                try fault(.destination)
                saved = try replace(currentEdit, at: note.fileURL)
                try fault(.afterReplacement)
            } catch {
                let failure = NoteFailureMapping.operationError(error)
                if (failure == .conflict || StorageFiles.isMissing(note.fileURL)) && !session.writing.contains(edit.id) {
                    return promote(edit, original: note.fileURL, missing: StorageFiles.isMissing(note.fileURL))
                }
                Log.save.error("save failed note=\(edit.id.rawValue, privacy: .public) stage=replace journaled=\(journaled) error=\(error.localizedDescription, privacy: .private)")
                setStatus(edit.id, .failed(edit.revision, failure, journaled: journaled))
                retryOrStop(currentEdit, failure: failure)
                return .failed(failure)
            }
            // Use the bytes verified inside our write. A later read could already hold
            // another app's version.
            var snapshot = NoteSnapshot(id: edit.id, collectionToken: collectionToken, fileURL: note.fileURL,
                                        fileRevision: saved.revision, text: saved.text, availability: .available, editRevision: edit.revision, locationRevision: note.locationRevision,
                                        createdAt: saved.stamp?.created ?? StorageFiles.creationDate(note.fileURL))
            snapshot.fileObservation = .ownWrite
            records[edit.id] = snapshot
            if note.fileURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                try? rememberIdentity(snapshot, deferred: true)
            }
            // Cache our own write, so the next reconcile doesn't re-read it.
            bodyCache[note.fileURL.path] = saved.stamp.map { CachedBody(stamp: $0, text: saved.text, revision: saved.revision) }
            edits.completeSaved(edit, fileRevision: saved.revision, session: &session)
            setStatus(edit.id, .saved(edit.revision))
            emit(.saved(snapshot))
            // The file is saved and verified. On failure, startup cleanup removes the journal later.
            try? finishEdit(edit)
            return .saved(revision: edit.revision, fileRevision: saved.revision)
        } catch {
            let failure = NoteFailureMapping.operationError(error)
            if case let .accessFailure(reason) = failure {
                accessFailures[edit.id] = reason
                if let prior = records[edit.id] {
                    let failed = NoteSnapshot(id: prior.id, collectionToken: prior.collectionToken, fileURL: prior.fileURL,
                        fileRevision: prior.fileRevision, text: prior.text, availability: .unavailable(reason: String(localized: reason.message)),
                        accessFailure: reason, editRevision: prior.editRevision, locationRevision: prior.locationRevision, createdAt: prior.createdAt)
                    records[edit.id] = failed
                    emit(.changed(failed))
                }
            }
            Log.save.error("save failed note=\(edit.id.rawValue, privacy: .public) stage=prepare journaled=\(journaled) error=\(error.localizedDescription, privacy: .private)")
            setStatus(edit.id, .failed(edit.revision, failure, journaled: journaled))
            retryOrStop(pending[edit.id] ?? edit, failure: failure)
            return .failed(failure)
        }
    }

    /// Limit retry delays. Permission failures wait for user action.
    private func retryOrStop(_ edit: EditSnapshot, failure: NoteOperationError) {
        if failure.shouldRetrySave {
            let count = session.retryCounts[edit.id] ?? 0
            session.retryCounts[edit.id] = count + 1
            Log.save.notice("save retry scheduled note=\(edit.id.rawValue, privacy: .public) attempt=\(count + 1)")
            schedule(edit, delay: .seconds([1, 5, 30][min(count, 2)]))
        } else {
            Log.save.notice("save retry stopped note=\(edit.id.rawValue, privacy: .public): needs user action")
            session.saveTasks[edit.id]?.cancel()
        }
    }

    private func replace(_ edit: EditSnapshot, at url: URL) throws -> (text: String, revision: FileRevision, stamp: StorageFiles.Stamp?) {
        // Naming our presenter stops coordination messages for our own write. FSEvents still
        // reports it, and externalEvent filters it out by stamp.
        let expectedResource = identities.identity(edit.id)?.resource
        let isCustom = url.deletingLastPathComponent().standardizedFileURL != folder?.standardizedFileURL
        let expectedParent = identities.identity(edit.id)?.parentResource
        let coordinator = NSFileCoordinator(filePresenter: fileObservers[edit.id] ?? observer)
        var failure: NSError?
        var result: Result<(text: String, revision: FileRevision, stamp: StorageFiles.Stamp?), Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &failure) { safeURL in
            result = Result {
                guard try StorageFiles.supported(safeURL) else { throw NoteOperationError.unavailable }
                guard try StorageFiles.fileResourceID(safeURL) == expectedResource,
                      (try isCustom || StorageFiles.resourceID(safeURL.deletingLastPathComponent()) == expectedParent) else {
                    throw NoteOperationError.conflict
                }
                let availability = try safeURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                guard availability.ubiquitousItemDownloadingStatus != .notDownloaded else { throw NoteOperationError.unavailable }
                let original = try readBody(safeURL)
                let data = StorageFiles.encoded(edit.text, preserving: original)
                // Detect a crash after the write but before journal cleanup.
                let digest = StorageFiles.digest(original)
                switch NoteSavePolicy.decide(equalContent: original == data, diskFingerprint: digest,
                    baseFingerprint: edit.baseRevision?.fingerprint,
                    lastWrittenFingerprint: session.lastWritten[edit.id]?.fingerprint,
                    ownBaseFingerprints: session.ownBases[edit.id] ?? [],
                    validEncoding: String(data: original, encoding: .utf8) != nil) {
                case .conflict: throw NoteOperationError.conflict
                case .unsupportedEncoding: throw NoteOperationError.unsupportedEncoding
                case .unchanged: break
                case .replace:
                    guard try StorageFiles.fileResourceID(safeURL) == expectedResource else { throw NoteOperationError.conflict }
                    if isCustom { try StorageFiles.saveAuthorizedFile(data, at: safeURL) }
                    else { try writeBody(data, safeURL) }
                }
                // Stamp between write and verify. Another write in between fails the verify,
                // so the stamp always describes our bytes.
                let stamp = try? StorageFiles.stamp(safeURL)
                guard try readBody(safeURL) == data else { throw NoteOperationError.inputOutput(LocalizedStringResource("Save verification failed", comment: "Error when a saved file does not match the text")) }
                let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
                let values = try URL(fileURLWithPath: safeURL.path).resourceValues(forKeys: [.contentModificationDateKey])
                let revision = FileRevision(fingerprint: StorageFiles.digest(data), modifiedAt: values.contentModificationDate ?? .distantPast)
                let text = String(decoding: body, as: UTF8.self)
                if isCustom {
                    session.lastWritten[edit.id] = revision
                    try checkpointSavedIdentity(NoteSnapshot(id: edit.id, collectionToken: edit.collectionToken,
                        fileURL: safeURL, fileRevision: revision, text: text, availability: .available,
                        editRevision: edit.revision, locationRevision: edit.locationRevision))
                }
                return (text, revision, stamp)
            }
        }
        if let failure { throw failure }
        guard let result else { throw NoteOperationError.unavailable }
        return try result.get()
    }

    func validateLocation(_ edit: EditSnapshot) throws {
        guard identities.identity(edit.id)?.availability != .trashed else { throw NoteOperationError.unavailable }
        let recovered = (session.completions[edit.id]?.result).map { if case .recovered = $0 { true } else { false } } ?? false
        guard RetainedEditPolicy.acceptsLocation(current: identities.identity(edit.id)?.revision,
            requested: edit.locationRevision, hasKnownLocation: session.knownLocations[edit.id] != nil,
            recovered: recovered) else { throw NoteOperationError.staleLocation }
    }

    func retry(_ id: NoteID) -> SaveResult {
        guard let edit = pending[id] else { return .failed(.unavailable) }
        return save(edit)
    }

    func flush(_ id: NoteID) throws {
        defer { writeIdentitiesIfDirty() }
        flushDeferredJournal(id)
        guard !session.writing.contains(id) else { throw NoteOperationError.unavailable }
        guard let edit = pending[id] else { return }
        session.saveTasks[id]?.cancel()
        switch save(edit) {
        case .saved, .recovered: return
        case let .failed(error): throw error
        }
    }

    func flushForQuit() throws {
        defer { writeIdentitiesIfDirty() }
        flushDeferredJournals()
        guard session.writing.isEmpty else { throw NoteOperationError.unavailable }
        for edit in Array(pending.values) {
            session.saveTasks[edit.id]?.cancel()
            guard case let .failed(error) = save(edit) else { continue }
            // Quit requires the journal to contain this exact revision if saving fails.
            guard case let .failed(revision, _, journaled)? = statuses[edit.id], journaled, revision == edit.revision else { throw error }
        }
    }

    func flush() throws {
        defer { writeIdentitiesIfDirty() }
        flushDeferredJournals()
        guard session.writing.isEmpty else { throw NoteOperationError.unavailable }
        for edit in Array(pending.values) {
            session.saveTasks[edit.id]?.cancel()
            switch save(edit) {
            case .saved, .recovered: break
            case let .failed(error): throw error
            }
        }
    }

    /// File promises copy text without saving, clearing pending edits, or advertising the original URL.
    func writeDragCopy(_ requested: NoteSnapshot, text: String?, to destination: URL) throws {
        let current = try read(requested.id, collectionToken: requested.collectionToken)
        guard current.availability == .available, current.locationRevision == requested.locationRevision else {
            throw NoteOperationError.unavailable
        }
        let retainedAccess = [lease].compactMap { $0 } + (accessLeases[requested.id] ?? [])
        defer { withExtendedLifetime(retainedAccess) {} }
        let data = Data((text ?? pending[requested.id]?.text ?? current.text).utf8)
        try StorageFiles.create(data, at: destination)
        guard try Data(contentsOf: destination) == data else { throw NoteOperationError.inputOutput(LocalizedStringResource("Export verification failed", comment: "Error when an exported file does not match the text")) }
    }

    func export(_ id: NoteID, to url: URL) throws {
        guard let edit = pending[id] else { throw NoteOperationError.unavailable }
        let data = Data(edit.text.utf8)
        try StorageFiles.export(data, to: url)
        release(edit, to: url)
    }

    /// The text of `edit` is verified in a separate file at `url`. Releasing it unblocks close
    /// and folder switch. The original file and its journal stay as they are.
    func release(_ edit: EditSnapshot, to url: URL) {
        setStatus(edit.id, .recoverable(edit.revision, url))
        preservedBuffers[edit.id] = edit
        pending[edit.id] = nil
        session.saveTasks[edit.id]?.cancel()
    }

    /// The user confirmed that the unsaved text may be lost. Drops the pending edit and its
    /// journal through `revision`; the file on disk keeps its last saved text.
    func discardEdits(_ id: NoteID, through revision: EditRevision) throws {
        guard !session.writing.contains(id) else { throw NoteOperationError.unavailable }
        if let edit = pending[id], edit.revision > revision { throw NoteOperationError.conflict }
        session.saveTasks[id]?.cancel()
        pending[id] = nil
        preservedBuffers[id] = nil
        try removeJournal(id, through: revision)
        session.journalRecords[id] = nil
        clearStatus(id)
    }

    func retainedBuffer(_ id: NoteID) -> EditSnapshot? { pending[id] ?? preservedBuffers[id] }

    func canDispose(_ id: NoteID) -> Bool {
        let recoverable: EditRevision?
        if case let .recoverable(revision, _) = statuses[id] { recoverable = revision } else { recoverable = nil }
        return RetainedEditPolicy(writing: session.writing.contains(id), pendingRevision: pending[id]?.revision,
            recoverableRevision: recoverable).canDispose
    }


}


extension NoteStore: EditorNotes, NoteNotifications, RecoveryNotes {
    func copySource(_ id: NoteID, collectionToken: CollectionToken) throws -> NoteCopySource {
        try validate(collectionToken)
        let note = try read(id, collectionToken: collectionToken)
        let retained = pending[id] ?? preservedBuffers[id]
        let journal = session.journalRecords[id]
        guard note.availability == .available || retained != nil || journal != nil else {
            throw NoteOperationError.unavailable
        }
        let revision = [
            note.editRevision.rawValue,
            retained?.revision.rawValue,
            journal?.editRevision.rawValue
        ].compactMap { $0 }.max() ?? 0
        return NoteCopySource(note: note, editRevision: EditRevision(rawValue: revision),
            text: retained?.text ?? journal?.text ?? note.text)
    }
    func exportText(_ id: NoteID, text: String, to url: URL) async throws {
        if pending[id] != nil { try export(id, to: url) }
        else {
            let data = Data(text.utf8)
            try await Task.detached {
                try StorageFiles.export(data, to: url)
            }.value
        }
    }
}

private extension NoteOperationError {
    var shouldRetrySave: Bool {
        switch self {
        case .permissionDenied, .unavailable, .conflict:
            return false
        case let .accessFailure(failure):
            switch failure.reason {
            case .permission, .folderAuthorization, .staleBookmark: return false
            case .missingFile, .unavailableVolume, .cloudPlaceholder, .unsupportedEncoding, .unknown: return true
            }
        default:
            return true
        }
    }
}
