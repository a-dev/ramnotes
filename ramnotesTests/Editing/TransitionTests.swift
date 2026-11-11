import ramnotesDomain
import AppKit
import XCTest
@testable import ramnotes

@MainActor
final class TransitionTests: XCTestCase {
    func testFailedTransactionDoesNotEnableUnavailableEditorAndResetInheritsLocks() async throws {
        let prepared = try await makeTransitionNotes(count: 2)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.open(note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[note.id]?.editor)
        editor.applyExternal(NoteSnapshot(id: note.id, collectionToken: note.collectionToken,
            fileURL: note.fileURL, fileRevision: note.fileRevision, text: "", availability: .missingOriginal))
        let transaction = coordinator.beginEditingLock()
        do {
            _ = try await prepared.store.switchFolder(to: prepared.folder,
                from: CollectionToken())
            XCTFail("A stale collectionToken must fail")
        } catch { }
        coordinator.endEditingLock(transaction)
        XCTAssertFalse(editor.textView.isEditable)

        let first = coordinator.beginEditingLock()
        let second = coordinator.beginEditingLock()
        coordinator.remove(note.id)
        coordinator.reset()
        coordinator.open(prepared.notes[1], focus: false)
        let opened = try XCTUnwrap(coordinator.windows[prepared.notes[1].id]?.editor)
        XCTAssertFalse(opened.textView.isEditable)
        coordinator.endEditingLock(first)
        XCTAssertFalse(opened.textView.isEditable)
        coordinator.endEditingLock(second)
        XCTAssertTrue(opened.textView.isEditable)
    }

