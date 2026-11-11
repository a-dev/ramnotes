import ramnotesDomain
import Darwin
import XCTest
@testable import ramnotes

final class SavingTests: XCTestCase {
    func testSaveReadsOnlyTargetAndPreservesUnrelatedReconciliation() async throws {
        let fixture = try TestFixture()
        let reads = BodyReads()
        let store = try NoteStore(support: fixture.root, readBody: reads.read)
        let folder = await store.defaultFolder()
        let targetURL = folder.appendingPathComponent("Target.txt")
        let otherURL = folder.appendingPathComponent("Other.txt")
        try Data("original".utf8).write(to: targetURL)
        try Data("other".utf8).write(to: otherURL)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let target = try XCTUnwrap(notes.first { $0.fileURL == targetURL })
        let other = try XCTUnwrap(notes.first { $0.fileURL == otherURL })
        try Data("external change".utf8).write(to: otherURL)
        reads.reset()
        guard case .saved = await store.save(makeEdit(target, collectionToken: collectionToken, revision: 1, text: "saved")) else {
            return XCTFail("Target save should succeed")
        }
        XCTAssertFalse(reads.urls.isEmpty)
        XCTAssertEqual(Set(reads.urls), [targetURL])
        let before = await store.records[other.id]
        XCTAssertEqual(before?.text, "other")
        try await store.reconcile(collectionToken: collectionToken)
        let after = await store.records[other.id]
        XCTAssertEqual(after?.text, "external change")
    }

