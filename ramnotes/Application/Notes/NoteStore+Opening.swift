import ramnotesDomain
import Foundation

struct FolderSelection: Sendable {
    let url: URL
    let collectionToken: CollectionToken
    let notes: [NoteSnapshot]
    let recoveryDiagnostics: [String]
}

extension NoteStore {
    func currentFolder() -> (url: URL?, collectionToken: CollectionToken) { (folder, collectionToken) }

    func openSelectedFolder(progress: (@Sendable ([NoteSnapshot]) -> Void)? = nil) throws -> FolderSelection {
        guard folder == nil else { throw NoteOperationError.inputOutput(LocalizedStringResource("A notes folder is already active", comment: "Error when a notes folder is chosen while another is already open")) }
        try fault(.folderAccess)
        let acquired: FolderLease?
        let selectedURL: URL
        var accessFailure: NoteOperationError?
        do {
            let restored = try folderAccess.restore()
            acquired = restored
            selectedURL = restored.url
        } catch {
            guard !identities.mapping.isEmpty else { throw error }
            acquired = nil
            accessFailure = NoteFailureMapping.operationError(error)
            selectedURL = try CatalogPersistence.load(at: folderAccess.selectionURL).defaultFolder?.url ?? folderAccess.defaultURL
        }
        let operationDiagnostics = reconcileLocationOperations()
        let token = CollectionToken()
        let identity = (try? StorageFiles.resourceID(selectedURL)) ?? identities.mapping.first {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL == selectedURL.standardizedFileURL
        }?.parentResource
        let custom = try customLocations(defaultURL: selectedURL)
        let result = try scanner.run(selectedURL, identities: identities, cache: bodyCache, collectionToken: token,
                                     custom: custom, defaultFailure: accessFailure, check: { try Task.checkCancellation() })
        let notes = result.snapshots.map { note in
            var note = note
            note.accessFailure = accessFailures[note.id] ?? note.accessFailure
            return note
        }
        try commitIdentities(result.discovery)
        pruneUnregisteredJournals()
        bodyCache = result.cache
        progress?(notes)
        try Task.checkCancellation()
        if let acquired { try folderAccess.commit(acquired) }
        resetFolderState()
        lease = acquired
        defaultAccessFailure = accessFailure
        folder = selectedURL
        activeFolderIdentity = identity
        collectionToken = token
        records = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        session.knownLocations = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.fileURL) })
        let diagnostics = operationDiagnostics.map { String(localized: $0) } + replayRecovery() + resumeDefaultFolderChanges()
        startObserving()
        return FolderSelection(url: selectedURL, collectionToken: token, notes: Array(records.values), recoveryDiagnostics: diagnostics)
    }

    func switchFolder(to requested: URL?, from token: CollectionToken) throws -> CollectionToken {
        guard let requested else { throw NoteOperationError.cancelled }
        return try switchFolder(to: requested, from: token)
    }

    /// Switches folders without moving files. Kept for older callers.
    /// A default-folder change keeps the collection token and all registered notes.
    func switchFolder(to requested: URL, from token: CollectionToken) throws -> CollectionToken {
        try validate(token)
        try Task.checkCancellation()
        try flush()
        let result = try changeDefaultFolder(to: requested, moveExisting: false, from: token)
        _ = replayRecovery()
        return result.collectionToken
    }


    /// Replaces `CollectionSession`, which drops every per-note record of the old folder.
    /// Keeps `pending` (empty after the flush), `preservedBuffers` (exports), `notices`
    /// (the app filters them by folder), and the recovery journals on disk.
    func resetFolderState() {
        flushDeferredJournals()
        session.cancelSaves()
        session = CollectionSession()
        clearStatuses()
        records.removeAll()
    }

    /// Retained buffers for the current folder only. Exports from an earlier folder stay
    /// available through `retainedBuffer(_:)`, but never fill editors in the new folder.
    func retainedEdits() -> [NoteID: EditSnapshot] {
        preservedBuffers.merging(pending) { _, pending in pending }.filter { $0.value.collectionToken == collectionToken }
    }

    func retainedRecovery() -> (edits: [RetainedEditSummary], diagnostics: [String]) {
        let loaded = recovery.load()
        return (loaded.records.map(RetainedEditSummary.init), loaded.diagnostics)
    }
}