    func testGroupHideKeepsOpenNotesAndHidesList() async throws {
        let prepared = try await makeTransitionNotes()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        var listIsVisible = true
        var hideListCalled = false
        coordinator.listVisible = { listIsVisible }
        coordinator.hideList = {
            hideListCalled = true
            listIsVisible = false
        }
        for note in prepared.notes {
            coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
            coordinator.open(note, focus: false)
        }

        coordinator.perform(.hide)

        XCTAssertTrue(hideListCalled)
        XCTAssertFalse(coordinator.anyGroupVisible)
        XCTAssertTrue(coordinator.windows.values.allSatisfy { $0.window?.isVisible == false })
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[0].id]?.isOpen, true)
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[1].id]?.isOpen, true)
    }

    func testRevealKeepsOpenNotesAndFocusesMostRecentlyUsedEligibleNote() async throws {
        let prepared = try await makeTransitionNotes()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let eligibleOlder = prepared.notes[0]
        let eligibleMRU = prepared.notes[1]
        let openedNote = prepared.notes[2]
        coordinator.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
        coordinator.metadata.notes[eligibleOlder.id] = NoteWindowMetadata(isOpen: true, focusOrder: 4)
        coordinator.metadata.notes[eligibleMRU.id] = NoteWindowMetadata(isOpen: true, focusOrder: 12)
        coordinator.metadata.notes[openedNote.id] = NoteWindowMetadata(isOpen: false, focusOrder: 99)
        for note in prepared.notes { coordinator.open(note, focus: false) }
        coordinator.metadata.notes[eligibleOlder.id]?.focusOrder = 4
        coordinator.metadata.notes[eligibleMRU.id]?.focusOrder = 120

        coordinator.perform(.reveal)

        let olderController = try XCTUnwrap(coordinator.windows[eligibleOlder.id])
        let mruController = try XCTUnwrap(coordinator.windows[eligibleMRU.id])
        let openedController = try XCTUnwrap(coordinator.windows[openedNote.id])
        XCTAssertEqual(coordinator.requestedFocus, eligibleMRU.id)
        // A background XCTest host cannot force macOS to transfer foreground ownership.
        if NSApp.isActive { XCTAssertTrue(mruController.window?.isKeyWindow == true) }
        XCTAssertTrue(mruController.window?.isVisible == true)
        XCTAssertTrue(olderController.window?.isVisible == true)
        XCTAssertTrue(openedController.window?.isVisible == true)
        XCTAssertGreaterThan(coordinator.metadata.notes[eligibleMRU.id]?.focusOrder ?? 0, 99)
    }

    func testDeletedLastEligibleNoteFallsBackToList() async throws {
        let prepared = try await makeTransitionNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.folderState.apply(.changed(note))
        coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
        coordinator.open(note, focus: false)
        var listWasShown = false
        coordinator.showList = { listWasShown = true }

        coordinator.remove(note.id)
        coordinator.perform(.reveal)

        XCTAssertTrue(listWasShown)
        XCTAssertNil(coordinator.windows[note.id])
        XCTAssertNil(coordinator.metadata.notes[note.id])
        XCTAssertNil(coordinator.notes[note.id])
    }

    func testRevealWithoutEligibleNotesRoutesToList() async throws {
        let prepared = try await makeTransitionNotes(count: 2)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
        for note in prepared.notes {
            coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: false)
        }
        var listWasShown = false
        coordinator.showList = { listWasShown = true }

        coordinator.perform(.reveal)

        XCTAssertTrue(listWasShown)
        XCTAssertTrue(coordinator.windows.isEmpty)
    }

    func testSettingsVisibilityDoesNotCountAsGroupVisibility() async throws {
        let prepared = try await makeTransitionNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.folderState.apply(.changed(note))
        coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
        var settingsIsVisible = true
        coordinator.listVisible = { false }
        coordinator.showSettings = { settingsIsVisible = true }

        XCTAssertFalse(coordinator.anyGroupVisible)
        coordinator.perform(.toggle)

        XCTAssertTrue(settingsIsVisible)
        XCTAssertTrue(coordinator.windows[note.id]?.window?.isVisible == true,
                      "With no note group visible, toggle should reveal eligible notes even if Settings is open")
    }

    func testRepeatedTogglesAlternateBetweenGroupHideAndReveal() async throws {
        let prepared = try await makeTransitionNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.folderState.apply(.changed(note))
        coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
        coordinator.open(note, focus: false)
        let window = try XCTUnwrap(coordinator.windows[note.id]?.window)

        coordinator.perform(.toggle)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(coordinator.metadata.notes[note.id]?.isOpen == true)

        coordinator.perform(.toggle)
        XCTAssertTrue(window.isVisible)

        coordinator.perform(.toggle)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(coordinator.metadata.notes[note.id]?.isOpen == true)
    }

    func testOpeningNoteAndTransitionTablePreserveOpenState() async throws {
        let prepared = try await makeTransitionNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.folderState.apply(.changed(note))
        coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: false)
        coordinator.open(note, focus: false)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.isOpen, true)
        let cases: [(WindowCoordinator.Action, Bool)] = [
            (.reveal, true), (.hide, false), (.hide, false), (.reveal, true),
            (.reveal, true), (.escape(transientActive: true), true),
            (.escape(transientActive: false), false), (.toggle, true), (.toggle, false)
        ]
        for (action, visible) in cases {
            coordinator.perform(action)
            try await waitUntil { coordinator.windows[note.id]?.window?.isVisible == visible }
            XCTAssertEqual(coordinator.windows[note.id]?.window?.isVisible, visible)
            XCTAssertEqual(coordinator.metadata.notes[note.id]?.isOpen, true)
        }
        coordinator.perform(.reveal)
        coordinator.closeNote(note.id)
        try await waitUntil {
            coordinator.metadata.notes[note.id]?.isOpen == false && coordinator.windows[note.id]?.window?.isVisible != true
        }
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.isOpen, false)
        XCTAssertNil(coordinator.windows[note.id])
    }

    func testDeletedLastActiveNoteFallsBackToEarlierEligibleNote() async throws {
        let prepared = try await makeTransitionNotes(count: 2)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        for (index, note) in prepared.notes.enumerated() {
            coordinator.folderState.apply(.changed(note))
            coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true, focusOrder: UInt64(index + 1))
        }
        coordinator.remove(prepared.notes[1].id)
        coordinator.perform(.reveal)
        XCTAssertEqual(coordinator.requestedFocus, prepared.notes[0].id)
        XCTAssertTrue(coordinator.windows[prepared.notes[0].id]?.window?.isVisible == true)
        if NSApp.isActive { XCTAssertTrue(coordinator.windows[prepared.notes[0].id]?.window?.isKeyWindow == true) }
        XCTAssertNil(coordinator.windows[prepared.notes[1].id])
    }

    func testEscapeWhileTransientUIIsActiveLeavesWindowsVisible() async throws {
        let prepared = try await makeTransitionNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
        coordinator.open(note, focus: false)
        let window = try XCTUnwrap(coordinator.windows[note.id]?.window)

        coordinator.perform(.escape(transientActive: true))

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(coordinator.metadata.notes[note.id]?.isOpen == true)
    }
}