    func testSaveEventCarriesVerifiedSnapshotAfterItsStatus() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Target.txt")
        try Data("original".utf8).write(to: url)
        let collectionToken = CollectionToken()
        let discovered = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(discovered.first)
        let stream = await store.events()
        guard case .saved = await store.save(makeEdit(note, collectionToken: collectionToken, revision: 1, text: "saved")) else {
            return XCTFail("Save should succeed")
        }
        var iterator = stream.makeAsyncIterator()
        let firstRelevantEvent = try await nextEvent(from: &iterator) { event in
            switch event {
            case .saveStatus(note.id, _, .saved(EditRevision(rawValue: 1))): return true
            case .saved(let snapshot): return snapshot.id == note.id
            default: return false
            }
        }
        guard case .saveStatus(note.id, _, .saved(EditRevision(rawValue: 1))) = firstRelevantEvent else {
            return XCTFail("The saved snapshot must follow its saved status.")
        }
        let snapshotEvent = try await nextEvent(from: &iterator) { event in
            if case .saved(let snapshot) = event { return snapshot.id == note.id }
            return false
        }
        guard case let .saved(snapshot) = snapshotEvent else { return XCTFail("Expected a saved snapshot") }
        XCTAssertEqual(snapshot.text, "saved")
        XCTAssertEqual(snapshot.editRevision, EditRevision(rawValue: 1))
        let written = await store.lastWritten[note.id]
        XCTAssertEqual(snapshot.fileRevision, written)
    }

    func testDragCopyUsesUnsavedTextWithoutSavingOrClearingPendingEdit() async throws {
        let prepared = try await makeNote()
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "unsaved drag text")
        _ = await prepared.store.submit(edit)
        let destination = prepared.fixture.root.appendingPathComponent("drag-copy.txt")

        try await prepared.store.writeDragCopy(prepared.note, text: nil, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data(edit.text.utf8))
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
        let retained = await prepared.store.retainedBuffer(prepared.note.id)
        let pending = await prepared.store.hasPendingEdits()
        XCTAssertEqual(retained?.text, edit.text)
        XCTAssertEqual(retained?.revision, edit.revision)
        XCTAssertTrue(pending)
        let liveDestination = prepared.fixture.root.appendingPathComponent("live-drag-copy.txt")
        try await prepared.store.writeDragCopy(prepared.note, text: "newest editor text", to: liveDestination)
        XCTAssertEqual(try Data(contentsOf: liveDestination), Data("newest editor text".utf8))
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testDragCopyRejectsMissingOriginalWithoutCreatingOutput() async throws {
        let prepared = try await makeNote()
        try FileManager.default.removeItem(at: prepared.note.fileURL)
        let destination = prepared.fixture.root.appendingPathComponent("drag-copy.txt")

        do {
            try await prepared.store.writeDragCopy(prepared.note, text: "stale text", to: destination)
            XCTFail("A missing original must not be exported")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .unavailable)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDragCopyRejectsMovedSourceAndSwitchedCollection() async throws {
        let prepared = try await makeNote()
        let movedURL = prepared.note.fileURL.deletingLastPathComponent().appendingPathComponent("Moved.txt")
        let moved = await prepared.store.moveNote(prepared.note.id, to: movedURL,
            collectionToken: prepared.collectionToken, locationRevision: prepared.note.locationRevision,
            editRevision: prepared.note.editRevision)
        guard case .moved = moved.outcome else { return XCTFail("Fixture move failed: \(moved)") }
        let destination = prepared.fixture.root.appendingPathComponent("stale-copy.txt")
        do {
            try await prepared.store.writeDragCopy(prepared.note, text: "captured text", to: destination)
            XCTFail("A moved original invalidates the promise")
        } catch let error as NoteOperationError { XCTAssertEqual(error, .unavailable) }
        let current = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)
        let reopened = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        _ = try await reopened.openSelectedFolder()
        do {
            try await reopened.writeDragCopy(current, text: "captured text", to: destination)
            XCTFail("A switched collection invalidates the promise")
        } catch let error as NoteOperationError { XCTAssertEqual(error, .staleCollection) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: movedURL), Data("original".utf8))
    }

    func testIdentityMapIsWrittenOnlyWhenItChanges() async throws {
        // Repeated identity writes increase disk traffic during autosave.
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Target.txt")
        try Data("original".utf8).write(to: url)
        let collectionToken = CollectionToken()
        let discovered = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(discovered.first)
        let identityURL = fixture.root.appendingPathComponent("collection.json")
        func fileID() throws -> String? { try StorageFiles.fileResourceID(identityURL) }
        func stored() throws -> String? {
            let map = try CatalogPersistence.load(at: identityURL)
            return map.notes[note.id]?.resource
        }
        let initial = try fileID()

        try await store.reconcile(collectionToken: collectionToken)
        XCTAssertEqual(try fileID(), initial, "An unchanged scan must not rewrite collection.json.")

        guard case .saved = await store.save(makeEdit(note, collectionToken: collectionToken, revision: 1, text: "saved")) else {
            return XCTFail("Save should succeed")
        }
        // Atomic replacement changes the file ID. The map tracks it in memory first.
        let current = try StorageFiles.fileResourceID(url)
        let known = await store.knownResourceIdentity(note.id)
        XCTAssertEqual(known, current)
        XCTAssertEqual(try fileID(), initial, "An autosave must not rewrite collection.json synchronously.")
        XCTAssertNotEqual(try stored(), current)

        try await store.flush(note.id)
        XCTAssertEqual(try stored(), current, "An explicit flush makes the refreshed identity durable.")
        let flushed = try fileID()
        try await store.flush(note.id)
        XCTAssertEqual(try fileID(), flushed, "A clean map is not written again.")
    }

    func testReconcileReadsOnlyBodiesWhoseStatChanged() async throws {
        let fixture = try TestFixture()
        let reads = BodyReads()
        let store = try NoteStore(support: fixture.root, readBody: reads.read)
        let folder = await store.defaultFolder()
        let urls = (0..<5).map { folder.appendingPathComponent("Note \($0).txt") }
        for url in urls { try Data("same".utf8).write(to: url) }
        let collectionToken = CollectionToken()
        _ = try await store.discover(in: folder, collectionToken: collectionToken)

        reads.reset()
        try await store.reconcile(collectionToken: collectionToken)
        XCTAssertEqual(reads.urls, [], "An unchanged folder must reconcile from stat alone.")

        // Same size, so only mtime and ctime tell it apart.
        try Data("next".utf8).write(to: urls[2])
        reads.reset()
        try await store.reconcile(collectionToken: collectionToken)
        XCTAssertEqual(reads.urls, [urls[2]])
        let changed = await store.records.values.first { $0.fileURL == urls[2] }
        XCTAssertEqual(changed?.text, "next")
    }

    func testOwnSaveIsCachedForLaterReconcile() async throws {
        let fixture = try TestFixture()
        let reads = BodyReads()
        let store = try NoteStore(support: fixture.root, readBody: reads.read)
        let folder = await store.defaultFolder()
        let targetURL = folder.appendingPathComponent("Target.txt")
        try Data("original".utf8).write(to: targetURL)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        guard case .saved = await store.save(makeEdit(note, collectionToken: collectionToken, revision: 1, text: "saved")) else {
            return XCTFail("Save should succeed")
        }
        reads.reset()
        try await store.reconcile(collectionToken: collectionToken)
        XCTAssertEqual(reads.urls, [], "Verified bytes from our own save must not be read again.")
        let record = await store.records[note.id]
        XCTAssertEqual(record?.text, "saved")
    }

    func testOwnSaveDoesNotScheduleReconcile() async throws {
        let debounce: Duration = .milliseconds(20)
        let prepared = try await makeNote(timing: StoreTiming(reconcileDebounce: debounce))
        await prepared.store.startObserving()
        let baseline = await prepared.store.reconcileCount
        guard case .saved = await prepared.store.save(makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "saved")) else {
            return XCTFail("Save should succeed")
        }
        try await waitUntil {
            (try? Data(contentsOf: prepared.note.fileURL)) == Data("saved".utf8)
        }
        // Exercise the same event path as presenter delivery, without depending on its latency.
        await prepared.store.externalEvent(collectionToken: prepared.collectionToken, at: prepared.note.fileURL)
        try await Task.sleep(for: debounce * 5)
        let passes = await prepared.store.reconcileCount
        XCTAssertEqual(passes, baseline, "Our verified save must not schedule a reconcile.")
    }

    func testSaveIsNotBlockedBehindAnInFlightReconcile() async throws {
        let fixture = try TestFixture()
        let gate = ReadGate()
        let store = try NoteStore(support: fixture.root, readBody: gate.read)
        let folder = await store.defaultFolder()
        let targetURL = folder.appendingPathComponent("Target.txt")
        // Sorts after the target, so the stalled scan has already captured the target's old body.
        let slowURL = folder.appendingPathComponent("Zed.txt")
        try Data("original".utf8).write(to: targetURL)
        try Data("slow".utf8).write(to: slowURL)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let target = try XCTUnwrap(notes.first { $0.fileURL == targetURL })
        let slow = try XCTUnwrap(notes.first { $0.fileURL == slowURL })
        try Data("slow external change".utf8).write(to: slowURL)
        gate.stall(slowURL)
        let reconcile = Task { try await store.reconcile(collectionToken: collectionToken) }
        defer { gate.release() }
        try await waitUntil { gate.isStalled }

        // Probe: with the scan on the actor, this save waits until the gate times out.
        let result = await store.save(makeEdit(target, collectionToken: collectionToken, revision: 1, text: "saved"))
        XCTAssertFalse(gate.timedOut, "The save did not finish while the reconcile was held; it must not queue behind folder I/O.")
        guard case .saved = result else { return XCTFail("Save should succeed") }
        gate.release()
        try await reconcile.value

        let records = await store.records
        XCTAssertEqual(records[target.id]?.text, "saved", "A scan that started before the save must not publish older bytes.")
        XCTAssertEqual(records[slow.id]?.text, "slow external change")
    }

    func testJournalWrittenThisSessionIsNotReReadOrRewrittenUnchanged() async throws {
        let faults = FaultController()
        faults.failNext(.destination, with: .inputOutput("destination write failed"))
        let prepared = try await makeNote(fault: faults.handler)
        let journalURL = recoveryURL(for: prepared.note.id, support: prepared.fixture.root)
        let first = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "one")
        _ = await prepared.store.submit(first)
        let submitted = try fileIdentity(journalURL)

        // The save journals the same record again before writing. It is already on disk.
        guard case .failed = await prepared.store.save(first) else { return XCTFail("Injected destination failure") }
        XCTAssertEqual(try fileIdentity(journalURL), submitted, "An unchanged journal must not be rewritten.")

        // Probe: we never re-read a journal we wrote, so a damaged copy can't block the next write.
        try Data("not json".utf8).write(to: journalURL)
        let second = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 2, text: "two")
        let status = await prepared.store.submit(second)
        XCTAssertEqual(status, .pending(second.revision))
        let journal = RecoveryStore(root: prepared.fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load()
        XCTAssertEqual(journal.records.map(\.text), ["two"])
        XCTAssertEqual(journal.diagnostics, [])
    }

    func testSaveFollowsRenameWhenFormerPathIsReplaced() async throws {
        let prepared = try await makeNote()
        let renamed = prepared.folder.appendingPathComponent("Renamed.txt")
        try FileManager.default.moveItem(at: prepared.note.fileURL, to: renamed)
        try Data("replacement".utf8).write(to: prepared.note.fileURL)
        let outcome = await prepared.store.save(makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "local"))
        guard case .saved = outcome else {
            return XCTFail("Save should follow original resource: \(outcome)")
        }
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "local")
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "replacement")
        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let records = await prepared.store.records
        XCTAssertEqual(records.count, 2)
    }

    func testSamePathReplacementIsComparedBeforeSave() async throws {
        let prepared = try await makeNote()
        let temporary = prepared.folder.appendingPathComponent("replacement.tmp")
        try Data("external".utf8).write(to: temporary)
        XCTAssertEqual(Darwin.rename(temporary.path, prepared.note.fileURL.path), 0)
        guard case .recovered = await prepared.store.save(makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "local")) else {
            return XCTFail("Replacement must conflict")
        }
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "external")
    }

    func testEditsAfterOneConflictUpdateTheSameRecoveryNote() async throws {
        let prepared = try await makeNote()
        try Data("external".utf8).write(to: prepared.note.fileURL)
        let first = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "local\n")
        guard case .recovered = await prepared.store.save(first) else {
            return XCTFail("The external change must conflict")
        }
        let second = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 2, text: "local\nM04 conflict word")
        guard case .recovered = await prepared.store.save(second) else {
            return XCTFail("A later edit in the same conflict window must stay recovered")
        }
        let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: prepared.folder.path)
            .filter { $0.hasPrefix("rn-") }
        XCTAssertEqual(recoveryFiles.count, 1)
        // One recovery note means the second edit updated the first promotion.
        let promoted = prepared.folder.appendingPathComponent(try XCTUnwrap(recoveryFiles.first))
        XCTAssertEqual(try String(contentsOf: promoted, encoding: .utf8), second.text)
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "external")
    }

    func testTargetReadFailureRetainsJournalAndNeverOverwrites() async throws {
        for failure in [NoteOperationError.permissionDenied, .unavailable] {
            let fixture = try TestFixture()
            let reads = BodyReads()
            let store = try NoteStore(support: fixture.root, readBody: reads.read)
            let folder = await store.defaultFolder()
            let url = folder.appendingPathComponent("Target.txt")
            try Data("original".utf8).write(to: url)
            let collectionToken = CollectionToken()
            let notes = try await store.discover(in: folder, collectionToken: collectionToken)
            let note = try XCTUnwrap(notes.first)
            reads.fail(with: failure)
            let edit = makeEdit(note, collectionToken: collectionToken, revision: 1, text: "retained")
            guard case .failed(let error) = await store.save(edit) else { return XCTFail("Read must fail") }
            XCTAssertEqual(error, failure)
            let status = await store.status(note.id)
            XCTAssertEqual(status, .failed(edit.revision, failure, journaled: true))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
            let journal = RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load()
            XCTAssertEqual(journal.records.first?.text, "retained")
        }
    }

    func testQuitAllowsJournaledEditThatCannotSave() async throws {
        let fixture = try TestFixture()
        let reads = BodyReads()
        let store = try NoteStore(support: fixture.root, readBody: reads.read)
        let folder = await store.defaultFolder()
        try Data("original".utf8).write(to: folder.appendingPathComponent("Target.txt"))
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        reads.fail(with: .permissionDenied)
        _ = await store.submit(makeEdit(note, collectionToken: collectionToken, revision: 1, text: "retained"))
        do { try await store.flush(); XCTFail("Close and folder changes still need a saved copy") } catch {}
        try await store.flushForQuit()
        let journal = RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load()
        XCTAssertEqual(journal.records.first?.text, "retained")
    }

    func testDirectSaveAfterDeletionPromotesJournaledText() async throws {
        let prepared = try await makeNote()
        try FileManager.default.removeItem(at: prepared.note.fileURL)
        guard case .recovered(let note) = await prepared.store.save(makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "retained")) else {
            return XCTFail("Deleted source should promote the draft")
        }
        XCTAssertEqual(note.text, "retained")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
    }

    func testAmbiguousResourceFallbackNeverOverwritesEitherCandidate() async throws {
        let prepared = try await makeNote()
        let alias = prepared.folder.appendingPathComponent("Alias.txt")
        try FileManager.default.linkItem(at: prepared.note.fileURL, to: alias)
        guard case .failed(.unavailable) = await prepared.store.save(makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "retained")) else {
            return XCTFail("Ambiguous identity must not authorize replacement")
        }
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "original")
        let buffer = await prepared.store.retainedBuffer(prepared.note.id)
        XCTAssertEqual(buffer?.text, "retained")
    }

    func testExternalWriteAfterReplacementIsNotTreatedAsOurOwnAdvance() async throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("Notes/Existing.txt")
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, fault: { stage in
            if case .afterReplacement = stage { try Data("external version".utf8).write(to: url) }
        })
        let folder = await store.defaultFolder()
        try Data("original".utf8).write(to: url)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        let first = makeEdit(note, collectionToken: collectionToken, revision: 1, text: "first local edit")
        guard case .saved = await store.save(first) else { return XCTFail("First write should succeed") }
        let second = makeEdit(note, collectionToken: collectionToken, revision: 2, text: "newer local edit")
        guard case .recovered(let recovery) = await store.save(second) else {
            return XCTFail("An external version must conflict even when it arrived immediately after our write")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external version")
        XCTAssertEqual(recovery.text, second.text)
    }

    func testOlderSaveCannotClearOrReplaceNewerEdit() async throws {
        let prepared = try await makeNote()
        let older = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "older")
        let newer = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 2, text: "newer")

        let olderStatus = await prepared.store.submit(older)
        let newerStatus = await prepared.store.submit(newer)
        XCTAssertEqual(olderStatus, .pending(older.revision))
        XCTAssertEqual(newerStatus, .pending(newer.revision))

        guard case .failed(.cancelled) = await prepared.store.save(older) else {
            return XCTFail("An older save should be rejected while a newer edit is pending")
        }
        guard case .saved(let savedRevision, _) = await prepared.store.save(newer) else {
            return XCTFail("The latest edit should save")
        }
        let read = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)
        let status = await prepared.store.status(prepared.note.id)
        let hasPendingEdits = await prepared.store.hasPendingEdits()

        XCTAssertEqual(savedRevision, newer.revision)
        XCTAssertEqual(read.text, "newer")
        XCTAssertEqual(status, .saved(newer.revision))
        XCTAssertFalse(hasPendingEdits)
    }

    func testSupersededEditIsNeverWrittenToTheNoteFile() async throws {
        let fixture = try TestFixture()
        let writes = NoteFileWrites()
        let debounce: Duration = .milliseconds(100)
        let store = try NoteStore(support: fixture.root, timing: StoreTiming(saveDebounce: debounce),
            writeBody: writes.write)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Existing.txt")
        try Data("original".utf8).write(to: url)
        let token = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: token)
        let note = try XCTUnwrap(notes.first)
        let first = makeEdit(note, collectionToken: token, revision: 1, text: "superseded A")
        let latest = makeEdit(note, collectionToken: token, revision: 2, text: "retained B")

        _ = await store.submit(first)
        _ = await store.submit(latest)
        // Export clears pending edits and cancels the latest save. A superseded task
        // must stay cancelled even after the newer pending revision is gone.
        let exported = fixture.root.appendingPathComponent("export.txt")
        try await store.export(note.id, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data(latest.text.utf8))
        try await Task.sleep(for: debounce * 3)
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))

        _ = await store.submit(latest)
        try await waitUntil { (try? Data(contentsOf: url)) == Data(latest.text.utf8) }
        try await Task.sleep(for: debounce * 3)

        let recorded = writes.values
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertTrue(recorded.allSatisfy { $0.url == url })
        XCTAssertFalse(recorded.contains { $0.data == Data(first.text.utf8) }, "Superseded A reached the note file")
        XCTAssertEqual(recorded.last?.data, Data(latest.text.utf8))
        XCTAssertEqual(try Data(contentsOf: url), Data(latest.text.utf8))
    }

    func testDebouncedSchedulerPersistsOnlyNewestEditAndCleansJournal() async throws {
        let prepared = try await makeNote(timing: StoreTiming(saveDebounce: .milliseconds(20)))
        let first = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "first scheduled version")
        let latest = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 2, text: "latest scheduled version")

        _ = await prepared.store.submit(first)
        _ = await prepared.store.submit(latest)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))

        try await waitUntil {
            let newest = (try? Data(contentsOf: prepared.note.fileURL)) == Data(latest.text.utf8)
            let journalIsEmpty = !FileManager.default.fileExists(atPath: recoveryURL(for: prepared.note.id, support: prepared.fixture.root).path)
            return newest && journalIsEmpty
        }

        let savedData = try Data(contentsOf: prepared.note.fileURL)
        let status = await prepared.store.status(prepared.note.id)
        let pending = await prepared.store.hasPendingEdits()
        let journalExists = FileManager.default.fileExists(atPath: recoveryURL(for: prepared.note.id, support: prepared.fixture.root).path)
        XCTAssertEqual(savedData, Data(latest.text.utf8))
        XCTAssertEqual(status, .saved(latest.revision))
        XCTAssertFalse(pending)
        XCTAssertFalse(journalExists)
    }

    func testCorruptChecksumAndTruncatedJournalAreRetainedWithDiagnostics() async throws {
        let faults = FaultController()
        faults.failNext(.destination, with: .permissionDenied)
        let prepared = try await makeNote(fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "recovered draft")
        _ = await prepared.store.submit(edit)
        guard case .failed(.permissionDenied) = await prepared.store.save(edit) else {
            return XCTFail("Injected destination permission failure should preserve the recovery journal")
        }
        let journalURL = recoveryURL(for: prepared.note.id, support: prepared.fixture.root)
        let validData = try Data(contentsOf: journalURL)
        var badChecksum = validData
        badChecksum[badChecksum.count - 1] ^= 0x01
        try badChecksum.write(to: journalURL)

        let restartedStore = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        _ = try await restartedStore.discover(in: prepared.folder, collectionToken: prepared.collectionToken)
        let checksumDiagnostics = await restartedStore.replayRecovery()

        XCTAssertFalse(checksumDiagnostics.isEmpty)
        XCTAssertEqual(try Data(contentsOf: journalURL), badChecksum)

        let truncated = Data([0x7b, 0x22])
        try truncated.write(to: journalURL)
        let truncationDiagnostics = await restartedStore.replayRecovery()

        XCTAssertFalse(truncationDiagnostics.isEmpty)
        XCTAssertEqual(try Data(contentsOf: journalURL), truncated)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testRestartReplaysPendingJournalAndCompletesDestinationSave() async throws {
        let faults = FaultController()
        faults.failNext(.destination, with: .permissionDenied)
        let prepared = try await makeNote(fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "replayed draft")
        _ = await prepared.store.submit(edit)
        guard case .failed(.permissionDenied) = await prepared.store.save(edit) else {
            return XCTFail("The initial save should leave a durable journal for restart")
        }
        let journalURL = recoveryURL(for: prepared.note.id, support: prepared.fixture.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let restartedStore = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        _ = try await restartedStore.discover(in: prepared.folder, collectionToken: prepared.collectionToken)
        let diagnostics = await restartedStore.replayRecovery()
        let read = try await restartedStore.read(prepared.note.id, collectionToken: prepared.collectionToken)
        let status = await restartedStore.status(prepared.note.id)
        let canDispose = await restartedStore.canDispose(prepared.note.id)

        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(read.text, "replayed draft")
        XCTAssertEqual(status, .saved(edit.revision))
        XCTAssertTrue(canDispose)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testJournalAndDestinationFailuresBlockDisposalUntilExport() async throws {
        let faults = FaultController()
        faults.failNext(.journal, with: .inputOutput("journal write failed"), count: 2)
        faults.failNext(.destination, with: .inputOutput("destination write failed"))
        let prepared = try await makeNote(fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "export me")

        let submitted = await prepared.store.submit(edit)
        XCTAssertEqual(submitted, .failed(edit.revision, .inputOutput("journal write failed"), journaled: false))
        guard case .failed(.inputOutput(_)) = await prepared.store.save(edit) else {
            return XCTFail("The destination failure should be reported")
        }
        let canDisposeBeforeExport = await prepared.store.canDispose(prepared.note.id)
        XCTAssertFalse(canDisposeBeforeExport)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))

        let exportURL = prepared.fixture.root.appendingPathComponent("exported-draft.txt")
        try await prepared.store.export(prepared.note.id, to: exportURL)
        let canDisposeAfterExport = await prepared.store.canDispose(prepared.note.id)
        let status = await prepared.store.status(prepared.note.id)

        XCTAssertTrue(canDisposeAfterExport)
        XCTAssertEqual(try Data(contentsOf: exportURL), Data("export me".utf8))
        XCTAssertEqual(status, .recoverable(edit.revision, exportURL))
    }

    func testPreReplacementFailureSchedulesRetry() async throws {
        let faults = FaultController()
        faults.failNext(.beforeReplacement, with: .inputOutput("catalog write failed"))
        let prepared = try await makeNote(timing: StoreTiming(saveDebounce: .seconds(60)), fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "retry me")
        guard case .failed(.inputOutput) = await prepared.store.save(edit) else { return XCTFail("Expected pre-replacement failure") }
        let count = await prepared.store.session.retryCounts[prepared.note.id]
        XCTAssertEqual(count, 1, "A failure before replacement must schedule a retry")
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testDiscardingUnsavedTextDropsEditAndJournalAndKeepsTheFile() async throws {
        let faults = FaultController()
        faults.failNext(.destination, with: .inputOutput("destination write failed"), count: 10)
        let prepared = try await makeNote(fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "lose me")
        _ = await prepared.store.submit(edit)
        guard case .failed = await prepared.store.save(edit) else { return XCTFail("The save should fail") }

        do {
            try await prepared.store.discardEdits(prepared.note.id, through: EditRevision(rawValue: 0))
            XCTFail("An older revision must not discard a newer edit")
        } catch let error as NoteOperationError { XCTAssertEqual(error, .conflict) }

        try await prepared.store.discardEdits(prepared.note.id, through: edit.revision)
        let disposable = await prepared.store.canDispose(prepared.note.id)
        let journal = await prepared.store.journalRecords[prepared.note.id]
        let status = await prepared.store.status(prepared.note.id)
        let retained = await prepared.store.retainedBuffer(prepared.note.id)
        XCTAssertTrue(disposable)
        XCTAssertNil(journal)
        XCTAssertNil(status)
        XCTAssertNil(retained)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testNativePermissionFailuresStopAutomaticRetryAndAllowRepair() async throws {
        let errors = [(NSCocoaErrorDomain, NSFileReadNoPermissionError),
                      (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
                      (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM))]
        for (domain, code) in errors {
            let faults = FaultController()
            faults.failNextNative(.destination, domain: domain, code: code)
            let prepared = try await makeNote(timing: StoreTiming(saveDebounce: .milliseconds(100)), fault: faults.handler)
            let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "retained draft")
            _ = await prepared.store.submit(edit)
            guard case let .failed(.accessFailure(failure)) = await prepared.store.save(edit) else {
                XCTFail("Expected native permission failure"); continue
            }
            XCTAssertEqual(failure.reason, .permission)
            XCTAssertEqual(failure.domain, domain)
            XCTAssertEqual(failure.code, code)
            let retryCount = await prepared.store.session.retryCounts[prepared.note.id]
            XCTAssertNil(retryCount, "Permission failure must not schedule a retry")
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
            let status = await prepared.store.status(prepared.note.id)
            XCTAssertEqual(status, .failed(edit.revision, .accessFailure(failure), journaled: true))
            let journal = try XCTUnwrap(RecoveryStore(root: prepared.fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load().records.first)
            XCTAssertEqual(journal.text, edit.text)
            guard case .saved = await prepared.store.retry(prepared.note.id) else { XCTFail("Retry after repair should save"); continue }
            XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data(edit.text.utf8))
        }
    }

    func testTypedAccessFailuresUseExpectedRetryPolicy() async throws {
        let cases: [(NoteAccessFailureReason, Bool)] = [
            (.folderAuthorization, false), (.permission, false), (.missingFile, true),
            (.unavailableVolume, true), (.cloudPlaceholder, true), (.unsupportedEncoding, true), (.unknown, true)
        ]
        for (reason, retryable) in cases {
            let faults = FaultController()
            let failure = NoteAccessFailure(reason: reason, domain: "test", code: 42, message: "test")
            faults.failNext(.destination, with: .accessFailure(failure), count: 4)
            let prepared = try await makeNote(fault: faults.handler)
            let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "draft")
            for attempt in 1...4 {
                guard case .failed(.accessFailure(failure)) = await prepared.store.save(edit) else {
                    XCTFail("Expected access failure"); break
                }
                let count = await prepared.store.session.retryCounts[prepared.note.id]
                XCTAssertEqual(count, retryable ? attempt : nil, "Unexpected retry policy for \(reason)")
            }
        }
    }

    func testNewEditSavesAfterPermissionRepair() async throws {
        let faults = FaultController()
        faults.failNextNative(.destination, domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let prepared = try await makeNote(timing: StoreTiming(saveDebounce: .milliseconds(20)), fault: faults.handler)
        let first = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "first draft")
        guard case .failed(.accessFailure) = await prepared.store.save(first) else { return XCTFail("Expected permission failure") }
        let latest = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 2, text: "new draft")
        _ = await prepared.store.submit(latest)
        try await waitUntil { (try? Data(contentsOf: prepared.note.fileURL)) == Data(latest.text.utf8) }
        let status = await prepared.store.status(prepared.note.id)
        XCTAssertEqual(status, .saved(latest.revision))
    }

    func testENOSPCIsReportedAndLeavesSourceAndRecoveryJournal() async throws {
        let faults = FaultController()
        faults.failNextENOSPC(.destination)
        let prepared = try await makeNote(fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "not saved yet")
        _ = await prepared.store.submit(edit)

        guard case let .failed(.accessFailure(failure)) = await prepared.store.save(edit) else {
            return XCTFail("ENOSPC should retain its underlying I/O error")
        }
        XCTAssertEqual(failure.reason, .unknown)
        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.code, Int(ENOSPC))
        XCTAssertTrue(String(localized: failure.message).localizedLowercase.contains("space"))
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL(for: prepared.note.id, support: prepared.fixture.root).path))
        let canDispose = await prepared.store.canDispose(prepared.note.id)
        XCTAssertFalse(canDispose)
    }

    func testDirectSaveAfterFolderDisappearsKeepsPendingEditAndJournal() async throws {
        let prepared = try await makeNote()
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "draft after folder loss")
        let movedFolder = prepared.fixture.root.appendingPathComponent("Notes unavailable", isDirectory: true)
        try FileManager.default.moveItem(at: prepared.folder, to: movedFolder)

        guard case .failed = await prepared.store.save(edit) else {
            return XCTFail("Saving after the notes folder disappears should fail")
        }

        let hasPendingEdits = await prepared.store.hasPendingEdits()
        let canDispose = await prepared.store.canDispose(prepared.note.id)
        let recoveryRecord = try XCTUnwrap(RecoveryStore(
            root: prepared.fixture.root.appendingPathComponent("Recovery"),
            fault: { _ in }
        ).load().records.first)

        XCTAssertTrue(hasPendingEdits)
        XCTAssertFalse(canDispose)
        XCTAssertEqual(recoveryRecord.noteID, prepared.note.id)
        XCTAssertEqual(recoveryRecord.text, edit.text)
    }

    func testSavePreservesBOMAndCRLFLineEndings() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("WindowsLines.txt")
        let originalData = Data([0xef, 0xbb, 0xbf]) + Data("First\r\nSecond\r\n".utf8)
        try originalData.write(to: url)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        let edit = makeEdit(note, collectionToken: collectionToken, revision: 1, text: "First updated\r\nSecond\r\n")
        _ = await store.submit(edit)

        guard case .saved = await store.save(edit) else {
            return XCTFail("The edit should save")
        }

        XCTAssertEqual(try Data(contentsOf: url), Data([0xef, 0xbb, 0xbf]) + Data("First updated\r\nSecond\r\n".utf8))
    }

    func testRetryAfterFailureDoesNotCreateDuplicateNotesOrJournals() async throws {
        let faults = FaultController()
        faults.failNext(.destination, with: .inputOutput("temporary destination failure"))
        let prepared = try await makeNote(fault: faults.handler)
        let edit = makeEdit(prepared.note, collectionToken: prepared.collectionToken, revision: 1, text: "saved once")
        _ = await prepared.store.submit(edit)
        guard case .failed(.inputOutput(_)) = await prepared.store.save(edit) else {
            return XCTFail("The injected first attempt should fail")
        }

        guard case .saved(let revision, _) = await prepared.store.retry(prepared.note.id) else {
            return XCTFail("Retry should save the pending edit")
        }
        let notes = try await prepared.store.discover(in: prepared.folder, collectionToken: prepared.collectionToken)
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: prepared.fixture.root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let status = await prepared.store.status(prepared.note.id)
        let hasPendingEdits = await prepared.store.hasPendingEdits()

        XCTAssertEqual(revision, edit.revision)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "saved once")
        XCTAssertTrue(recoveryFiles.isEmpty)
        XCTAssertEqual(status, .saved(edit.revision))
        XCTAssertFalse(hasPendingEdits)
    }
}

