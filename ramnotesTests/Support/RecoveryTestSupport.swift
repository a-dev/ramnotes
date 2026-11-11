import ramnotesDomain
import AppKit
import XCTest
@testable import ramnotes

/// Records messages and supplies note capabilities. Other host actions do nothing.
@MainActor
final class TestRecoveryHost: RecoveryHost {
    var recoveryNotes: (any RecoveryNotes)?
    var folder: FolderSelection?
    let folderState = FolderState()
    var messages: [String] = []
    var revealed: [NoteID] = []
    var windows: WindowCoordinator?
    var metadataStore: MetadataStore? { nil }
    var metadataDelivery: MetadataPersistence? { nil }
    var recoveryBlocked: Bool { false }
    init(store: NoteStore) { recoveryNotes = store }
    func showMessage(_ text: String) { messages.append(text) }
    func refreshList() {}
    func showList() {}
    func revealNote(_ id: NoteID) { revealed.append(id) }
    var persistCount = 0
    func persistMetadata() { persistCount += 1 }
}

struct RecoveryPreparedNote {
    let fixture: TestFixture
    let store: NoteStore
    let folder: URL
    let collectionToken: CollectionToken
    let note: NoteSnapshot
}

func makeRecoveryNote(
    failJournalAndDestination: Bool = false,
    failDestination: Bool = false,
    filename: String = "Recovery test.txt"
) async throws -> RecoveryPreparedNote {
    let fixture = try TestFixture()
    let fault: StorageFault = { stage in
        switch stage {
        case .journal where failJournalAndDestination:
            throw NoteOperationError.permissionDenied
        case .destination where failJournalAndDestination || failDestination:
            throw NoteOperationError.permissionDenied
        default:
            return
        }
    }
    let store = try NoteStore(support: fixture.root, clock: fixture.clock, fault: fault)
    let folder = await store.defaultFolder()
    let url = folder.appendingPathComponent(filename)
    try Data("original".utf8).write(to: url)
    let collectionToken = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: collectionToken)
    return RecoveryPreparedNote(fixture: fixture, store: store, folder: folder,
                                collectionToken: collectionToken, note: try XCTUnwrap(notes.first))
}