private struct TransitionPreparedNotes {
    let fixture: TestFixture
    let store: NoteStore
    let folder: URL
    let collectionToken: CollectionToken
    let notes: [NoteSnapshot]
}

private func makeTransitionNotes(count: Int = 3) async throws -> TransitionPreparedNotes {
    let fixture = try TestFixture()
    let store = try NoteStore(support: fixture.root, clock: fixture.clock)
    let folder = await store.defaultFolder()
    for number in 0..<count {
        try Data("note \(number)".utf8).write(to: folder.appendingPathComponent("Transition note \(number).txt"))
    }
    let collectionToken = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: collectionToken)
    return TransitionPreparedNotes(fixture: fixture, store: store, folder: folder,
                                   collectionToken: collectionToken, notes: notes)
}

private actor SuspendedMetadataWriter {
    var values: [MetadataSnapshot] = []
    var gate: CheckedContinuation<Void, Never>?
    var shouldFail = false
    func write(_ value: MetadataSnapshot) async throws {
        values.append(value)
        await withCheckedContinuation { gate = $0 }
        if shouldFail { throw MetadataDiagnostic(message: "Injected metadata failure") }
    }
    func release(failing: Bool = false) {
        shouldFail = failing
        gate?.resume()
        gate = nil
    }
    var count: Int { values.count }
}

extension TransitionTests {
    private func waitForWrites(_ count: Int, writer: SuspendedMetadataWriter) async {
        for _ in 0..<10_000 {
            if await writer.count >= count { return }
            await Task.yield()
        }
        XCTFail("Writer did not reach the expected suspension")
    }