private struct PreparedNote {
    let fixture: TestFixture
    let store: NoteStore
    let folder: URL
    let collectionToken: CollectionToken
    let note: NoteSnapshot
}

private func makeNote(timing: StoreTiming = StoreTiming(), fault: @escaping StorageFault = { _ in }) async throws -> PreparedNote {
    let fixture = try TestFixture()
    let store = try NoteStore(support: fixture.root, clock: fixture.clock, timing: timing, fault: fault)
    let folder = await store.defaultFolder()
    let url = folder.appendingPathComponent("Existing.txt")
    try Data("original".utf8).write(to: url)
    let collectionToken = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: collectionToken)
    return PreparedNote(fixture: fixture, store: store, folder: folder, collectionToken: collectionToken, note: try XCTUnwrap(notes.first))
}

private func makeEdit(_ note: NoteSnapshot, collectionToken: CollectionToken, revision: UInt64, text: String) -> EditSnapshot {
    EditSnapshot(id: note.id, collectionToken: collectionToken, revision: EditRevision(rawValue: revision), baseRevision: note.fileRevision, text: text)
}

/// Atomic writes replace the inode, so an unchanged identifier means the file was not rewritten.
private func fileIdentity(_ url: URL) throws -> NSObject? {
    try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
}

private func recoveryURL(for id: NoteID, support: URL) -> URL {
    support.appendingPathComponent("Recovery", isDirectory: true).appendingPathComponent(id.rawValue.uuidString + ".json")
}

