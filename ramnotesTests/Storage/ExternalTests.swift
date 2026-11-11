import ramnotesDomain
import Darwin
import XCTest
@testable import ramnotes

final class ExternalTests: XCTestCase {
    func testPresentationVerificationRetriesWhenFileChangesDuringSnapshotRead() async throws {
        let fixture = try TestFixture()
        let replacement = ReadReplacementController()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: externalHooks,
            readBody: replacement.readBody)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("during-scan.txt")
        try Data("original".utf8).write(to: url)
        let selection = try await store.openSelectedFolder()
        let note = try XCTUnwrap(selection.notes.first)
        try atomicReplace(Data("first external version".utf8), at: url)
        replacement.arm(replacingWith: Data("latest external version".utf8))

        let verified = try await store.verifyForPresentation(note)

        XCTAssertEqual(verified.id, note.id)
        XCTAssertEqual(verified.fileURL, url)
        XCTAssertEqual(verified.text, "latest external version")
        XCTAssertEqual(try Data(contentsOf: url), Data("latest external version".utf8))
    }

    func testRepeatedPresentationVerificationSkipsUnchangedDefaultFileBookmarks() async throws {
        let fixture = try TestFixture()
        let resolutions = BookmarkResolutionCounter()
        let hooks = FolderAccessHooks(bookmark: { Data($0.path.utf8) }, resolve: { data in
            let path = String(decoding: data, as: UTF8.self)
            resolutions.record(path)
            return (URL(fileURLWithPath: path), false)
        }, start: { _ in true }, stop: { _ in })
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks)
        let folder = await store.defaultFolder()
        try Data("unchanged".utf8).write(to: folder.appendingPathComponent("unchanged.txt"))
        let selection = try await store.openSelectedFolder()
        let note = try XCTUnwrap(selection.notes.first)
        let identity = await store.identities.identity(note.id)
        XCTAssertNotNil(identity?.fileAccess?.bookmark, "The test note must have a saved per-file bookmark.")
        let resolutionsBeforeVerification = resolutions.count(for: note.fileURL.path)

        for _ in 0..<3 {
            let verified = try await store.verifyForPresentation(note)
            XCTAssertEqual(verified.text, "unchanged")
        }

        XCTAssertEqual(resolutions.count(for: note.fileURL.path), resolutionsBeforeVerification,
            "Unchanged default-folder notes are proven by the candidate snapshot and need no per-note bookmark resolution.")
    }

    func testPresentationVerificationDetectsTimestampOnlyBackwardChange() async throws {
        let prepared = try await makeExternalNote()
        let timestamp = try XCTUnwrap(prepared.note.fileRevision?.modifiedAt).addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: prepared.note.fileURL.path)
        let verified = try await prepared.store.verifyForPresentation(prepared.note)
        XCTAssertEqual(verified.text, prepared.note.text)
        XCTAssertEqual(verified.fileRevision?.modifiedAt.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(verified.fileObservation, .disk)
    }

    func testPresentationVerificationRecognizesOwnSaveAndPreservesConflict() async throws {
        let prepared = try await makeExternalNote()
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "local")
        guard case .saved = await prepared.store.save(edit) else { return XCTFail("Expected save") }
        let own = try await prepared.store.verifyForPresentation(prepared.note)
        XCTAssertEqual(own.fileObservation, .ownWrite)
        let next = EditSnapshot(id: own.id, collectionToken: own.collectionToken,
            revision: EditRevision(rawValue: 2), baseRevision: own.fileRevision, text: "retained draft")
        _ = await prepared.store.submit(next)
        try atomicReplace(Data("external".utf8), at: own.fileURL)
        let external = try await prepared.store.verifyForPresentation(own)
        XCTAssertEqual(external.fileObservation, .disk)
        XCTAssertEqual(external.text, "external")
        let notices = await prepared.store.recoveryNotices()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(notices.first).recoveryURL, encoding: .utf8), "retained draft")
    }

    func testAvailabilityRetryPublishesTimestampOnlyObservation() async throws {
        let prepared = try await makeExternalNote()
        let timestamp = try XCTUnwrap(prepared.note.fileRevision?.modifiedAt).addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: prepared.note.fileURL.path)
        _ = try await prepared.store.retryAvailability(prepared.note.id, collectionToken: prepared.collectionToken)
        let refreshed = await prepared.store.records[prepared.note.id]
        XCTAssertEqual(refreshed?.fileObservation, .disk)
        XCTAssertEqual(refreshed?.fileRevision?.modifiedAt.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPresentationVerificationDefersDuringComposition() async throws {
        let prepared = try await makeExternalNote()
        try await prepared.store.setWriting(true, for: prepared.note.id)
        try atomicReplace(Data("external".utf8), at: prepared.note.fileURL)
        do {
            _ = try await prepared.store.verifyForPresentation(prepared.note)
            XCTFail("Composition must prevent presentation")
        } catch { XCTAssertEqual(error as? NoteOperationError, .cancelled) }
        try await prepared.store.setWriting(false, for: prepared.note.id)
        let verified = try await prepared.store.verifyForPresentation(prepared.note)
        XCTAssertEqual(verified.text, "external")
    }

    func testOrdinaryEditDoesNotScanOtherNotesBeforeTheirExternalEvent() async throws {
        let prepared = try await makeExternalNote()
        let other = try await prepared.store.create(in: prepared.folder, collectionToken: prepared.collectionToken)
        try Data("external change".utf8).write(to: other.fileURL)
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "typing")

        try await prepared.store.finishWriting(edit)

        let cached = await prepared.store.records[other.id]
        let retained = await prepared.store.retainedBuffer(edit.id)
        XCTAssertEqual(cached?.text, "", "Ordinary typing must not read the entire folder.")
        XCTAssertEqual(retained?.text, "typing")
        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let refreshed = await prepared.store.records[other.id]
        XCTAssertEqual(refreshed?.text, "external change")
        try await prepared.store.flush()
    }

    func testCleanAtomicExternalChangeReloadsSameNoteIdentity() async throws {
        let prepared = try await makeExternalNote()
        let replacement = Data("external version".utf8)
        try atomicReplace(replacement, at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let cached = await prepared.store.records[prepared.note.id]
        let notices = await prepared.store.recoveryNotices()

        XCTAssertEqual(cached?.id, prepared.note.id)
        XCTAssertEqual(cached?.text, "external version")
        XCTAssertEqual(cached?.fileURL, prepared.note.fileURL)
        XCTAssertTrue(notices.isEmpty)
    }

    func testDirtyExternalChangePreservesDiskVersionAndPromotesLocalDraft() async throws {
        let prepared = try await makeExternalNote()
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "local draft")
        _ = await prepared.store.submit(edit)
        let storedJournal = await prepared.store.journalRecords[edit.id]
        let journalID = try XCTUnwrap(storedJournal?.id)
        try atomicReplace(Data("external version".utf8), at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let notices = await prepared.store.recoveryNotices()
        let promoted = try XCTUnwrap(try promotedNotes(in: prepared.folder).first)
        let currentOriginal = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)

        XCTAssertEqual(currentOriginal.text, "external version")
        XCTAssertEqual(try Data(contentsOf: promoted), Data("local draft".utf8))
        XCTAssertEqual(notices.first?.sourceNoteID, prepared.note.id)
        XCTAssertEqual(notices.count, 1)
        XCTAssertFalse(notices[0].originalMissing)
        XCTAssertEqual(notices[0].originalURL, prepared.note.fileURL)
        XCTAssertEqual(notices[0].recoveryURL, promoted)

        guard case .recovered(let repeatedRecord) = await prepared.store.save(edit) else {
            return XCTFail("Repeating a save after conflict promotion should return the same recovery result")
        }
        XCTAssertEqual(repeatedRecord.id, journalID)
        XCTAssertEqual(repeatedRecord.noteID, edit.id)
        let repeatedNotices = await prepared.store.recoveryNotices()
        XCTAssertEqual(repeatedNotices.map(\.recoveryNoteID), [notices[0].recoveryNoteID])
        XCTAssertEqual(try promotedNotes(in: prepared.folder).count, 1)

        // Promotion registers the recovery note directly. A later scan must keep that identity.
        let recoveryID = try XCTUnwrap(notices[0].recoveryNoteID)
        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let records = await prepared.store.records
        XCTAssertEqual(records[recoveryID]?.fileURL, promoted)
        XCTAssertEqual(records[recoveryID]?.text, "local draft")
        XCTAssertEqual(records.count, 2)
    }

    func testCleanDeletionEmitsRemovedEvent() async throws {
        let prepared = try await makeExternalNote()
        let stream = await prepared.store.events()
        var iterator = stream.makeAsyncIterator()
        await prepared.store.emit(.failed(nil, .cancelled))
        try FileManager.default.removeItem(at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let noteID = prepared.note.id
        let event = try await nextEvent(from: &iterator) { event in
            if case .removed(let id, _) = event { return id == noteID }
            return false
        }
        guard case .removed(let id, let collectionToken) = event else {
            return XCTFail("Expected a removed event for the deleted note")
        }

        XCTAssertEqual(id, prepared.note.id)
        XCTAssertEqual(collectionToken, prepared.collectionToken)
    }

    func testDirtyDeletionPromotesDraftAndMarksOriginalMissing() async throws {
        let prepared = try await makeExternalNote()
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "unsaved after deletion")
        _ = await prepared.store.submit(edit)
        let storedJournal = await prepared.store.journalRecords[edit.id]
        let journalID = try XCTUnwrap(storedJournal?.id)
        try FileManager.default.removeItem(at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let notices = await prepared.store.recoveryNotices()
        let promoted = try XCTUnwrap(try promotedNotes(in: prepared.folder).first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: promoted), Data("unsaved after deletion".utf8))
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].originalMissing)
        XCTAssertEqual(notices[0].originalURL, prepared.note.fileURL)

        guard case .recovered(let repeatedRecord) = await prepared.store.save(edit) else {
            return XCTFail("Repeating a save after deletion promotion should return the same recovery result")
        }
        XCTAssertEqual(repeatedRecord.id, journalID)
        XCTAssertEqual(repeatedRecord.noteID, edit.id)
        let repeatedNotices = await prepared.store.recoveryNotices()
        XCTAssertEqual(repeatedNotices.map(\.recoveryNoteID), [notices[0].recoveryNoteID])
        XCTAssertEqual(try promotedNotes(in: prepared.folder).count, 1)

        let finalEdit = EditSnapshot(
            id: edit.id,
            collectionToken: prepared.collectionToken,
            revision: EditRevision(rawValue: 2),
            baseRevision: edit.baseRevision,
            text: "newer composition after deletion"
        )
        _ = await prepared.store.submit(finalEdit)
        let disposableBeforeSave = await prepared.store.canDispose(edit.id)
        let retainedFinal = await prepared.store.retainedBuffer(edit.id)
        let secondJournal = await prepared.store.journalRecords[edit.id]
        let secondJournalID = try XCTUnwrap(secondJournal?.id)

        XCTAssertFalse(disposableBeforeSave)
        XCTAssertEqual(retainedFinal?.revision, finalEdit.revision)
        XCTAssertEqual(retainedFinal?.text, finalEdit.text)

        guard case .recovered(let secondRecord) = await prepared.store.save(finalEdit) else {
            return XCTFail("A newer edit after deletion should be recovered without recreating the original")
        }
        guard case .recovered(let repeatedSecondRecord) = await prepared.store.save(finalEdit) else {
            return XCTFail("Repeating the newer save should return the cached recovery result")
        }
        let allPromoted = try promotedNotes(in: prepared.folder)
        let finalCopies = try allPromoted.filter { try Data(contentsOf: $0) == Data(finalEdit.text.utf8) }

        XCTAssertEqual(secondRecord.id, secondJournalID)
        XCTAssertEqual(secondRecord.noteID, edit.id)
        XCTAssertEqual(repeatedSecondRecord.id, secondRecord.id)
        XCTAssertEqual(repeatedSecondRecord.noteID, secondRecord.noteID)
        XCTAssertEqual(allPromoted.count, 2, "One promoted file should exist for each captured revision")
        XCTAssertEqual(finalCopies.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
    }

    func testRenameBeforeSaveKeepsIdentityAndWritesToRenamedPath() async throws {
        let prepared = try await makeExternalNote()
        let renamedURL = prepared.folder.appendingPathComponent("Renamed.txt")
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "saved after rename")
        try FileManager.default.moveItem(at: prepared.note.fileURL, to: renamedURL)

        guard case .saved = await prepared.store.save(edit) else {
            return XCTFail("Save should follow the note's renamed resource")
        }
        let read = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
        XCTAssertEqual(read.id, prepared.note.id)
        XCTAssertEqual(read.fileURL, renamedURL)
        XCTAssertEqual(read.text, "saved after rename")
    }

    func testRenameWithPendingEditPublishesNewURLAndKeepsDraft() async throws {
        let prepared = try await makeExternalNote()
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "dirty during rename")
        _ = await prepared.store.submit(edit)
        let stream = await prepared.store.events()
        var iterator = stream.makeAsyncIterator()
        await prepared.store.emit(.failed(nil, .cancelled))
        let renamedURL = prepared.folder.appendingPathComponent("Renamed.txt")
        try FileManager.default.moveItem(at: prepared.note.fileURL, to: renamedURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let noteID = prepared.note.id
        let event = try await nextEvent(from: &iterator) { event in
            if case .changed(let note) = event { return note.id == noteID }
            return false
        }
        guard case let .changed(note) = event else {
            return XCTFail("A rename under a dirty buffer should publish the new location")
        }
        let pending = await prepared.store.pending[edit.id]

        XCTAssertEqual(note.id, prepared.note.id)
        XCTAssertEqual(note.fileURL, renamedURL)
        XCTAssertEqual(pending?.text, edit.text)
        XCTAssertTrue(try promotedNotes(in: prepared.folder).isEmpty, "A pure rename is not a conflict")
    }

    func testRepeatedReconcileDoesNotPromoteDraftTwice() async throws {
        let prepared = try await makeExternalNote()
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "single recovery copy")
        _ = await prepared.store.submit(edit)
        try atomicReplace(Data("external version".utf8), at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let notices = await prepared.store.recoveryNotices()
        let promoted = try promotedNotes(in: prepared.folder)
        let original = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(promoted.count, 1)
        XCTAssertEqual(try Data(contentsOf: promoted[0]), Data("single recovery copy".utf8))
        XCTAssertEqual(original.text, "external version")
    }

    func testStaleExternalEventGenerationIsIgnored() async throws {
        let prepared = try await makeExternalNote()
        let staleGeneration = CollectionToken()
        try atomicReplace(Data("external version".utf8), at: prepared.note.fileURL)

        await prepared.store.externalEvent(collectionToken: staleGeneration)
        let cached = await prepared.store.records[prepared.note.id]
        let notices = await prepared.store.recoveryNotices()

        XCTAssertNotEqual(staleGeneration, prepared.collectionToken)
        XCTAssertEqual(cached?.text, "original")
        XCTAssertTrue(notices.isEmpty)
    }

    func testActiveWritingDefersReloadUntilWritingEnds() async throws {
        let prepared = try await makeExternalNote()
        try await prepared.store.setWriting(true, for: prepared.note.id)
        try atomicReplace(Data("external version".utf8), at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let whileWriting = await prepared.store.records[prepared.note.id]
        XCTAssertEqual(whileWriting?.text, "original")

        try await prepared.store.setWriting(false, for: prepared.note.id)
        let afterWriting = await prepared.store.records[prepared.note.id]
        XCTAssertEqual(afterWriting?.text, "external version")
    }

    func testDirtyConflictDuringCompositionWaitsForFinalWritingSnapshot() async throws {
        let prepared = try await makeExternalNote()
        let firstComposition = EditSnapshot(
            id: prepared.note.id,
            collectionToken: prepared.collectionToken,
            revision: EditRevision(rawValue: 1),
            baseRevision: prepared.note.fileRevision,
            text: "intermediate composition"
        )
        _ = await prepared.store.submit(firstComposition)
        try await prepared.store.setWriting(true, for: prepared.note.id)
        try atomicReplace(Data("external version".utf8), at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let noticesWhileWriting = await prepared.store.recoveryNotices()
        let canDisposeWhileWriting = await prepared.store.canDispose(prepared.note.id)

        XCTAssertTrue(noticesWhileWriting.isEmpty)
        XCTAssertFalse(canDisposeWhileWriting)

        let finalComposition = EditSnapshot(
            id: prepared.note.id,
            collectionToken: prepared.collectionToken,
            revision: EditRevision(rawValue: 2),
            baseRevision: prepared.note.fileRevision,
            text: "final marked-text composition"
        )
        try await prepared.store.finishWriting(finalComposition)

        let notices = await prepared.store.recoveryNotices()
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(try Data(contentsOf: notice.recoveryURL), Data("final marked-text composition".utf8))
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("external version".utf8))
    }

    func testExternalEventSchedulesReconcile() async throws {
        let prepared = try await makeExternalNote()
        await prepared.store.startObserving()
        try atomicReplace(Data("observed version".utf8), at: prepared.note.fileURL)
        await prepared.store.externalEvent(collectionToken: prepared.collectionToken)
        try await waitUntil {
            await prepared.store.records[prepared.note.id]?.text == "observed version"
        }
    }

    func testCustomConflictUsesCurrentDefaultAndPersistsLinksAcrossRestart() async throws {
        let prepared = try await makeExternalNote()
        let next = prepared.fixture.root.appendingPathComponent("Next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        _ = try await prepared.store.changeDefaultFolder(to: next, moveExisting: false, from: prepared.collectionToken)
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "custom draft")
        _ = await prepared.store.submit(edit)
        try atomicReplace(Data("external".utf8), at: prepared.note.fileURL)
        guard case .recovered = await prepared.store.save(edit) else { return XCTFail("Expected recovery") }
        let promoted = try XCTUnwrap(try promotedNotes(in: next).first)
        XCTAssertEqual(promoted.deletingLastPathComponent().path, next.path)
        XCTAssertTrue(promoted.lastPathComponent.hasPrefix("rn-"))
        XCTAssertEqual(try String(contentsOf: promoted, encoding: .utf8), edit.text)
        let restarted = try NoteStore(support: prepared.fixture.root, folderAccessHooks: externalHooks)
        _ = try await restarted.openSelectedFolder()
        let links = await restarted.recoveryNotices()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.sourceNoteID, prepared.note.id)
        XCTAssertEqual(links.first?.originalURL, prepared.note.fileURL)
        XCTAssertEqual(links.first?.recoveryURL.lastPathComponent, promoted.lastPathComponent)
        XCTAssertEqual(try promotedNotes(in: next).count, 1)
    }

    func testUnavailableDefaultRetainsCustomDraftAcrossRestartAndPromotesOnceOnReturn() async throws {
        let prepared = try await makeExternalNote()
        let next = prepared.fixture.root.appendingPathComponent("Next")
        let detached = prepared.fixture.root.appendingPathComponent("Detached")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        _ = try await prepared.store.changeDefaultFolder(to: next, moveExisting: false, from: prepared.collectionToken)
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "retained custom draft")
        _ = await prepared.store.submit(edit)
        try atomicReplace(Data("external".utf8), at: prepared.note.fileURL)
        try FileManager.default.moveItem(at: next, to: detached)
        guard case .failed = await prepared.store.save(edit) else { return XCTFail("Unavailable default must fail promotion") }
        let retained = await prepared.store.retainedRecovery()
        XCTAssertEqual(retained.edits.first?.text, edit.text)
        XCTAssertTrue(try promotedNotes(in: prepared.folder).isEmpty)
        let restarted = try NoteStore(support: prepared.fixture.root, folderAccessHooks: externalHooks)
        _ = try await restarted.openSelectedFolder()
        let afterRestart = await restarted.retainedRecovery()
        XCTAssertEqual(afterRestart.edits.first?.text, edit.text)
        XCTAssertTrue(try promotedNotes(in: detached).isEmpty)
        try FileManager.default.moveItem(at: detached, to: next)
        let returned = try NoteStore(support: prepared.fixture.root, folderAccessHooks: externalHooks)
        _ = try await returned.openSelectedFolder()
        _ = await returned.replayRecovery()
        XCTAssertEqual(try promotedNotes(in: next).count, 1)
        let finished = await returned.retainedRecovery()
        XCTAssertTrue(finished.edits.isEmpty)
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "external")
    }

    func testRestartAfterEveryPromotionCheckpointDoesNotDuplicate() async throws {
        for stage in [StorageStage.promotion, .promotionCreated, .promotionCatalog] {
            let prepared = try await makeExternalNote(fault: { if $0 == stage { throw NoteOperationError.cancelled } })
            let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "checkpoint draft")
            _ = await prepared.store.submit(edit)
            try atomicReplace(Data("external".utf8), at: prepared.note.fileURL)
            guard case .failed = await prepared.store.save(edit) else { return XCTFail("Expected checkpoint interruption") }
            let interruptedRecords = await prepared.store.journalRecords
            let interruptedRecord = try XCTUnwrap(interruptedRecords[edit.id])
            let reservedPromotion = try XCTUnwrap(interruptedRecord.promotionURL)
            let initialFileCount = stage == .promotion ? 0 : 1
            XCTAssertEqual(try promotedNotes(in: prepared.folder).count, initialFileCount)
            let restarted = try NoteStore(support: prepared.fixture.root, folderAccessHooks: externalHooks)
            _ = try await restarted.openSelectedFolder()
            _ = await restarted.replayRecovery()
            XCTAssertEqual(try promotedNotes(in: prepared.folder).count, 1)
            let links = await restarted.recoveryNotices()
            XCTAssertEqual(links.count, 1)
            let catalog = await restarted.identities.catalog
            let link = try XCTUnwrap(catalog.recoveryLinks[interruptedRecord.id])
            XCTAssertEqual(link.sourceNoteID, edit.id)
            XCTAssertEqual(link.recoveryURL, reservedPromotion)
            XCTAssertNotNil(link.recoveryNoteID)
            if let promotedNoteID = interruptedRecord.promotedNoteID {
                XCTAssertEqual(link.recoveryNoteID, promotedNoteID)
            }
            XCTAssertEqual(try Data(contentsOf: reservedPromotion), Data(edit.text.utf8))
            XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("external".utf8))
            _ = await restarted.replayRecovery()
            XCTAssertEqual(try promotedNotes(in: prepared.folder).count, 1)
            let linksAfterSecondReplay = await restarted.recoveryNotices()
            XCTAssertEqual(linksAfterSecondReplay.count, 1)
            XCTAssertEqual(try Data(contentsOf: reservedPromotion), Data(edit.text.utf8))
            let retained = await restarted.retainedRecovery()
            XCTAssertTrue(retained.edits.isEmpty)
        }
    }

    func testNewerRevisionAfterPromotionCatalogInterruptionGetsSeparateRecoveryIdentity() async throws {
        let prepared = try await makeExternalNote(fault: { if $0 == .promotionCatalog { throw NoteOperationError.cancelled } })
        let first = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "first preserved revision")
        _ = await prepared.store.submit(first)
        try atomicReplace(Data("external".utf8), at: prepared.note.fileURL)
        guard case .failed = await prepared.store.save(first) else { return XCTFail("Expected catalog interruption") }
        let second = EditSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            revision: EditRevision(rawValue: 2), baseRevision: prepared.note.fileRevision, text: "newer preserved revision")
        _ = await prepared.store.submit(second)
        let secondSave = await prepared.store.save(second)
        guard case .failed(.cancelled) = secondSave else {
            return XCTFail("The newer revision should reach the injected catalog interruption")
        }
        let copies = try promotedNotes(in: prepared.folder)
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(Set(try copies.map { try String(contentsOf: $0, encoding: .utf8) }), Set([first.text, second.text]))
        let restarted = try NoteStore(support: prepared.fixture.root, folderAccessHooks: externalHooks)
        _ = try await restarted.openSelectedFolder()
        let links = await restarted.recoveryNotices()
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(try promotedNotes(in: prepared.folder).count, 2)
        let retained = await restarted.retainedRecovery()
        XCTAssertTrue(retained.edits.isEmpty)
    }

    func testRestartCompletesInterruptedPromotionExactlyOnce() async throws {
        let faults = PromotionFaultController()
        faults.failNextPromotion()
        let prepared = try await makeExternalNote(fault: faults.handler)
        let edit = makeExternalEdit(prepared.note, collectionToken: prepared.collectionToken, text: "local version")
        _ = await prepared.store.submit(edit)
        try atomicReplace(Data("external version".utf8), at: prepared.note.fileURL)

        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        guard case .failed(_, _, journaled: true) = await prepared.store.status(prepared.note.id) else {
            return XCTFail("Injected promotion interruption should leave a journal")
        }

        let recoveryStore = RecoveryStore(root: prepared.fixture.root.appendingPathComponent("Recovery"), fault: { _ in })
        let record = try XCTUnwrap(recoveryStore.load().records.first)
        let expectedPromotion = try XCTUnwrap(record.promotionURL)
        try Data("local version".utf8).write(to: expectedPromotion)

        let restartedStore = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        _ = try await restartedStore.discover(in: prepared.folder, collectionToken: prepared.collectionToken)
        let firstDiagnostics = await restartedStore.replayRecovery()
        let secondDiagnostics = await restartedStore.replayRecovery()
        let notices = await restartedStore.recoveryNotices()
        let promoted = try promotedNotes(in: prepared.folder)

        XCTAssertTrue(firstDiagnostics.isEmpty)
        XCTAssertTrue(secondDiagnostics.isEmpty)
        XCTAssertEqual(promoted, [expectedPromotion])
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("external version".utf8))
        XCTAssertEqual(try Data(contentsOf: expectedPromotion), Data("local version".utf8))
        XCTAssertEqual(notices.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryStore.url(prepared.note.id).path))
    }
}

