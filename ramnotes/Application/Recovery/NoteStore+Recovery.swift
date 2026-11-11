import ramnotesDomain
import Foundation
import os

/// Serialized application recovery workflow. Every journal and catalog checkpoint
/// stays synchronous on NoteStore, including the checkpoints around file creation.
extension NoteStore {
#if DEBUG
    /// Writes a recovery link between two registered notes and emits `.notice`, as a real
    /// promotion does. The DEBUG layout fixture uses it so the store holds the notice it shows.
    func seedRecoveryNoticeForFixture(original: NoteSnapshot, recovery: NoteSnapshot) throws {
        let notice = RecoveryNotice(originalURL: original.fileURL, recoveryURL: recovery.fileURL,
                                    originalMissing: false, recoveryNoteID: recovery.id, sourceNoteID: original.id)
        try checkpointMemoryCatalog { $0.recoveryLinks[UUID()] = notice }
        notices.append(notice)
        emit(.notice(notice))
    }
#endif

    /// Detaches the live buffer without writing to the observed Trash resource.
    /// Returning acknowledges durable retention of this exact revision and text.
    func retainForExternalTrash(_ edit: EditSnapshot) throws {
        try validate(edit.collectionToken)
        guard let identity = identities.identity(edit.id), identity.revision == edit.locationRevision else {
            throw NoteOperationError.staleLocation
        }
        var record = RecoveryPolicy.journal(for: edit, url: URL(fileURLWithPath: identity.path), prior: nil,
            folderIdentity: identity.parentResource ?? activeFolderIdentity,
            resourceIdentity: knownResourceIdentity(edit.id), now: clock.now())
        record.trackingRemoved = true
        try persistJournal(record)
        try recovery.retain(record)
    }

    /// The edit lives on in a recovery note. Its journal record goes even if journal removal fails.
    func finishRecovered(_ edit: EditSnapshot, summary: RetainedEditSummary) {
        edits.completeRecovered(edit, summary: summary, session: &session)
        try? removeJournal(edit.id, through: edit.revision)
        session.journalRecords[edit.id] = nil
    }