private final class FaultController: @unchecked Sendable {
    private enum StageKey: Hashable { case journal, beforeReplacement, destination }
    private enum InjectedFailure: Sendable {
        case operation(NoteOperationError)
        case posix(Int)
        case native(String, Int)
    }

    private let lock = NSLock()
    private var failures: [StageKey: [InjectedFailure]] = [:]

    var handler: StorageFault {
        { [self] stage in try check(stage) }
    }

    func failNext(_ stage: StorageStage, with error: NoteOperationError, count: Int = 1) {
        let key = Self.key(for: stage)
        guard count > 0, let key else { return }
        lock.lock()
        failures[key, default: []].append(contentsOf: repeatElement(.operation(error), count: count))
        lock.unlock()
    }

    func failNextNative(_ stage: StorageStage, domain: String, code: Int) {
        guard let key = Self.key(for: stage) else { return }
        lock.withLock { failures[key, default: []].append(.native(domain, code)) }
    }

    func failNextENOSPC(_ stage: StorageStage) {
        guard let key = Self.key(for: stage) else { return }
        lock.lock()
        failures[key, default: []].append(.posix(Int(ENOSPC)))
        lock.unlock()
    }

    private func check(_ stage: StorageStage) throws {
        guard let key = Self.key(for: stage) else { return }
        lock.lock()
        let failure = failures[key]?.isEmpty == false ? failures[key]?.removeFirst() : nil
        lock.unlock()
        switch failure {
        case let .operation(error): throw error
        case let .posix(code): throw NSError(domain: NSPOSIXErrorDomain, code: code)
        case let .native(domain, code): throw NSError(domain: domain, code: code)
        case nil: return
        }
    }

