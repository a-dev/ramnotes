import XCTest
import ramnotesDomain
@testable import ramnotes

final class RecoverySaveStateTests: XCTestCase {
    func testRecoveryDoesNotAdvanceOriginalSavedRevision() {
        var state = NoteSaveState()
        let revision = state.edited()
        let record = RecoveryRecord(id: UUID(), noteID: NoteID(), collectionToken: CollectionToken(),
            originalURL: URL(fileURLWithPath: "/original.txt"), folderIdentity: nil,
            originalResourceIdentity: nil, baseRevision: nil, editRevision: revision, text: "draft",
            createdAt: .distantPast, reason: .conflict)
        state.completedSave(.recovered(RetainedEditSummary(record)))
        XCTAssertTrue(state.hasUnsavedEdits)
        XCTAssertEqual(state.savedRevision.rawValue, 0)
        state.completedSave(revision: EditRevision(rawValue: 99))
        XCTAssertTrue(state.hasUnsavedEdits)
    }

    func testRetainedEditSummaryMapsIdentityTextAndReason() throws {
        let noteID = NoteID()
        let promoted = NoteID()
        for (stored, expected) in [(RecoveryRecord.Reason.conflict, RetainedEditSummary.Reason.conflict),
                                   (.missingOriginal, .missingOriginal), (.saveFailure, .saveFailure)] {
            let record = RecoveryRecord(id: UUID(), noteID: noteID, collectionToken: CollectionToken(),
                originalURL: URL(fileURLWithPath: "/notes/original.txt"), folderIdentity: "folder",
                originalResourceIdentity: "resource", baseRevision: nil, editRevision: EditRevision(rawValue: 7),
                text: "retained\ntext", createdAt: Date(timeIntervalSince1970: 42), reason: stored,
                promotionURL: URL(fileURLWithPath: "/notes/rn-1.txt"), promotedNoteID: promoted)
            let summary = RetainedEditSummary(record)
            XCTAssertEqual(summary.id, record.id)
            XCTAssertEqual(summary.noteID, noteID)
            XCTAssertEqual(summary.originalURL, record.originalURL)
            XCTAssertEqual(summary.text, "retained\ntext")
            XCTAssertEqual(summary.editRevision, EditRevision(rawValue: 7))
            XCTAssertEqual(summary.createdAt, Date(timeIntervalSince1970: 42))
            XCTAssertEqual(summary.reason, expected)
            // The persisted record keeps its schema; mapping doesn't touch the encoded journal.
            let decoded = try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(decoded, record)
        }
    }

    func testBatchForgetRemovesOnlyNamedNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root, fault: { _ in })
        let ids = [NoteID(), NoteID(), NoteID()]
        for id in ids {
            try store.write(RecoveryRecord(id: UUID(), noteID: id, collectionToken: CollectionToken(),
                originalURL: URL(fileURLWithPath: "/o.txt"), baseRevision: nil, editRevision: EditRevision(rawValue: 1),
                text: "t", createdAt: .distantPast, reason: .saveFailure))
        }
        let failures = try store.forget(Set(ids.prefix(2)))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(store.load().records.map(\.noteID), [ids[2]])
    }
}
