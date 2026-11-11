import ramnotesDomain
import XCTest
@testable import ramnotes

/// Pure reconcile decisions. No disk, no store, no sleeps.
final class ReconcileDiffTests: XCTestCase {
    private let token = CollectionToken()
    private let id = NoteID()
    private let url = URL(fileURLWithPath: "/notes/a.txt")
    private let movedURL = URL(fileURLWithPath: "/notes/b.txt")

    private func rev(_ f: String) -> FileRevision { FileRevision(fingerprint: f, modifiedAt: Date(timeIntervalSince1970: 0)) }

    private func note(_ url: URL? = nil, _ f: String = "1", _ availability: NoteAvailability = .available) -> NoteSnapshot {
        NoteSnapshot(id: id, collectionToken: token, fileURL: url ?? self.url, fileRevision: rev(f), text: "t", availability: availability)
    }

    private func edit(base: String = "1") -> EditSnapshot {
        EditSnapshot(id: id, collectionToken: token, revision: EditRevision(rawValue: 2), baseRevision: rev(base), text: "local")
    }

    private func diff(previous: [NoteSnapshot], scanned: [NoteSnapshot], pending: [EditSnapshot] = [],
                      session: CollectionSession = CollectionSession(), missing: Set<NoteID> = []) -> ReconcileDiff {
        var edits = EditState()
        for e in pending { edits.pending[e.id] = e }
        return ReconcileDiff(previous: Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) }), scanned: scanned,
                             edits: edits, session: session, missingFiles: missing, token: token)
    }

    func testNewNoteIsDiscoveredAndUnchangedNoteHasNoEffect() {
        XCTAssertTrue(diff(previous: [note()], scanned: [note()]).effects.isEmpty)
        guard case .discovered(let n)? = diff(previous: [], scanned: [note()]).effects.first else { return XCTFail() }
        XCTAssertEqual(n.fileObservation, .disk)
    }

    func testChangedAndRemovedNotes() {
        guard case .changed(let n)? = diff(previous: [note()], scanned: [note(nil, "2")]).effects.first else { return XCTFail() }
        XCTAssertEqual(n.fileRevision, rev("2"))
        guard case .removed(let removed)? = diff(previous: [note()], scanned: []).effects.first else { return XCTFail() }
        XCTAssertEqual(removed, id)
    }

    func testOwnWriteIsObserved() {
        var session = CollectionSession()
        session.lastWritten[id] = rev("2")
        XCTAssertEqual(diff(previous: [], scanned: [note(nil, "2")], session: session).current.first?.fileObservation, .ownWrite)
    }

    func testTrashedNoteWithEditIsRetained() {
        let effects = diff(previous: [note()], scanned: [note(nil, "1", .trashed)], pending: [edit()]).effects
        guard case .retainTrashed(_, let old, let disk)? = effects.first else { return XCTFail() }
        XCTAssertEqual(old.availability, .available)
        XCTAssertEqual(disk.availability, .trashed)
        guard case .publish? = diff(previous: [note()], scanned: [note(nil, "1", .trashed)]).effects.first else { return XCTFail() }
    }

    func testWritingNoteKeepsOldTextAndPublishesMove() {
        var session = CollectionSession()
        session.writing = [id]
        guard case .keep? = diff(previous: [note()], scanned: [note(nil, "2")], session: session).effects.first else { return XCTFail() }
        guard case .publish(let moved)? = diff(previous: [note()], scanned: [note(movedURL, "2")], session: session).effects.first
        else { return XCTFail() }
        XCTAssertEqual(moved.fileURL, movedURL)
        XCTAssertEqual(moved.fileRevision, rev("1"))
    }

    func testEditOnChangedFileIsPromoted() {
        guard case .reconcileEdit(let plan)? = diff(previous: [note()], scanned: [note(nil, "2")], pending: [edit()]).effects.first,
              case .changed(let target)? = plan.promotion else { return XCTFail() }
        XCTAssertEqual(target, url)
        XCTAssertNil(plan.rebound)
    }

    func testEditOnMissingFileIsPromotedOnlyWhenMissing() {
        guard case .reconcileEdit(let gone)? = diff(previous: [note()], scanned: [], pending: [edit()], missing: [id]).effects.first,
              case .missing? = gone.promotion else { return XCTFail() }
        guard case .reconcileEdit(let unreadable)? = diff(previous: [note()], scanned: [], pending: [edit()]).effects.first
        else { return XCTFail() }
        XCTAssertNil(unreadable.promotion)
    }

    func testMovedEditIsReboundWithoutPromotion() {
        guard case .reconcileEdit(let plan)? = diff(previous: [note()], scanned: [note(movedURL)], pending: [edit()]).effects.first
        else { return XCTFail() }
        XCTAssertNotNil(plan.rebound)
        XCTAssertNil(plan.promotion)
        XCTAssertFalse(plan.refreshJournal)
    }

    func testOwnWriteUnderEditRefreshesJournal() {
        var session = CollectionSession()
        session.lastWritten[id] = rev("2")
        session.journalRecords[id] = nil
        guard case .reconcileEdit(let noJournal)? = diff(previous: [note()], scanned: [note(nil, "2")], pending: [edit()],
                                                         session: session).effects.first else { return XCTFail() }
        XCTAssertNil(noJournal.promotion)
        XCTAssertFalse(noJournal.refreshJournal)
        guard case .reconcileEdit(let moved)? = diff(previous: [note()], scanned: [note(movedURL, "2")], pending: [edit()],
                                                     session: session).effects.first else { return XCTFail() }
        XCTAssertTrue(moved.refreshJournal)
    }
}