    private static func key(for stage: StorageStage) -> StageKey? {
        switch stage {
        case .journal: .journal
        case .beforeReplacement: .beforeReplacement
        case .destination: .destination
        case .accessMigrationCatalog, .copyVerification, .copyCatalog, .afterReplacement, .promotion, .promotionCreated, .promotionCatalog, .trash, .folderAccess, .movePrepared, .moveFilesystem, .moveAfterFilesystem, .moveAfterSourceRemoval, .moveVerified, .moveSourceRemoval, .moveSourceRemoved, .moveCatalog, .moveComplete, .defaultPrepared, .defaultCommit, .defaultCommitted, .defaultEntry, .defaultAfterMove, .defaultCheckpoint, .defaultComplete: nil
        }
    }
}

final class BodyReads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    private var failure: NoteOperationError?
    func fail(with error: NoteOperationError) { lock.withLock { failure = error } }
    var urls: [URL] { lock.withLock { values } }
    func reset() { lock.withLock { values.removeAll() } }
    @Sendable func read(_ url: URL) throws -> Data {
        let error = lock.withLock { values.append(url); return failure }
        if let error { throw error }
        return try Data(contentsOf: url)
    }
}

/// Pause the first read until release or the two-second timeout.
final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var name: String?
    private var stalled = false
    private var expired = false
    var isStalled: Bool { lock.withLock { stalled } }
    var timedOut: Bool { lock.withLock { expired } }
    func stall(_ url: URL) { lock.withLock { name = url.lastPathComponent } }
    func release() { gate.signal() }
    @Sendable func read(_ url: URL) throws -> Data {
        let wait = lock.withLock {
            guard url.lastPathComponent == name else { return false }
            name = nil
            stalled = true
            return true
        }
        if wait, gate.wait(timeout: .now() + 2) == .timedOut { lock.withLock { expired = true } }
        return try Data(contentsOf: url)
    }
}