    func promote(_ edit: EditSnapshot, original: URL, missing: Bool) -> SaveResult {
        Log.recovery.notice("promote to recovery note=\(edit.id.rawValue, privacy: .public) missing=\(missing) path=\(original.path, privacy: .private)")
        do {
            if var completed = session.journalRecords[edit.id],
               let link = RecoveryPolicy.completedPromotion(completed, for: edit, links: identities.catalog.recoveryLinks) {
                completed.promotedNoteID = link.recoveryNoteID
                completed.promotionURL = link.recoveryURL
                finishRecovered(edit, summary: RetainedEditSummary(completed))
                setStatus(edit.id, .recoverable(edit.revision, link.recoveryURL))
                return .recovered(RetainedEditSummary(completed))
            }
            if let updated = updateConflictRecovery(edit, missing: missing) { return updated }
            guard let folder, defaultAccessFailure == nil else { throw NoteOperationError.unavailable }
            guard try StorageFiles.resourceID(folder) == activeFolderIdentity else { throw NoteOperationError.unavailable }
            let retainedDefault = lease
            defer { withExtendedLifetime(retainedDefault) {} }
            let prior = session.journalRecords[edit.id] ?? journal(for: edit, url: original)
            var record = RecoveryPolicy.promotion(for: edit, original: original, missing: missing,
                prior: prior, collectionToken: collectionToken, folderIdentity: activeFolderIdentity,
                resourceIdentity: knownResourceIdentity(edit.id))
            // Save a reserved name before writing the recovery file.
            // If that file already exists, verify it. Never overwrite it.
            var promotionLease: FolderLease?
            if let access = record.promotionAccess {
                let restored = try folderAccess.restore(access).0
                promotionLease = restored
                guard try StorageFiles.resourceID(restored.url) == record.promotionParentResource else { throw NoteOperationError.unavailable }
                if let reserved = record.promotionURL {
                    record.promotionURL = restored.url.appendingPathComponent(reserved.lastPathComponent)
                }
            }
            defer { withExtendedLifetime(promotionLease) {} }
            if let reserved = record.promotionURL, record.promotionResource == nil,
               !StorageFiles.exists(reserved),
               (try? StorageFiles.resourceID(reserved.deletingLastPathComponent())) == record.promotionParentResource,
               !Self.sameDirectory(reserved.deletingLastPathComponent(), folder) {
                record.promotionURL = nil
            }
            if record.promotionURL == nil {
                var candidate = folder.appendingPathComponent(filenameGenerator.next())
                for _ in 0..<10_000 {
                    if !StorageFiles.exists(candidate) { break }
                    candidate = folder.appendingPathComponent(filenameGenerator.next())
                }
                guard !StorageFiles.exists(candidate) else { throw NoteOperationError.destinationOccupied }
                record.promotionURL = candidate
                record.promotionAccess = try lease.map { try folderAccess.descriptor(for: $0) }
                record.promotionParentResource = activeFolderIdentity
            }
            session.journalRecords[edit.id] = record
            try persistJournal(record)
            try fault(.promotion)
            guard let promoted = record.promotionURL else { throw NoteOperationError.unavailable }
            record.promotionResource = try RecoveryFiles.createOrVerify(record)
            session.journalRecords[edit.id] = record
            try persistJournal(record)
            try fault(.promotionCreated)
            // Register the one known file. Don't rescan the folder for each conflicted note.
            let note = try adopt(promoted)
            record.promotedNoteID = note.id
            // Save completion before cleanup. Every retry uses the same promotion ID.
            try persistJournal(record)
            let notice = RecoveryNotice(originalURL: original, recoveryURL: promoted, originalMissing: missing,
                                        recoveryNoteID: note.id, sourceNoteID: edit.id)
            try checkpointMemoryCatalog { catalog in
                catalog.recoveryLinks[record.id] = notice
                catalog.notes[note.id]?.access = record.promotionAccess
            }
            accessLeases[note.id] = [promotionLease ?? retainedDefault].compactMap { $0 }
            startObserving()
            try fault(.promotionCatalog)
            if !notices.contains(notice) { notices.append(notice) }
            setStatus(edit.id, .recoverable(edit.revision, promoted))
            finishRecovered(edit, summary: RetainedEditSummary(record))
            emit(.notice(notice))
            if missing {
                records[edit.id] = nil
                emit(.removed(edit.id, collectionToken))
            }
            emit(.discovered(note))
            session.conflictRecoveries[edit.id] = missing ? nil : ConflictRecovery(record: record,
                baseRevision: edit.baseRevision, sourceRevision: edit.revision,
                recoveryNoteID: note.id, recoveryRevision: note.editRevision)
            return .recovered(RetainedEditSummary(record))
        } catch {
            let failure = NoteFailureMapping.operationError(error)
            Log.recovery.error("promote failed note=\(edit.id.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            setStatus(edit.id, .failed(edit.revision, failure, journaled: StorageFiles.exists(recovery.url(edit.id))))
            return .failed(failure)
        }
    }

    /// Writes a later edit of a conflicted note into the recovery note of the same conflict.
    /// Returns nil when the window does not apply or the write fails; the caller then
    /// promotes to a new recovery note, so the text is never lost.
    private func updateConflictRecovery(_ edit: EditSnapshot, missing: Bool) -> SaveResult? {
        guard var window = session.conflictRecoveries[edit.id] else { return nil }
        let recoveryID = window.recoveryNoteID
        guard RecoveryPolicy.reusesConflictRecovery(window, for: edit, missing: missing,
                  recoveryEditRevision: records[recoveryID]?.editRevision, recoveryPending: pending[recoveryID] != nil),
              let target = records[recoveryID], let promoted = window.record.promotionURL else {
            session.conflictRecoveries[edit.id] = nil
            return nil
        }
        let revision = EditRevision(rawValue: target.editRevision.rawValue + 1)
        let update = EditSnapshot(id: recoveryID, collectionToken: collectionToken, revision: revision,
            baseRevision: target.fileRevision, text: edit.text, locationRevision: target.locationRevision)
        guard case .saved = save(update) else {
            session.conflictRecoveries[edit.id] = nil
            return nil
        }
        var record = window.record
        record = RecoveryRecord(id: record.id, noteID: record.noteID, collectionToken: record.collectionToken,
            originalURL: record.originalURL, folderIdentity: record.folderIdentity,
            originalResourceIdentity: record.originalResourceIdentity, baseRevision: edit.baseRevision,
            editRevision: edit.revision, text: edit.text, createdAt: record.createdAt, reason: record.reason,
            promotedNoteID: record.promotedNoteID)
        record.promotionURL = window.record.promotionURL
        record.promotionAccess = window.record.promotionAccess
        record.promotionParentResource = window.record.promotionParentResource
        record.promotionResource = window.record.promotionResource
        window.sourceRevision = edit.revision
        window.recoveryRevision = records[recoveryID]?.editRevision ?? revision
        session.conflictRecoveries[edit.id] = window
        finishRecovered(edit, summary: RetainedEditSummary(record))
        setStatus(edit.id, .recoverable(edit.revision, promoted))
        return .recovered(RetainedEditSummary(record))
    }

    func replayRecovery() -> [String] {
        let loaded = recovery.load()
        for record in loaded.records {
            let id = record.noteID
            let decision = RecoveryPolicy.replay(record, folderAvailable: folder != nil,
                activeFolderIdentity: activeFolderIdentity, trackedParent: identities.identity(id)?.parentResource,
                tracked: records[id] != nil)
            guard decision != .retain else { continue }
            if records[id] == nil {
                records[id] = snapshot(id: id, url: record.originalURL, collectionToken: collectionToken)
            }
            session.knownLocations[id] = records[id]?.fileURL
            let edit = EditSnapshot(id: id, collectionToken: collectionToken, revision: record.editRevision,
                                    baseRevision: record.baseRevision, text: record.text, locationRevision: identities.identity(id)?.revision ?? LocationRevision())
            session.journalRecords[id] = record
            pending[id] = edit
            if decision == .promote {
                _ = promote(edit, original: record.originalURL, missing: record.reason == .missingOriginal)
            } else { _ = save(edit) }
        }
        return loaded.diagnostics
    }
}
