import XCTest
import ramnotesDomain

final class NoteRulesTests: XCTestCase {
    func testAccessRenewalRequiresVerifiedFileIdentity() {
        XCTAssertTrue(NoteFileIdentityPolicy.permitsRenewal(tracked: "volume:file", selected: "volume:file"))
        XCTAssertFalse(NoteFileIdentityPolicy.permitsRenewal(tracked: "volume:file", selected: "other:file"))
        XCTAssertFalse(NoteFileIdentityPolicy.permitsRenewal(tracked: nil, selected: nil))
        XCTAssertFalse(NoteFileIdentityPolicy.permitsRenewal(tracked: "volume:file", selected: nil))
    }

    func testTrackingRemovalPermitsAnyLostNote() {
        XCTAssertTrue(NoteTrackingRemovalPolicy.permitsRemoval(availability: .missingOriginal, confirmedMissing: true))
        XCTAssertFalse(NoteTrackingRemovalPolicy.permitsRemoval(availability: .missingOriginal, confirmedMissing: false))
        XCTAssertFalse(NoteTrackingRemovalPolicy.permitsRemoval(availability: .available, confirmedMissing: true))
        XCTAssertTrue(NoteTrackingRemovalPolicy.permitsRemoval(availability: .unavailable(reason: "Permission denied"), confirmedMissing: false))
        XCTAssertTrue(NoteTrackingRemovalPolicy.permitsRemoval(availability: .unavailable(reason: "A location operation needs retry or review."), confirmedMissing: false))
    }

    func testGeneratedFilenamesUseThreeShortWords() {
        var vocabulary = Set<String>()
        for index in 0..<1_295 {
            let generator = NoteFilenameGenerator(randomIndex: { range in
                XCTAssertEqual(range, 0..<1_295)
                return index
            })
            let name = generator.next()
            let words = name.dropFirst(3).dropLast(4).split(separator: "-")
            XCTAssertTrue(name.hasPrefix("rn-"))
            XCTAssertTrue(name.hasSuffix(".txt"))
            XCTAssertEqual(words.count, 3)
            XCTAssertEqual(Set(words).count, 1)
            for word in words {
                XCTAssertTrue((1...5).contains(word.count))
                XCTAssertTrue(word.utf8.allSatisfy { (97...122).contains($0) })
            }
            vocabulary.insert(String(words[0]))
            XCTAssertNotNil(NoteFilename(name))
        }
        XCTAssertEqual(vocabulary.count, 1_295)
        XCTAssertEqual(NoteFilenameGenerator(randomIndex: { $0.lowerBound }).next(), "rn-acid-acid-acid.txt")
        XCTAssertEqual(NoteFilenameGenerator(randomIndex: { $0.upperBound - 1 }).next(), "rn-zoom-zoom-zoom.txt")
    }

    func testOlderSaveDoesNotClearNewerEdit() {
        var state = NoteSaveState()
        let first = state.edited()
        _ = state.edited()
        state.completedSave(revision: first)
        XCTAssertTrue(state.hasUnsavedEdits)
        XCTAssertEqual(state.savedRevision, first)
    }

    func testValidatedNoteFilenamePreservesAcceptedNames() {
        for name in ["note.txt", "A.TXT", " .txt.txt", "日本語.txt", "a\\b.txt"] {
            XCTAssertEqual(NoteFilename(name)?.rawValue, name)
        }
        for name in ["", ".txt", ".TXT", "  .txt", "note.md", "a/b.txt", "a:b.txt", "a\0.txt"] {
            XCTAssertNil(NoteFilename(name), name)
        }
    }

    func testLocationAdvancementRejectsStaleRequest() {
        let old = LocationRevision()
        var current = old
        current.advance()
        XCTAssertFalse(current.matches(old))
        XCTAssertTrue(current.matches(old.advanced()))
    }

    func testSavePolicyEqualOwnWriteAndExternalConflict() {
        func decide(equal: Bool = false, disk: String = "external", base: String? = "base",
                    own: String? = nil, bases: Set<String> = [], valid: Bool = true) -> NoteSavePolicy.Decision {
            NoteSavePolicy.decide(equalContent: equal, diskFingerprint: disk, baseFingerprint: base,
                lastWrittenFingerprint: own, ownBaseFingerprints: bases, validEncoding: valid)
        }
        XCTAssertEqual(decide(equal: true), .unchanged)
        XCTAssertEqual(decide(disk: "base"), .replace)
        XCTAssertEqual(decide(own: "external", bases: ["base"]), .replace)
        XCTAssertEqual(decide(own: "external"), .conflict)
        XCTAssertEqual(decide(bases: ["base"]), .conflict)
        XCTAssertEqual(decide(base: nil, own: "external", bases: ["base"]), .conflict)
        XCTAssertEqual(decide(equal: true, valid: false), .unsupportedEncoding)
        XCTAssertEqual(decide(valid: false), .conflict)
    }