    func testLatestEditorPositionSurvivesMetadataWriteFailure() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        let id = NoteID()
        var metadata = CollectionMetadata(notes: [id: NoteWindowMetadata(isOpen: true)])
        metadata.notes[id]?.editorPosition = EditorPosition(selections: [.init(location: 1, length: 0)],
            scrollX: 0, scrollY: 20, hasActiveCaret: true, fileModifiedAt: nil)
        persistence.submit(.collection(metadata))
        await waitForWrites(1, writer: writer)
        metadata.notes[id]?.editorPosition = EditorPosition(selections: [.init(location: 4, length: 2)],
            scrollX: 0, scrollY: 90, hasActiveCaret: false, fileModifiedAt: nil)
        persistence.submit(.collection(metadata))
        await writer.release(failing: true)
        await waitForWrites(2, writer: writer)
        await writer.release(failing: true)
        for _ in 0..<10_000 where persistence.pendingCount == 0 { await Task.yield() }
        let retry = Task { try await persistence.flush() }
        await waitForWrites(3, writer: writer)
        await writer.release()
        try await retry.value
        let values = await writer.values
        guard case let .collection(saved) = values.last else { return XCTFail("Missing position retry") }
        XCTAssertEqual(saved, metadata)
        XCTAssertEqual(persistence.pendingCount, 0)
    }

    func testSupersedingMetadataRunsAfterInFlightFailure() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        var errors = 0
        persistence.failed = { _, _ in errors += 1 }
        persistence.submit(.settings(AppSettings()))
        await waitForWrites(1, writer: writer)
        var enteredBarrier = false
        let barrier = Task { enteredBarrier = true; try await persistence.flush() }
        while !enteredBarrier { await Task.yield() }
        var latest = AppSettings()
        latest.fontSize = 42
        persistence.submit(.settings(latest))
        await writer.release(failing: true)
        await waitForWrites(2, writer: writer)
        guard await writer.count == 2 else { _ = try? await barrier.value; return }
        await writer.release()
        try await barrier.value
        let values = await writer.values
        guard case let .settings(saved) = values[1] else { return XCTFail("Missing newer settings") }
        XCTAssertEqual(saved.fontSize, 42)
        XCTAssertEqual(errors, 0, "An obsolete failure must not be attributed to the newer value")
    }

    func testNewSubmissionRetriesFailedDestinationWithoutFlush() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        persistence.submit(.settings(AppSettings()))
        await waitForWrites(1, writer: writer)
        await writer.release(failing: true)
        for _ in 0..<10_000 where persistence.pendingCount == 0 { await Task.yield() }
        XCTAssertEqual(persistence.pendingCount, 1, "The failed snapshot stays retryable")

        var latest = AppSettings()
        latest.fontSize = 22
        persistence.submit(.settings(latest))
        await waitForWrites(2, writer: writer)
        await writer.release()
        try await persistence.flush()
        let values = await writer.values
        guard case let .settings(saved) = values.last else { return XCTFail("Missing retried write") }
        XCTAssertEqual(saved.fontSize, 22)
        XCTAssertEqual(persistence.pendingCount, 0)
    }

    func testMetadataBurstCoalescesCollectionAlongsideOtherDestinations() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        persistence.submit(.collection(CollectionMetadata()))
        await waitForWrites(1, writer: writer)
        for size in 1...1000 {
            var settings = AppSettings()
            settings.fontSize = Double(size)
            persistence.submit(.settings(settings))
        }
        persistence.submit(.collection(CollectionMetadata()))
        XCTAssertEqual(persistence.pendingCount, 2)
        let barrier = Task { try await persistence.flush() }
        await writer.release()
        await waitForWrites(2, writer: writer)
        await writer.release()
        await waitForWrites(3, writer: writer)
        await writer.release()
        try await barrier.value
        let values = await writer.values
        guard case let .settings(saved) = values[1] else { return XCTFail("Missing settings") }
        XCTAssertEqual(saved.fontSize, 1000)
        guard case .collection = values[2] else { return XCTFail("Missing collection") }
        XCTAssertEqual(persistence.pendingCount, 0)
    }

    func testMetadataBarrierDoesNotRequireLaterSubmissions() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        persistence.submit(.settings(AppSettings()))
        await waitForWrites(1, writer: writer)
        var enteredBarrier = false
        let barrier = Task { enteredBarrier = true; try await persistence.flush() }
        while !enteredBarrier { await Task.yield() }
        persistence.submit(.collection(CollectionMetadata()))
        await writer.release()
        await waitForWrites(2, writer: writer)
        try await barrier.value
        await writer.release()
        try await persistence.flush()
    }

    func testMetadataFailureIsVisibleAndLatestSnapshotCanBeRetried() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        var latest = AppSettings()
        latest.fontSize = 25
        persistence.submit(.settings(latest))
        await waitForWrites(1, writer: writer)
        var enteredBarrier = false
        let barrier = Task { enteredBarrier = true; try await persistence.flush() }
        while !enteredBarrier { await Task.yield() }
        await writer.release(failing: true)
        do { try await barrier.value; XCTFail("Failure must reach lifecycle callers") } catch { }
        XCTAssertEqual(persistence.pendingCount, 1)
        let retry = Task { try await persistence.flush() }
        await waitForWrites(2, writer: writer)
        await writer.release()
        try await retry.value
        let values = await writer.values
        guard case let .settings(saved) = values[1] else { return XCTFail("Missing retry") }
        XCTAssertEqual(saved.fontSize, 25)
        XCTAssertEqual(persistence.pendingCount, 0)
    }

    func testCancelledMetadataBarrierDoesNotCancelPersistence() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        persistence.submit(.settings(AppSettings()))
        await waitForWrites(1, writer: writer)
        var enteredBarrier = false
        let barrier = Task { enteredBarrier = true; try await persistence.flush() }
        while !enteredBarrier { await Task.yield() }
        barrier.cancel()
        await writer.release()
        do { try await barrier.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        try await persistence.flush()
        XCTAssertEqual(persistence.pendingCount, 0)
    }
}

