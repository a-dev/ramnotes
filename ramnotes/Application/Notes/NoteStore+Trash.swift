import ramnotesDomain
import Foundation

extension NoteStore: NoteTrashing {
    func moveToTrash(_ id: NoteID, collectionToken token: CollectionToken) throws {
        try validate(token)
        try requireNoLocationOperation(id)
        guard !session.writing.contains(id) else { throw NoteOperationError.unavailable }
        if let edit = pending[id] {
            switch save(edit) {
            case .saved, .recovered: break
            case let .failed(error): throw error
            }
        }
        guard let note = records[id], let location = identities.identity(id) else { throw NoteOperationError.unavailable }

        // Trash is authorized by the selected note's file grant. A parent-folder grant is
        // never acquired for custom-path notes.
        let parent = note.fileURL.deletingLastPathComponent()
        let fileLease: FolderLease
        if let fileAccess = location.fileAccess {
            fileLease = try folderAccess.restore(fileAccess).0
        } else if Self.sameDirectory(parent, defaultFolder()),
                  let defaultLease = lease, Self.sameDirectory(parent, defaultLease.url) {
            // Older default-folder catalog entries can rely on the already retained folder
            // grant. Do not acquire a new parent grant as a fallback.
            fileLease = defaultLease
        } else {
            throw NoteOperationError.unavailable
        }
        defer { withExtendedLifetime(fileLease) {} }
        let coordinator = NSFileCoordinator(filePresenter: fileObservers[id] ?? observer)
        var coordinationFailure: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: note.fileURL, options: .forDeleting, error: &coordinationFailure) { source in
            result = Result {
                try fault(.trash)
                try verifyTrashSource(location, at: source, revision: note.fileRevision)
                _ = try trashService.move(source)
            }
        }
        if let coordinationFailure { throw coordinationFailure }
        guard let result else { throw NoteOperationError.unavailable }
        try result.get()

        // A successful Trash is final. If the catalog checkpoint fails, remove the in-memory
        // entry as well so a later activation cannot rediscover the trashed custom note.
        var updated = identities
        updated.remove(id)
        do { try writeIdentities(updated) }
        catch {
            installCatalog(updated.catalog)
            deferIdentityWrite(updated)
            emit(.failed(id, NoteFailureMapping.operationError(error)))
        }
        forget(id, path: location.path)
    }

    /// Trash uses a file grant, so its identity check must not require opening the parent.
    /// `source` is the URL supplied by NSFileCoordinator for this deletion claim.
    private func verifyTrashSource(_ location: NoteLocationRecord, at source: URL,
                                  revision: FileRevision?) throws {
        guard let revision, location.resource != nil,
              try StorageFiles.supported(source),
              try StorageFiles.fileResourceID(source) == location.resource,
              try StorageFiles.locationRevision(source) == revision else {
            throw NoteOperationError.conflict
        }
        guard try StorageFiles.linkCount(source) == 1 else {
            throw NoteOperationError.conflict
        }
    }
}
