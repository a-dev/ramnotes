import ramnotesDomain
import Foundation

extension NoteStore {
    /// Forgets an unavailable note completely: catalog entries (see
    /// `CollectionCatalog.forgetting`), recovery journals, and buffers. Deletes no note file.
    func removeUnavailableNote(_ id: NoteID, collectionToken token: CollectionToken, locationRevision: LocationRevision) throws {
        try validate(token)
        guard let location = identities.identity(id), location.revision.matches(locationRevision) else { throw NoteOperationError.staleLocation }
        // Resolve again at both checkpoints: a moved or returned file stays registered.
        func originalIsMissing() -> Bool {
            if let descriptor = location.fileAccess,
               let (lease, _) = try? folderAccess.restore(descriptor),
               let resource = location.resource,
               (try? StorageFiles.fileResourceID(lease.url)) == resource,
               (try? lease.url.checkResourceIsReachable()) == true {
                return false
            }
            return StorageFiles.isMissing(URL(fileURLWithPath: location.path))
        }
        guard !session.writing.contains(id) else { throw NoteOperationError.conflict }
        let availability = records[id]?.availability ?? location.availability
        let needsMissingCheck = availability == .missingOriginal
        guard NoteTrackingRemovalPolicy.permitsRemoval(availability: availability,
                  confirmedMissing: needsMissingCheck && originalIsMissing()) else {
            throw NoteOperationError.originalNotMissing
        }
        guard !needsMissingCheck || originalIsMissing() else { throw NoteOperationError.conflict }
        var updated = identities
        updated.remove(id)
        try writeIdentities(updated)
        forget(id, path: location.path)
    }

    /// Clear session state after catalog removal. Journal cleanup errors still permit the removal event.
    func forget(_ id: NoteID, path: String? = nil) {
        do { try journals.forget(id) } catch { emit(.failed(id, NoteFailureMapping.operationError(error))) }
        notices.removeAll { $0.recoveryNoteID == id || $0.sourceNoteID == id }
        if let path = path ?? records[id]?.fileURL.path ?? session.knownLocations[id]?.path { bodyCache[path] = nil }
        session.forget(id)
        clearStatus(id)
        pending[id] = nil
        preservedBuffers[id] = nil
        records[id] = nil
        accessFailures[id] = nil
        accessLeases[id] = nil
        fileObservers.removeValue(forKey: id)?.cancel()
        emit(.removed(id, collectionToken))
    }

    /// Removes journals for notes the catalog no longer registers. A note with a retained
    /// recovery record (`trackingRemoved`) keeps its journals: the user may still need them.
    func pruneUnregisteredJournals() {
        let registered = registeredNoteIDs()
        let records = recovery.load().records
        let retained = Set(records.filter(\.trackingRemoved).map(\.noteID))
        let stale = Set(records.map(\.noteID)).filter { !registered.contains($0) && !retained.contains($0) }
        guard !stale.isEmpty else { return }
        do {
            for (id, error) in try journals.forget(stale) { emit(.failed(id, NoteFailureMapping.operationError(error))) }
        } catch {
            for id in stale { emit(.failed(id, NoteFailureMapping.operationError(error))) }
        }
    }
}