extension TransitionTests {
    func testMetadataBarrierPersistsSupersedingSnapshotAndIndependentDestinationAfterFailure() async throws {
        let writer = SuspendedMetadataWriter()
        let persistence = MetadataPersistence { try await writer.write($0) }
        persistence.submit(.collection(CollectionMetadata()))
        await waitForWrites(1, writer: writer)
        persistence.submit(.settings(AppSettings()))
        var enteredBarrier = false
        let barrier = Task { enteredBarrier = true; try await persistence.flush() }
        while !enteredBarrier { await Task.yield() }
        var latest = AppSettings()
        latest.fontSize = 31
        persistence.submit(.settings(latest))
        await writer.release(failing: true)
        await waitForWrites(2, writer: writer)
        await writer.release()
        do { try await barrier.value; XCTFail("Old folder failure must block the transition") } catch { }
        let values = await writer.values
        guard case let .settings(saved) = values[1] else { return XCTFail("Independent settings were lost") }
        XCTAssertEqual(saved.fontSize, 31)
        let retry = Task { try await persistence.flush() }
        await waitForWrites(3, writer: writer)
        await writer.release()
        try await retry.value
    }

    func testMetadataFlushRoundTripsCollectionAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(root: root)
        let persistence = MetadataPersistence(store: store)
        var settings = AppSettings()
        settings.fontSize = 27
        persistence.submit(.settings(settings))
        persistence.submit(.collection(CollectionMetadata()))
        persistence.submit(.collection(CollectionMetadata()))
        try await persistence.flush()
        let loadedSettings = await store.loadSettings()
        XCTAssertEqual(loadedSettings.value, settings)
        let loaded = await store.loadCollection()
        XCTAssertNil(loaded.diagnostic)
        XCTAssertEqual(loaded.value, CollectionMetadata())
    }
}

extension TransitionTests {
    func testLifecycleInitializationJoinsAndDefersReveal() async {
        let lifecycle = LifecycleController()
        var gate: CheckedContinuation<Void, Never>?
        var loads = 0
        var reveals = 0
        lifecycle.reveal = { reveals += 1 }
        let first = Task {
            await lifecycle.initialize { _ in
                loads += 1
                await withCheckedContinuation { gate = $0 }
                return true
            }
        }
        while gate == nil { await Task.yield() }
        lifecycle.requestReveal()
        let second = Task { await lifecycle.initialize { _ in loads += 1; return false } }
        await Task.yield()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(reveals, 0)
        gate?.resume()
        await first.value
        await second.value
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(reveals, 1)
    }

    func testLifecycleFailedTransitionRetainsStateAndQuitWaitsForSwitch() async throws {
        let lifecycle = LifecycleController()
        await lifecycle.initialize { _ in true }
        do {
            try await lifecycle.transact(.switching, editors: { nil }, flushMetadata: {
                throw MetadataDiagnostic(message: "Injected failure")
            }, commit: { XCTFail("Failed flush must not commit") })
            XCTFail("Expected failure")
        } catch { }
        XCTAssertEqual(lifecycle.state, .ready)
        var gate: CheckedContinuation<Void, Never>?
        let switching = Task {
            try await lifecycle.transact(.switching, editors: { nil }, flushMetadata: {}) {
                await withCheckedContinuation { gate = $0 }
            }
        }
        while gate == nil { await Task.yield() }
        var quitCommitted = false
        let quit = Task {
            try await lifecycle.transact(.quitting, editors: { nil }, flushMetadata: {}) { quitCommitted = true }
        }
        await Task.yield()
        XCTAssertFalse(quitCommitted)
        gate?.resume()
        try await switching.value
        try await quit.value
        XCTAssertTrue(quitCommitted)
        XCTAssertEqual(lifecycle.state, .quitting)
    }
}

extension TransitionTests {
    func testQuitDuringStartupWaitsAndFailedStartupCanRetryWithNewToken() async throws {
        let lifecycle = LifecycleController()
        var gate: CheckedContinuation<Void, Never>?
        var oldToken: UUID?
        let startup = Task {
            await lifecycle.initialize { token in
                oldToken = token
                await withCheckedContinuation { gate = $0 }
                return false
            }
        }
        while gate == nil { await Task.yield() }
        var quit = false
        let quitting = Task {
            try await lifecycle.transact(.quitting, editors: { nil }, flushMetadata: {}) { quit = true }
        }
        await Task.yield()
        XCTAssertFalse(quit)
        gate?.resume()
        await startup.value
        try await quitting.value
        XCTAssertTrue(quit)
        XCTAssertFalse(lifecycle.isCurrent(try XCTUnwrap(oldToken)))

        let retry = LifecycleController()
        var failedToken: UUID?
        await retry.initialize { failedToken = $0; return false }
        XCTAssertEqual(retry.state, .failed)
        await retry.initialize { _ in true }
        XCTAssertEqual(retry.state, .ready)
        XCTAssertFalse(retry.isCurrent(try XCTUnwrap(failedToken)))
    }