/// Records each successful note replacement at the write boundary; journals use their own writer.
private final class NoteFileWrites: @unchecked Sendable {
    struct Write { let url: URL; let data: Data }
    private let lock = NSLock()
    private var recorded: [Write] = []
    var values: [Write] { lock.withLock { recorded } }
    @Sendable func write(_ data: Data, _ url: URL) throws {
        try StorageFiles.atomic(data, at: url)
        lock.withLock { recorded.append(Write(url: url, data: data)) }
    }
}

/// A clock the test moves by hand, so debounce tests need no sleeps.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
}

extension SavingTests {
    private func journalRecord(text: String) -> RecoveryRecord {
        RecoveryRecord(id: UUID(), noteID: NoteID(UUID()), collectionToken: CollectionToken(),
            originalURL: URL(fileURLWithPath: "/tmp/Note.txt"), folderIdentity: "volume:folder",
            baseRevision: FileRevision(fingerprint: "abc", modifiedAt: Date(timeIntervalSince1970: 100)),
            editRevision: EditRevision(rawValue: 7), text: text, createdAt: Date(timeIntervalSince1970: 200),
            reason: .saveFailure, promotedNoteID: nil)
    }

    func testRawTextJournalRoundTripsAndStoresBodyUnescaped() throws {
        let record = journalRecord(text: "Line one\nline \"two\" café 🌿\n")
        let data = try RecoveryStore.encode(record)
        XCTAssertTrue(data.starts(with: RecoveryStore.magic))
        XCTAssertTrue(data.suffix(Data(record.text.utf8).count) == Data(record.text.utf8), "The body is raw UTF-8.")
        XCTAssertEqual(try RecoveryStore.decode(data), record)
        XCTAssertEqual(try RecoveryStore.decode(RecoveryStore.encode(journalRecord(text: ""))).map(\.text), "")
    }