private struct ExternalPreparedNote {
    let fixture: TestFixture
    let store: NoteStore
    let folder: URL
    let collectionToken: CollectionToken
    let note: NoteSnapshot
}

private func makeExternalNote(fault: @escaping StorageFault = { _ in }) async throws -> ExternalPreparedNote {
    let fixture = try TestFixture()
    let store = try NoteStore(support: fixture.root, clock: fixture.clock, fault: fault, folderAccessHooks: externalHooks)
    let folder = await store.defaultFolder()
    let url = folder.appendingPathComponent("Existing.txt")
    try Data("original".utf8).write(to: url)
    let collectionToken = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: collectionToken)
    return ExternalPreparedNote(fixture: fixture, store: store, folder: folder, collectionToken: collectionToken, note: try XCTUnwrap(notes.first))
}

private func makeExternalEdit(_ note: NoteSnapshot, collectionToken: CollectionToken, text: String) -> EditSnapshot {
    EditSnapshot(id: note.id, collectionToken: collectionToken, revision: EditRevision(rawValue: 1), baseRevision: note.fileRevision, text: text)
}

private func atomicReplace(_ data: Data, at url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".external-\(UUID()).tmp")
    try data.write(to: temporary)
    guard Darwin.rename(temporary.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: temporary)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func promotedNotes(in folder: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("rn-") && $0.pathExtension == "txt" }
        .sorted { $0.path < $1.path }
}

private final class PromotionFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    var handler: StorageFault {
        { [self] stage in
            guard case .promotion = stage else { return }
            lock.lock()
            let fail = shouldFail
            shouldFail = false
            lock.unlock()
            if fail { throw NoteOperationError.inputOutput("Injected interruption during promotion") }
        }
    }

    func failNextPromotion() {
        lock.lock()
        shouldFail = true
        lock.unlock()
    }
}

private var externalHooks: FolderAccessHooks {
    FolderAccessHooks(bookmark: { Data($0.path.utf8) },
        resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
        start: { _ in true }, stop: { _ in })
}

private final class BookmarkResolutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    func count(for path: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == path }.count }
}

private final class ReadReplacementController: @unchecked Sendable {
    private let lock = NSLock()
    private var replacement: Data?

    var readBody: @Sendable (URL) throws -> Data { { [self] url in
        let data = try Data(contentsOf: url)
        lock.lock()
        let next = replacement
        replacement = nil
        lock.unlock()
        if let next { try atomicReplace(next, at: url) }
        return data
    } }

    func arm(replacingWith data: Data) {
        lock.lock(); replacement = data; lock.unlock()
    }
}
