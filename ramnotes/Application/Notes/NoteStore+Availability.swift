import ramnotesDomain
import Foundation

extension NoteStore {
    /// Runs on the storage actor, so file coordination and downloads never block the UI.
    func retryAvailability(_ id: NoteID, collectionToken: CollectionToken) async throws -> String {
        try validate(collectionToken)
        guard records[id] != nil else { throw NoteOperationError.unavailable }
        try await reconcile(collectionToken: collectionToken)
        guard let refreshed = records[id] else { throw NoteOperationError.unavailable }
        if refreshed.availability == .available { emit(.changed(refreshed)); return String(localized: "Content available.", comment: "Shown after the app confirmed that an unavailable note can be read again") }
        emit(.changed(refreshed))
        // Reading a placeholder already requested its iCloud download.
        return refreshed.accessFailure.map { String(localized: $0.message) } ?? String(localized: "File still unavailable. Click Locate File… to select it.", comment: "Shown when a missing note file is still unavailable")
    }
}