    func testLegacyJournalIsReadAndRewrittenInRawTextFormat() throws {
        let fixture = try TestFixture()
        let store = RecoveryStore(root: fixture.root, fault: { _ in })
        let record = journalRecord(text: "legacy body")
        let payload = try JSONEncoder().encode(record)
        let legacy = try JSONEncoder().encode(RecoveryStore.LegacyEnvelope(version: 1, payload: payload, checksum: StorageFiles.digest(payload)))
        try legacy.write(to: store.url(record.noteID))
        XCTAssertEqual(store.load().records, [record])

        let newer = RecoveryRecord(id: record.id, noteID: record.noteID, collectionToken: record.collectionToken,
            originalURL: record.originalURL, baseRevision: record.baseRevision, editRevision: EditRevision(rawValue: 8),
            text: "migrated", createdAt: record.createdAt, reason: record.reason, promotedNoteID: nil)
        XCTAssertTrue(try store.persist(newer))
        XCTAssertTrue(try Data(contentsOf: store.url(record.noteID)).starts(with: RecoveryStore.magic))
        XCTAssertEqual(store.load().records, [newer])
    }

    func testCorruptRawTextJournalIsPreservedAndNeverOverwritten() throws {
        let fixture = try TestFixture()
        let store = RecoveryStore(root: fixture.root, fault: { _ in })
        let record = journalRecord(text: "draft")
        var corrupt = try RecoveryStore.encode(record)
        corrupt[corrupt.count - 1] ^= 0x01
        try corrupt.write(to: store.url(record.noteID))

        XCTAssertNil(try RecoveryStore.decode(corrupt))
        let loaded = store.load()
        XCTAssertEqual(loaded.records, [])
        XCTAssertEqual(loaded.diagnostics.count, 1)
        XCTAssertThrowsError(try store.persist(record))
        XCTAssertEqual(try Data(contentsOf: store.url(record.noteID)), corrupt)

        let truncated = RecoveryStore.magic + Data("{\"id\"".utf8)
        try truncated.write(to: store.url(record.noteID))
        XCTAssertThrowsError(try store.persist(record))
        XCTAssertEqual(try Data(contentsOf: store.url(record.noteID)), truncated)
    }