    func testCancelledTransitionReleasesLockAndDoesNotCommit() async throws {
        let prepared = try await makeTransitionNotes(count: 1)
        let windows = WindowCoordinator(store: prepared.store)
        defer { windows.perform(.hide) }
        windows.open(prepared.notes[0], focus: false)
        let editor = try XCTUnwrap(windows.windows[prepared.notes[0].id]?.editor)
        let lifecycle = LifecycleController()
        await lifecycle.initialize { _ in true }
        var gate: CheckedContinuation<Void, Never>?
        let task = Task {
            try await lifecycle.transact(.switching, editors: { windows }, captureGeometry: { windows.captureAllGeometry() }, flushMetadata: {
                await withCheckedContinuation { gate = $0 }
            }) { XCTFail("Cancellation must prevent commit") }
        }
        while gate == nil { await Task.yield() }
        XCTAssertFalse(editor.textView.isEditable)
        task.cancel()
        gate?.resume()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertEqual(lifecycle.state, .ready)
    }

    func testDelayedLoginHintDoesNotOverridePendingManualReopen() async {
        let lifecycle = LifecycleController()
        var origin = LaunchOrigin()
        var gate: CheckedContinuation<Void, Never>?
        var revealed = 0
        lifecycle.reveal = { revealed += 1 }
        let startup = Task {
            await lifecycle.initialize { _ in
                await withCheckedContinuation { gate = $0 }
                return true
            }
        }
        while gate == nil { await Task.yield() }
        origin.manualReopen()
        lifecycle.requestReveal()
        origin.receive([LaunchOrigin.loginURL])
        XCTAssertFalse(origin.hidden)
        XCTAssertEqual(revealed, 0)
        gate?.resume()
        await startup.value
        XCTAssertEqual(revealed, 1)
    }
}

extension TransitionTests {
    func testStoreReplacementCancelsOldSubscription() async throws {
        let old = try await makeTransitionNotes(count: 1)
        let new = try await makeTransitionNotes(count: 1)
        let lifecycle = LifecycleController()
        var received: [NoteID] = []
        await lifecycle.observe(old.store) { event in
            if case let .changed(note) = event { received.append(note.id) }
        }
        await lifecycle.observe(new.store) { event in
            if case let .changed(note) = event { received.append(note.id) }
        }
        await old.store.emit(.changed(old.notes[0]))
        await new.store.emit(.changed(new.notes[0]))
        for _ in 0..<1000 where received.isEmpty { await Task.yield() }
        XCTAssertEqual(received, [new.notes[0].id])
        lifecycle.stopObservation()
    }
}

