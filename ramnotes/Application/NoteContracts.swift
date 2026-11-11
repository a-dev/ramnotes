import ramnotesDomain
import Foundation

struct StoreTiming: Sendable {
    var saveDebounce: Duration = .milliseconds(500)
    var reconcileDebounce: Duration = .milliseconds(100)
    /// Minimum gap between two recovery journal writes of one note while typing. Zero
    /// journals every edit. Saves, flushes, Quit, and folder changes write a deferred
    /// journal at once, so a crash loses at most this much typing.
    var journalDebounce: Duration = .zero

    /// The app's timing: journal at most every 250 ms per note.
    static let app = StoreTiming(journalDebounce: .milliseconds(250))
}

enum FileObservation: Equatable, Sendable {
    case disk, ownWrite
}

struct NoteSnapshot: Equatable, Sendable {
    let id: NoteID
    let collectionToken: CollectionToken
    let fileURL: URL
    let fileRevision: FileRevision?
    let text: String
    let availability: NoteAvailability
    var fileObservation: FileObservation? = nil
    var accessFailure: NoteAccessFailure? = nil
    var editRevision = EditRevision(rawValue: 0)
    var locationRevision = LocationRevision()
    /// The current backing file's creation date. Nil when it couldn't be read.
    var createdAt: Date? = nil
}

struct NoteCopySource: Sendable {
    let note: NoteSnapshot
    let editRevision: EditRevision
    let text: String
}

struct EditSnapshot: Sendable {
    let id: NoteID
    let collectionToken: CollectionToken
    let revision: EditRevision
    let baseRevision: FileRevision?
    let text: String
    var locationRevision = LocationRevision()
}

enum NoteOperationError: Error, Equatable, Sendable {
    case accessFailure(NoteAccessFailure)
    case conflict
    case permissionDenied
    case unavailable
    case unsupportedEncoding
    /// Display text resolves in the presentation locale. Infrastructure supplies a resource, never a formatted string.
    case inputOutput(LocalizedStringResource)
    /// A move to `destination` is still pending; finish it before choosing another location.
    case unfinishedMove(destination: URL)
    /// Move To… was interrupted. `underlying` is the system's own (already localized) description.
    case moveInterrupted(underlying: String?)
    /// A rename or Save As location change was interrupted.
    case locationChangeInterrupted(underlying: String?)
    case cancelled
    case staleCollection
    case staleLocation
    case destinationOccupied
    case invalidFilename
    case locationOperationPending
    /// Restore File Access got a file other than the tracked one.
    case notOriginalFile
    /// Remove from List found the original file again, so the note stays tracked.
    case originalNotMissing


}

enum SaveResult: Sendable {
    case saved(revision: EditRevision, fileRevision: FileRevision)
    case recovered(RetainedEditSummary)
    case failed(NoteOperationError)
}

struct RecoveryNotice: Codable, Equatable, Sendable {
    let originalURL: URL
    let recoveryURL: URL
    let originalMissing: Bool
    let recoveryNoteID: NoteID
    var sourceNoteID: NoteID? = nil
}

/// Application notifications, including progress and derived snapshots; not domain events.
enum NoteEvent: Sendable {
    case saveStatus(NoteID, CollectionToken, StorageSaveStatus)
    /// The verified file state after a save, so callers need no re-read.
    case saved(NoteSnapshot)
    case notice(RecoveryNotice)
    case discovered(NoteSnapshot)
    case changed(NoteSnapshot)
    /// A different resource replaces the old binding; retained text belongs to recovery.
    case rebound(NoteSnapshot)
    case removed(NoteID, CollectionToken)
    case failed(NoteID?, NoteOperationError)
}

protocol Clock: Sendable { func now() -> Date }

struct SystemClock: Clock { func now() -> Date { Date() } }

// Before applying a result, callers check the collection token and the note's location and edit revisions.
// A cancelled operation reports success only if the write reached disk.

enum StorageSaveStatus: Equatable, Sendable {
    case saved(EditRevision)
    case pending(EditRevision)
    case failed(EditRevision, NoteOperationError, journaled: Bool)
    case recoverable(EditRevision, URL)
}

protocol FileGrant: Sendable { var url: URL { get } }

protocol FolderGrant: Sendable { var url: URL { get } }

struct NoteLocation: Equatable, Sendable {
    let id: NoteID
    let revision: LocationRevision
}

struct DefaultFolderResultBatch: Equatable, Sendable {
    enum State: String, Sendable { case running, paused, settled }
    struct Entry: Equatable, Sendable {
        enum State: String, Sendable { case pending, moved, failed }
        let sourceID: NoteID
        let sourceURL: URL
        let destination: URL
        let state: State
        let message: String?
    }
    let id: UUID
    let state: State
    let entries: [Entry]
}

struct NoteMoveResult: Sendable {
    enum Outcome: Sendable { case unchanged, moved, failed(NoteOperationError), interrupted(UUID) }
    let noteID: NoteID
    let location: NoteLocation
    let outcome: Outcome
    var error: NoteOperationError? = nil
}

struct DefaultFolderChangeResult: Sendable {
    let batch: DefaultFolderResultBatch?
    let folder: URL
    let collectionToken: CollectionToken
    var error: NoteOperationError? = nil
    var unchanged: Bool { batch == nil }
}

extension NoteSaveState {
    mutating func completedSave(_ result: SaveResult) {
        if case let .saved(revision, _) = result { completedSave(revision: revision) }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