    func testRetainedEditDisposalRequiresVerifiedCopyOfCurrentRevision() {
        let first = EditRevision(rawValue: 1), newer = EditRevision(rawValue: 2)
        XCTAssertFalse(RetainedEditPolicy(writing: false, pendingRevision: first, recoverableRevision: nil).canDispose)
        XCTAssertFalse(RetainedEditPolicy(writing: false, pendingRevision: newer, recoverableRevision: first).canDispose)
        XCTAssertTrue(RetainedEditPolicy(writing: false, pendingRevision: first, recoverableRevision: first).canDispose)
        XCTAssertFalse(RetainedEditPolicy(writing: true, pendingRevision: nil, recoverableRevision: first).canDispose)
        XCTAssertTrue(RetainedEditPolicy(writing: false, pendingRevision: nil, recoverableRevision: nil).canDispose)
        let requested = LocationRevision()
        var different = requested
        different.advance()
        let rows: [(label: String, current: LocationRevision?, known: Bool, recovered: Bool, expected: Bool)] = [
            ("nil, unknown, not recovered", nil, false, false, false),
            ("nil, unknown, recovered", nil, false, true, false),
            ("nil, known, not recovered", nil, true, false, false),
            ("nil, known, recovered", nil, true, true, true),
            ("match, unknown, not recovered", requested, false, false, true),
            ("match, unknown, recovered", requested, false, true, true),
            ("match, known, not recovered", requested, true, false, true),
            ("match, known, recovered", requested, true, true, true),
            ("mismatch, unknown, not recovered", different, false, false, false),
            ("mismatch, unknown, recovered", different, false, true, false),
            ("mismatch, known, not recovered", different, true, false, false),
            ("mismatch, known, recovered", different, true, true, false),
        ]
        for row in rows {
            XCTAssertEqual(RetainedEditPolicy.acceptsLocation(current: row.current, requested: requested,
                hasKnownLocation: row.known, recovered: row.recovered), row.expected, row.label)
        }
    }

    func testCollectionRegistrationConflictRule() {
        let firstID = NoteID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let secondID = NoteID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        let registration = CollectionRegistration(id: firstID, parentResource: "parent-a", path: "/notes/A.txt")

        XCTAssertFalse(registration.conflicts(with: registration), "An existing ID may retain its location.")
        XCTAssertFalse(registration.conflicts(with: .init(id: firstID, parentResource: "parent-a", path: "/notes/B.txt")))
        XCTAssertTrue(registration.conflicts(with: .init(id: secondID, parentResource: "parent-a", path: "/notes/A.txt")))
        XCTAssertFalse(registration.conflicts(with: .init(id: secondID, parentResource: "parent-b", path: "/notes/A.txt")))
        XCTAssertFalse(registration.conflicts(with: .init(id: secondID, parentResource: "parent-a", path: "/notes/B.txt")))
    }

    func testLocationOperationStagesAdvanceOnlyThroughAdjacentCheckpoints() {
        let stages: [LocationOperationStage] = [.prepared, .destinationVerified, .sourceRemoved, .catalogCommitted, .complete]
        for (index, stage) in stages.enumerated() {
            for (nextIndex, next) in stages.enumerated() {
                XCTAssertEqual(stage.canAdvance(to: next), nextIndex == index + 1,
                    "Unexpected transition from \(stage) to \(next)")
            }
        }
    }
    func testLocationOperationEvidenceAndTransitions() throws {
        let id = NoteID()
        func state(stage: LocationOperationStage = .prepared, resource: String? = nil,
                   sourceID: NoteID? = nil, sourceResource: String? = "source",
                   sourceParent: String? = "parent", revision: FileRevision? = FileRevision(fingerprint: "f", modifiedAt: .distantPast),
                   destinationParent: String? = "destination", name: String? = "Moved.txt") -> LocationOperationState {
            LocationOperationState(noteID: id, sourceID: sourceID ?? id, sourceResource: sourceResource,
                sourceParentResource: sourceParent, expectedFileRevision: revision,
                destinationParentResource: destinationParent, destinationName: name, stage: stage, destinationResource: resource)
        }
        for incomplete in [state(sourceID: NoteID()), state(sourceResource: nil), state(sourceParent: nil),
                           state(revision: nil), state(destinationParent: nil), state(name: nil),
                           state(name: "bad"), state(stage: .destinationVerified)] {
            XCTAssertThrowsError(try incomplete.validateForExecution()) { XCTAssertEqual($0 as? LocationOperationState.Failure, .missingEvidence) }
        }
        var operation = state()
        XCTAssertThrowsError(try operation.advance(to: .sourceRemoved))
        XCTAssertThrowsError(try operation.verifyDestination(""))
        try operation.verifyDestination("resource")
        XCTAssertThrowsError(try operation.verifyDestination("other"))
        XCTAssertThrowsError(try operation.abandonPrepared())
        try operation.advance(to: .sourceRemoved)
        XCTAssertThrowsError(try operation.advance(to: .complete))
        try operation.advance(to: .catalogCommitted)
        try operation.advance(to: .complete)
        XCTAssertEqual(operation.destinationResource, "resource")
        var abandoned = state(revision: nil)
        try abandoned.abandonPrepared()
        XCTAssertEqual(abandoned.stage, .complete)
        var touched = state(resource: "resource")
        XCTAssertThrowsError(try touched.abandonPrepared())
    }

}