extension TransitionTests {
    func testDefaultChangeFinishesCompositionKeepsEditorsUndoAndWaitsForMetadataAndQuit() async throws {
        let fixture = try TestFixture()
        let hooks = FolderAccessHooks(bookmark: { Data($0.path.utf8) }, resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }, start: { _ in true }, stop: { _ in })
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
        let destination = fixture.root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let windows = WindowCoordinator(store: store)
        defer { windows.perform(.hide) }
        windows.open(note, focus: false)
        let editor = try XCTUnwrap(windows.windows[note.id]?.editor)
        editor.textView.insertText("first", replacementRange: NSRange(location: 0, length: 0))
        editor.capture()
        editor.textView.setMarkedText(" composed", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: 5, length: 0))
        editor.capture()
        XCTAssertTrue(editor.textView.hasMarkedText())
        let customRoot = fixture.root.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let customURL = customRoot.appendingPathComponent("custom.txt")
        try Data("custom".utf8).write(to: customURL)
        let custom = try await store.registerCustomFile(customURL, parent: FolderAccess(support: fixture.root, hooks: hooks).acquire(customRoot))
        windows.open(custom, focus: false)
        let customEditor = try XCTUnwrap(windows.windows[custom.id]?.editor)
        customEditor.textView.insertText(" edited", replacementRange: NSRange(location: 6, length: 0))
        customEditor.capture()
        customEditor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        windows.metadata.notes[custom.id]?.backgroundTone = .purple
        let prepared = try await store.prepareDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        let lifecycle = LifecycleController()
        await lifecycle.initialize { _ in true }
        var barrier: CheckedContinuation<Void, Never>?
        var committed = false
        let switching = Task {
            try await lifecycle.transact(.switching, editors: { windows }, captureGeometry: { windows.captureAllGeometry() }, flushMetadata: {
                XCTAssertFalse(editor.textView.hasMarkedText())
                XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "first composed")
                await withCheckedContinuation { barrier = $0 }
            }) {
                let result = try await store.commitDefaultFolder(prepared)
                XCTAssertEqual(result.collectionToken, note.collectionToken)
                let moved = try await store.read(note.id, collectionToken: note.collectionToken)
                editor.applyExternal(moved)
                committed = true
            }
        }
        while barrier == nil { await Task.yield() }
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertFalse(committed)
        var quitCommitted = false
        let quit = Task {
            try await lifecycle.transact(.quitting, editors: { windows }, captureGeometry: { windows.captureAllGeometry() }, flushMetadata: {}) {
                XCTAssertTrue(committed)
                let batches = await store.defaultFolderBatches()
                XCTAssertEqual(batches.first?.state, .settled)
                quitCommitted = true
            }
        }
        await Task.yield()
        XCTAssertFalse(quitCommitted)
        do {
            try await lifecycle.transact(.switching, editors: { windows }, captureGeometry: { windows.captureAllGeometry() }, flushMetadata: {}) { XCTFail("Overlapping transaction admitted") }
            XCTFail("Repeated default change admitted")
        } catch { }
        barrier?.resume()
        try await switching.value
        try await quit.value
        XCTAssertTrue(quitCommitted)
        XCTAssertTrue(windows.windows[custom.id]?.editor === customEditor)
        XCTAssertEqual(customEditor.note.fileURL, customURL)
        XCTAssertEqual(customEditor.textView.string, "custom edited")
        XCTAssertEqual(customEditor.textView.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertTrue(customEditor.textView.undoManager?.canUndo == true)
        XCTAssertEqual(windows.metadata.notes[custom.id]?.backgroundTone, .purple)
        XCTAssertEqual(try String(contentsOf: customURL, encoding: .utf8), "custom edited")
        XCTAssertTrue(windows.windows[note.id]?.editor === editor)
        XCTAssertEqual(editor.textView.string, "first composed")
        XCTAssertEqual(editor.note.fileURL.deletingLastPathComponent(), destination)
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        XCTAssertFalse(editor.textView.isEditable, "Successful Quit retains its own lock")
    }

    func testDefaultChangeMetadataFailureLeavesCollectionAndEditorIntact() async throws {
        let fixture = try TestFixture()
        let hooks = FolderAccessHooks(bookmark: { Data($0.path.utf8) }, resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }, start: { _ in true }, stop: { _ in })
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
        let destination = fixture.root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let windows = WindowCoordinator(store: store)
        defer { windows.perform(.hide) }
        windows.open(note, focus: false)
        let editor = try XCTUnwrap(windows.windows[note.id]?.editor)
        editor.textView.insertText("dirty text", replacementRange: NSRange(location: 0, length: 0))
        editor.capture()
        let prepared = try await store.prepareDefaultFolder(to: destination, moveExisting: true, from: note.collectionToken)
        let lifecycle = LifecycleController()
        await lifecycle.initialize { _ in true }
        do {
            try await lifecycle.transact(.switching, editors: { windows }, captureGeometry: { windows.captureAllGeometry() }, flushMetadata: { throw NoteOperationError.permissionDenied }) {
                _ = try await store.commitDefaultFolder(prepared)
                XCTFail("Metadata failure committed")
            }
            XCTFail("Metadata failure ignored")
        } catch { }
        XCTAssertTrue(windows.windows[note.id]?.editor === editor)
        XCTAssertEqual(editor.textView.string, "dirty text")
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, selection.url)
        XCTAssertEqual(current.collectionToken, selection.collectionToken)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "dirty text")
        let batches = await store.defaultFolderBatches()
        XCTAssertTrue(batches.isEmpty)
    }
}
