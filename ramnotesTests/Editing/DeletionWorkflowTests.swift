import ramnotesDomain
import XCTest
@testable import ramnotes

@MainActor
final class DeletionWorkflowTests: XCTestCase {
    func testEditorFlushesBeforeTrashAndReleasesLockAfterSuccess() async throws {
        let note = snapshot()
        let storage = DeletionStorage()
        let workflow = DeletionWorkflow()
        var events: [String] = []
        var deleted: [NoteID] = []

        let result = await workflow.delete([note], in: note.collectionToken, using: storage,
            isCurrent: { true }, canProceed: { true }, editor: { _ in
                DeletionEditor(flush: { events.append("flush") }, release: { events.append("release") })
            }, didDelete: { id in events.append("removed"); deleted.append(id) })

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(events, ["flush", "removed", "release"])
        XCTAssertEqual(deleted, [note.id])
        let actuallyDeleted = await storage.deletedIDs
        XCTAssertEqual(actuallyDeleted, [note.id])
    }

    func testBatchFailureKeepsPriorSuccessAndContinuesLaterNotes() async throws {
        let token = CollectionToken()
        let notes = [snapshot(token), snapshot(token), snapshot(token)]
        let storage = DeletionStorage(failing: [notes[1].id])
        let workflow = DeletionWorkflow()
        var deleted: [NoteID] = []

        let result = await workflow.delete(notes, in: notes[0].collectionToken, using: storage,
            isCurrent: { true }, canProceed: { true }, editor: { _ in nil },
            didDelete: { deleted.append($0) })

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failures.map { $0.0.id }, [notes[1].id])
        XCTAssertEqual(deleted, [notes[0].id, notes[2].id])
        let actuallyDeleted = await storage.deletedIDs
        XCTAssertEqual(actuallyDeleted, [notes[0].id, notes[2].id])
    }

    func testLifecycleChangeStopsBatchAfterCompletedDeletion() async throws {
        let token = CollectionToken()
        let notes = [snapshot(token), snapshot(token)]
        let storage = DeletionStorage()
        let workflow = DeletionWorkflow()
        var canProceed = true
        var released = false
        var deleted: [NoteID] = []

        let result = await workflow.delete(notes, in: notes[0].collectionToken, using: storage,
            isCurrent: { true }, canProceed: { canProceed }, editor: { _ in
                DeletionEditor(flush: { canProceed = false }, release: { released = true })
            }, didDelete: { deleted.append($0) })

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(released)
        XCTAssertEqual(deleted, [notes[0].id])
        let actuallyDeleted = await storage.deletedIDs
        XCTAssertEqual(actuallyDeleted, [notes[0].id])
    }

    func testUncommittedCompositionFailureKeepsNoteAndReleasesEditorLock() async throws {
        let note = snapshot()
        let storage = DeletionStorage()
        let workflow = DeletionWorkflow()
        var released = false

        let result = await workflow.delete([note], in: note.collectionToken, using: storage,
            isCurrent: { true }, canProceed: { true }, editor: { _ in
                DeletionEditor(flush: { throw NoteOperationError.unavailable }, release: { released = true })
            }, didDelete: { _ in XCTFail("A note with unfinished composition must not be removed") })

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.failures.map { $0.0.id }, [note.id])
        XCTAssertTrue(released)
        let actuallyDeleted = await storage.deletedIDs
        XCTAssertTrue(actuallyDeleted.isEmpty)
    }

    func testDeletionDoesNotConsumeIndependentTextUndoManager() async throws {
        let note = snapshot()
        let storage = DeletionStorage()
        let workflow = DeletionWorkflow()
        let textUndoManager = UndoManager()
        let probe = TextUndoProbe()
        textUndoManager.registerUndo(withTarget: probe) { $0.count += 1 }

        let result = await workflow.delete([note], in: note.collectionToken, using: storage,
            isCurrent: { true }, canProceed: { true }, editor: { _ in nil }, didDelete: { _ in })

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(textUndoManager.canUndo)
        XCTAssertEqual(probe.count, 0)
        textUndoManager.undo()
        XCTAssertEqual(probe.count, 1)
    }

    func testConcurrentDuplicateDeletionIsRejectedWhileTrashIsPending() async throws {
        let note = snapshot()
        let storage = SuspendedDeletionStorage()
        let workflow = DeletionWorkflow()
        let first = Task { @MainActor in
            await workflow.delete([note], in: note.collectionToken, using: storage,
                isCurrent: { true }, canProceed: { true }, editor: { _ in nil }, didDelete: { _ in })
        }
        await storage.waitUntilStarted()

        let duplicate = await workflow.delete([note], in: note.collectionToken, using: storage,
            isCurrent: { true }, canProceed: { true }, editor: { _ in nil },
            didDelete: { _ in XCTFail("A pending deletion must not be submitted twice") })

        XCTAssertEqual(duplicate.succeeded, 0)
        XCTAssertTrue(duplicate.failures.isEmpty)
        let callsWhilePending = await storage.callCount
        XCTAssertEqual(callsWhilePending, 1)
        await storage.finish()
        let completed = await first.value
        XCTAssertEqual(completed.succeeded, 1)
        XCTAssertTrue(completed.failures.isEmpty)
        let callsAfterCompletion = await storage.callCount
        XCTAssertEqual(callsAfterCompletion, 1)
    }
}

private actor DeletionStorage: NoteTrashing {
    private let failing: Set<NoteID>
    private(set) var deletedIDs: [NoteID] = []

    init(failing: Set<NoteID> = []) { self.failing = failing }

    func moveToTrash(_ id: NoteID, collectionToken: CollectionToken) async throws {
        if failing.contains(id) { throw NoteOperationError.permissionDenied }
        deletedIDs.append(id)
    }
}

private actor SuspendedDeletionStorage: NoteTrashing {
    private(set) var callCount = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?

    func moveToTrash(_ id: NoteID, collectionToken: CollectionToken) async throws {
        callCount += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { pending = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        pending?.resume()
        pending = nil
    }
}

private func snapshot(_ token: CollectionToken = CollectionToken()) -> NoteSnapshot {
    NoteSnapshot(id: NoteID(), collectionToken: token,
        fileURL: URL(fileURLWithPath: "/notes/note.txt"), fileRevision: nil,
        text: "text", availability: .available, editRevision: EditRevision(rawValue: 0))
}

@MainActor
private final class TextUndoProbe: NSObject {
    var count = 0
}
