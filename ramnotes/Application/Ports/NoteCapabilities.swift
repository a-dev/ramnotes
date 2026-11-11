import ramnotesDomain
import Foundation

/// Editing delivery stays ordered by the editor outbox and serialized by its owner.
protocol NoteEditing: Sendable {
    func submit(_ edit: EditSnapshot) async -> StorageSaveStatus
    func setWriting(_ active: Bool, for id: NoteID) async throws
    func finishWriting(_ edit: EditSnapshot) async throws
    func flush(_ id: NoteID) async throws
    func flush() async throws
    /// Quit can proceed after a failed save if the journal contains the exact revision.
    func flushForQuit() async throws
    func canDispose(_ id: NoteID) async -> Bool
    func discardEdits(_ id: NoteID, through revision: EditRevision) async throws
    func status(_ id: NoteID) async -> StorageSaveStatus?
    func pruneStatus(_ id: NoteID) async
    func exportText(_ id: NoteID, text: String, to url: URL) async throws
    func copySource(_ id: NoteID, collectionToken: CollectionToken) async throws -> NoteCopySource
}

protocol NoteLocations: Sendable {
    func retryLocationOperation(_ id: UUID) async throws -> NoteMoveResult
    func acquireFile(_ url: URL) async throws -> any FileGrant
    func acquireDestinationFile(_ url: URL) async throws -> any FileGrant
    func createCopy(from source: NoteSnapshot, editRevision: EditRevision, text: String, to destination: any FileGrant) async throws -> NoteSnapshot
    func read(_ id: NoteID, collectionToken: CollectionToken) async throws -> NoteSnapshot
    func removeUnavailableNote(_ id: NoteID, collectionToken: CollectionToken, locationRevision: LocationRevision) async throws
    func renewFileAccess(_ id: NoteID, file: any FileGrant, collectionToken: CollectionToken, locationRevision: LocationRevision) async throws -> NoteSnapshot
    func relinkNote(_ id: NoteID, file: any FileGrant, collectionToken: CollectionToken, locationRevision: LocationRevision) async throws -> NoteSnapshot
    func moveNote(_ id: NoteID, to url: URL, collectionToken: CollectionToken, locationRevision: LocationRevision, editRevision: EditRevision) async -> NoteMoveResult
}

protocol EditorNotes: NoteEditing, NoteLocations {
    func retainForExternalTrash(_ edit: EditSnapshot) async throws
    func verifyForPresentation(_ note: NoteSnapshot) async throws -> NoteSnapshot
    func verifyForPresentation(_ notes: [NoteSnapshot]) async throws -> [NoteID: Result<NoteSnapshot, Error>]
}

protocol NoteNotifications: AnyObject, Sendable {
    func events() async -> AsyncStream<NoteEvent>
    /// Subscribes and returns how many events were published before this subscription.
    func subscribe() async -> (events: AsyncStream<NoteEvent>, published: Int)
    func publishedEventCount() async -> Int
}

/// Recovery presentation can read notes and request deletion workflows.
protocol RecoveryNotes: NoteTrashing {
    func status(_ id: NoteID) async -> StorageSaveStatus?
    func read(_ id: NoteID, collectionToken: CollectionToken) async throws -> NoteSnapshot
    func forgetRecoveryNotices(_ recoveryURLs: Set<URL>) async throws
}

/// Recovery presentation exports preserved text through this capability. Composition supplies
/// the infrastructure implementation; presentation never creates files itself.
protocol RecoveryTextExporting: Sendable {
    func exportRecoveryText(_ data: Data, to url: URL) async throws
}