    func testTypingJournalsCoalesceWithinDebounceAndFlushWritesNewest() async throws {
        let fixture = try TestFixture()
        let clock = ManualClock()
        let store = try NoteStore(support: fixture.root, clock: clock,
            timing: StoreTiming(saveDebounce: .seconds(3600), journalDebounce: .seconds(3600)))
        let folder = await store.defaultFolder()
        try Data("original".utf8).write(to: folder.appendingPathComponent("Existing.txt"))
        let token = CollectionToken()
        let discovered = try await store.discover(in: folder, collectionToken: token)
        let note = try XCTUnwrap(discovered.first)
        let recovery = RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in })
        func journaled() -> [String] { recovery.load().records.map(\.text) }

        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 1, text: "a"))
        XCTAssertEqual(journaled(), ["a"], "The first edit journals at once.")
        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 2, text: "ab"))
        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 3, text: "abc"))
        XCTAssertEqual(journaled(), ["a"], "Edits inside the debounce are coalesced.")

        clock.advance(3601)
        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 4, text: "abcd"))
        XCTAssertEqual(journaled(), ["abcd"], "An edit after the debounce journals at once.")

        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 5, text: "abcde"))
        XCTAssertEqual(journaled(), ["abcd"])
        // Flush writes the deferred journal before the note file, then the save removes it.
        try await store.flush(note.id)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "abcde")
        XCTAssertEqual(journaled(), [])
    }

    func testFlushForQuitWritesDeferredJournalWhenSaveFails() async throws {
        let fixture = try TestFixture()
        let clock = ManualClock()
        let faults = FaultController()
        let store = try NoteStore(support: fixture.root, clock: clock,
            timing: StoreTiming(saveDebounce: .seconds(3600), journalDebounce: .seconds(3600)), fault: faults.handler)
        let folder = await store.defaultFolder()
        try Data("original".utf8).write(to: folder.appendingPathComponent("Existing.txt"))
        let token = CollectionToken()
        let discovered = try await store.discover(in: folder, collectionToken: token)
        let note = try XCTUnwrap(discovered.first)
        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 1, text: "one"))
        _ = await store.submit(makeEdit(note, collectionToken: token, revision: 2, text: "two"))

        faults.failNext(.destination, with: .permissionDenied)
        try await store.flushForQuit()
        let recovery = RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in })
        XCTAssertEqual(recovery.load().records.map(\.text), ["two"], "Quit keeps the newest edit journaled.")
    }
}
