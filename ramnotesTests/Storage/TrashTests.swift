import ramnotesDomain
import Foundation
import XCTest
@testable import ramnotes

final class TrashTests: XCTestCase {
    @MainActor
    func testLiveEditorRetainsDeliveryRejectedAfterExternalTrashAcrossRestart() async throws {
        for earlierPending in [false, true] {
            let fixture = try TestFixture()
            let resolved = TrashResultBox()
            let hooks = FolderAccessHooks(bookmark: { Data($0.path.utf8) }, resolve: { data in
                (resolved.value ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
            }, start: { _ in true }, stop: { _ in })
            var service = TrashService()
            service.contains = { $0.deletingLastPathComponent().lastPathComponent == ".Trash" }
            let store = try NoteStore(support: fixture.root, trashService: service, folderAccessHooks: hooks)
            let folder = await store.defaultFolder()
            let source = folder.appendingPathComponent("Live.txt")
            try Data("original".utf8).write(to: source)
            let token = CollectionToken()
            let discovered = try await store.discover(in: folder, collectionToken: token)
            let note = try XCTUnwrap(discovered.first)
            let coordinator = WindowCoordinator(store: store)
            coordinator.open(note, focus: false)
            let editor = try XCTUnwrap(coordinator.windows[note.id]?.editor)
            if earlierPending {
                _ = await store.submit(makeTrashEdit(note, collectionToken: token, text: "earlier pending"))
            }
            let trash = fixture.root.appendingPathComponent(".Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            resolved.set(destination)
            try await store.reconcile(collectionToken: token)
            let observed = await store.records[note.id]
            let trashed = try XCTUnwrap(observed)
            XCTAssertEqual(trashed.availability, .trashed)
            // Queue the latest delivery without yielding, then deliver the real storage observation.
            editor.textView.string = "latest live buffer"
            editor.capture()
            coordinator.folderState.apply(.changed(trashed))
            coordinator.acceptFileObservation(trashed)
            editor.applyExternal(trashed)
            XCTAssertNotNil(coordinator.windows[note.id])
            for _ in 0..<1000 where coordinator.windows[note.id] != nil { await Task.yield() }
            XCTAssertNil(coordinator.windows[note.id])
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
            let restarted = try NoteStore(support: fixture.root, trashService: service, folderAccessHooks: hooks)
            _ = try await restarted.openSelectedFolder()
            let retained = await restarted.retainedRecovery()
            XCTAssertTrue(retained.edits.contains { $0.text == "latest live buffer" })
        }
    }

    func testExternalTrashDisablesNoteAndEmptyTrashRemovesTracking() async throws {
        try await checkExternalTrash()
    }

    func testExternalTrashRecoversPendingTextBeforeDisablingNote() async throws {
        try await checkExternalTrash(retainedText: "unsaved text")
    }

    func testFinderRestorationMakesTrashedNoteAvailableAgain() async throws {
        try await checkExternalTrash(restore: true)
    }

    func testFinderRestorationOfCustomPathNoteKeepsTracking() async throws {
        try await checkExternalTrash(restore: true, custom: true)
    }

    private func checkExternalTrash(retainedText: String? = nil, restore: Bool = false, custom: Bool = false) async throws {
        let fixture = try TestFixture()
        let resolved = TrashResultBox()
        let hooks = FolderAccessHooks(bookmark: { Data($0.path.utf8) },
            resolve: { data in
                (resolved.value ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
            }, start: { _ in true }, stop: { _ in })
        var service = TrashService()
        service.contains = { $0.deletingLastPathComponent().lastPathComponent == ".Trash" }
        let store = try NoteStore(support: fixture.root, trashService: service, folderAccessHooks: hooks)
        let folder = await store.defaultFolder()
        let source = (custom ? fixture.root : folder).appendingPathComponent("ExternalTrash.txt")
        try Data("original".utf8).write(to: source)
        let token = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: token)
        let note: NoteSnapshot
        if custom { note = try await store.registerFile(source, collectionToken: token) }
        else { note = try XCTUnwrap(notes.first) }
        if let retainedText {
            _ = await store.submit(makeTrashEdit(note, collectionToken: token, text: retainedText))
        }
        let trash = fixture.root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        resolved.set(destination)

        try await store.reconcile(collectionToken: token)
        let trashed = await store.records[note.id]
        XCTAssertEqual(trashed?.availability, .trashed)
        let results = await SearchIndex().search(notes: [try XCTUnwrap(trashed)], query: "")
        XCTAssertEqual(results.first?.snippet, "File was moved to Trash")
        if let retainedText {
            let notices = await store.recoveryNotices()
            XCTAssertEqual(notices.count, 1)
            let recovery = try XCTUnwrap(notices.first)
            XCTAssertEqual(try String(contentsOf: recovery.recoveryURL, encoding: .utf8), retainedText)
        }
        if restore {
            try FileManager.default.moveItem(at: destination, to: source)
            resolved.set(source)
            try await store.reconcile(collectionToken: token)
            let restored = await store.records[note.id]
            XCTAssertEqual(restored?.availability, .available)
            XCTAssertEqual(restored?.fileURL, source)
            return
        }
        let current = try XCTUnwrap(trashed)
        let result = await store.save(EditSnapshot(id: note.id, collectionToken: token,
            revision: EditRevision(rawValue: 2), baseRevision: current.fileRevision,
            text: "must not save", locationRevision: current.locationRevision))
        if case .saved = result { XCTFail("Trashed notes must not be editable") }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")

        try FileManager.default.removeItem(at: destination)
        try await store.reconcile(collectionToken: token)
        let removed = await store.records[note.id]
        XCTAssertNil(removed)
        let identity = await store.identities.identity(note.id)
        XCTAssertNil(identity)
        let catalog = try CatalogPersistence.load(at: fixture.root.appendingPathComponent("catalog.json"))
        XCTAssertNil(catalog.notes[note.id])
    }

    func testDirtyBufferIsSavedBeforeTrashAndRemovedFromCollection() async throws {
        let prepared = try await makeTrashNote()
        _ = await prepared.store.submit(makeTrashEdit(prepared.note, collectionToken: prepared.collectionToken,
            text: "latest edited text"))

        try await prepared.store.moveToTrash(prepared.note.id, collectionToken: prepared.collectionToken)

        XCTAssertEqual(try Data(contentsOf: prepared.trashURL), Data("latest edited text".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
        let removed = await prepared.store.records[prepared.note.id]
        XCTAssertNil(removed)
    }

    func testTrashForgetsJournalAndNoticesOfTrashedNote() async throws {
        let prepared = try await makeTrashNote()
        let store = prepared.store
        let id = prepared.note.id
        let recovery = await store.recovery
        try recovery.write(RecoveryRecord(id: UUID(), noteID: id, collectionToken: prepared.collectionToken,
            originalURL: prepared.note.fileURL, baseRevision: nil, editRevision: .init(rawValue: 1),
            text: "journaled", createdAt: .distantPast, reason: .saveFailure))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.url(id).path))

        try await store.moveToTrash(id, collectionToken: prepared.collectionToken)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.url(id).path))
        XCTAssertTrue(recovery.load().records.isEmpty)
        let notices = await store.notices
        XCTAssertFalse(notices.contains { $0.recoveryNoteID == id || $0.sourceNoteID == id })
        let pending = await store.pending[id]
        XCTAssertNil(pending)
    }

    func testTrashClearsSessionStateAfterCompletedConflictRecovery() async throws {
        let prepared = try await makeTrashNote()
        let store = prepared.store
        let id = prepared.note.id
        try Data("external".utf8).write(to: prepared.note.fileURL)
        let edit = makeTrashEdit(prepared.note, collectionToken: prepared.collectionToken, text: "local draft")
        guard case .recovered = await store.save(edit) else { return XCTFail("Expected conflict recovery") }
        let conflicts = await store.session.conflictRecoveries[id]
        let beforeSource = try XCTUnwrap(conflicts)
        let recoveryID = beforeSource.recoveryNoteID

        await store.forget(id)

        let session = await store.session
        XCTAssertNil(session.conflictRecoveries[id])
        XCTAssertNil(session.completions[id])
        XCTAssertNil(session.journalRecords[id])
        XCTAssertNil(session.lastWritten[id])
        XCTAssertNil(session.ownBases[id])
        XCTAssertNil(session.retryCounts[id])
        XCTAssertFalse(session.writing.contains(id))
        let status = await store.statuses[id]
        XCTAssertNil(status)

        var other = session
        other.conflictRecoveries[NoteID()] = beforeSource
        other.forget(recoveryID)
        XCTAssertTrue(other.conflictRecoveries.isEmpty)
    }

    func testJournalDeletionFailureIsReportedAndCleanupContinues() async throws {
        let prepared = try await makeTrashNote()
        let store = prepared.store
        let id = prepared.note.id
        let recovery = await store.recovery
        try recovery.write(RecoveryRecord(id: UUID(), noteID: id, collectionToken: prepared.collectionToken,
            originalURL: prepared.note.fileURL, baseRevision: nil, editRevision: .init(rawValue: 1),
            text: "journaled", createdAt: .distantPast, reason: .saveFailure))
        let root = recovery.url(id).deletingLastPathComponent()
        let stream = await store.events()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        await store.forget(id)
        await store.emit(.failed(nil, .cancelled))

        var failed = false, removed = false
        for await event in stream {
            if case .failed(nil, .cancelled) = event { break }
            if case .failed(let noteID, _) = event, noteID == id { failed = true }
            if case .removed(let noteID, _) = event, noteID == id { removed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(removed)
        let records = await store.records[id]
        XCTAssertNil(records)
    }

    func testTrashFailureKeepsOriginalAndActiveRecord() async throws {
        let prepared = try await makeTrashNote(fault: { stage in
            if case .trash = stage { throw NoteOperationError.permissionDenied }
        })
        _ = await prepared.store.submit(makeTrashEdit(prepared.note,
            collectionToken: prepared.collectionToken, text: "latest recoverable edit"))

        do {
            try await prepared.store.moveToTrash(prepared.note.id, collectionToken: prepared.collectionToken)
            XCTFail("Expected injected Trash failure")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .permissionDenied)
        }

        let active = await prepared.store.records[prepared.note.id]
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
        XCTAssertEqual(active?.id, prepared.note.id)
        XCTAssertEqual(active?.availability, .available)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("latest recoverable edit".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.trashURL.path))
    }

    func testPartialTrashFailureKeepsSuccessfulDeletionsAndFailedNote() async throws {
        let fixture = try TestFixture()
        let trashRoot = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
        let service = TrashService(move: { url in
            if url.lastPathComponent == "Middle.txt" { throw NoteOperationError.permissionDenied }
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let target = trashRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let store = try NoteStore(support: fixture.root, trashService: service, folderAccessHooks: trashHooks)
        let folder = await store.defaultFolder()
        let urls = ["First.txt", "Middle.txt", "Last.txt"].map { folder.appendingPathComponent($0) }
        for (index, url) in urls.enumerated() { try Data("note \(index)".utf8).write(to: url) }
        let token = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: token)
        let ordered = try urls.map { url in try XCTUnwrap(notes.first { $0.fileURL == url }) }
        var succeeded: [NoteID] = []
        var failed: [NoteID] = []

        for note in ordered {
            do {
                try await store.moveToTrash(note.id, collectionToken: token)
                succeeded.append(note.id)
            } catch let error as NoteOperationError {
                XCTAssertEqual(error, .permissionDenied)
                failed.append(note.id)
            }
        }

        XCTAssertEqual(succeeded, [ordered[0].id, ordered[2].id])
        XCTAssertEqual(failed, [ordered[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[2].path))
        XCTAssertEqual(try Data(contentsOf: trashRoot.appendingPathComponent("First.txt")), Data("note 0".utf8))
        XCTAssertEqual(try Data(contentsOf: trashRoot.appendingPathComponent("Last.txt")), Data("note 2".utf8))
        let first = await store.records[ordered[0].id]
        let middle = await store.records[ordered[1].id]
        let last = await store.records[ordered[2].id]
        XCTAssertNil(first)
        XCTAssertNotNil(middle)
        XCTAssertNil(last)
    }

    func testExternalReplacementAtTrashBoundaryIsNeverDeleted() async throws {
        let fixture = try TestFixture()
        let target = fixture.root.appendingPathComponent("Notes/Existing.txt")
        let store = try NoteStore(support: fixture.root, fault: { stage in
            if stage == .trash {
                try FileManager.default.removeItem(at: target)
                try Data("external replacement".utf8).write(to: target)
            }
        })
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Existing.txt")
        try Data("original".utf8).write(to: url)
        let token = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: token)
        let note = try XCTUnwrap(notes.first)

        do {
            try await store.moveToTrash(note.id, collectionToken: token)
            XCTFail("A replacement must not be moved to Trash")
        } catch { }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external replacement")
        let active = await store.records[note.id]
        XCTAssertEqual(active?.id, note.id)
    }

    func testCustomFileTrashUsesFileGrantWithoutAcquiringParent() async throws {
        let fixture = try TestFixture()
        let hooks = TrashAccessRecorder()
        let trashRoot = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
        let service = TrashService(move: { url in
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let destination = trashRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        let store = try NoteStore(support: fixture.root, clock: fixture.clock,
            trashService: service, folderAccessHooks: hooks.hooks)
        let folder = await store.defaultFolder()
        let token = CollectionToken()
        _ = try await store.discover(in: folder, collectionToken: token)
        let customParent = fixture.root.appendingPathComponent("Picked", isDirectory: true)
        try FileManager.default.createDirectory(at: customParent, withIntermediateDirectories: true)
        let customFile = customParent.appendingPathComponent("Custom.txt")
        try Data("custom content".utf8).write(to: customFile)
        let note = try await store.registerFile(customFile, collectionToken: token)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        catalog.notes[note.id]?.parentResource = nil
        try CatalogPersistence.save(catalog, at: catalogURL)
        let reopened = try NoteStore(support: fixture.root, clock: fixture.clock,
            trashService: service, folderAccessHooks: hooks.hooks)
        let selection = try await reopened.openSelectedFolder()
        XCTAssertEqual(selection.notes.first(where: { $0.id == note.id })?.fileURL, customFile)
        hooks.reset()

        try await reopened.moveToTrash(note.id, collectionToken: selection.collectionToken)

        XCTAssertEqual(hooks.resolvedURLs, [customFile.standardizedFileURL])
        XCTAssertTrue(hooks.startedURLs.isEmpty)
        XCTAssertTrue(hooks.bookmarkedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashRoot.appendingPathComponent("Custom.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: customFile.path))
    }

    func testTrashCatalogCheckpointRetriesAfterCatalogBecomesWritable() async throws {
        let fixture = try TestFixture()
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        let trashRoot = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
        let service = TrashService(move: { url in
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let destination = trashRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            try FileManager.default.removeItem(at: catalogURL)
            try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: false)
            return destination
        })
        let store = try NoteStore(support: fixture.root, clock: fixture.clock,
            trashService: service, folderAccessHooks: trashHooks)
        let folder = await store.defaultFolder()
        let source = folder.appendingPathComponent("Checkpoint.txt")
        try Data("checkpoint text".utf8).write(to: source)
        let token = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: token)
        let note = try XCTUnwrap(notes.first)
        let originalCatalog = try Data(contentsOf: catalogURL)

        try await store.moveToTrash(note.id, collectionToken: token)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let removedInMemory = await store.records[note.id]
        XCTAssertNil(removedInMemory)
        try FileManager.default.removeItem(at: catalogURL)
        try originalCatalog.write(to: catalogURL)
        await store.writeIdentitiesIfDirty()

        let durableCatalog = try CatalogPersistence.load(at: catalogURL)
        XCTAssertNil(durableCatalog.notes[note.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashRoot.appendingPathComponent("Checkpoint.txt").path))
    }

    func testFileManagerTrashMovesDisposableFileWithoutAppRestorationHistory() async throws {
        let fixture = try TestFixture()
        let result = TrashResultBox()
        let service = TrashService(move: { url in
            var returned: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &returned)
            guard let trashed = returned as URL? else {
                throw NoteOperationError.inputOutput("Trash did not return a resulting location")
            }
            result.set(trashed)
            return trashed
        })
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, trashService: service,
            folderAccessHooks: trashHooks)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Disposable.txt")
        try Data("disposable content".utf8).write(to: url)
        let token = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: token)
        let note = try XCTUnwrap(notes.first)

        try await store.moveToTrash(note.id, collectionToken: token)
        let trashedURL = try XCTUnwrap(result.value)
        addTeardownBlock { try? FileManager.default.removeItem(at: trashedURL) }
        XCTAssertTrue(service.contains(trashedURL))
        XCTAssertFalse(service.contains(fixture.root))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path))
        let removed = await store.records[note.id]
        XCTAssertNil(removed)
    }
}

private struct TrashPreparedNote {
    let fixture: TestFixture
    let store: NoteStore
    let collectionToken: CollectionToken
    let note: NoteSnapshot
    let trashURL: URL
}

private func makeTrashNote(fault: @escaping StorageFault = { _ in }) async throws -> TrashPreparedNote {
    let fixture = try TestFixture()
    let trashRoot = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
    let service = TrashService(move: { url in
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        let target = trashRoot.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    })
    let store = try NoteStore(support: fixture.root, clock: fixture.clock, fault: fault,
        trashService: service, folderAccessHooks: trashHooks)
    let folder = await store.defaultFolder()
    let url = folder.appendingPathComponent("Existing.txt")
    try Data("original".utf8).write(to: url)
    let token = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: token)
    return TrashPreparedNote(fixture: fixture, store: store, collectionToken: token,
        note: try XCTUnwrap(notes.first), trashURL: trashRoot.appendingPathComponent(url.lastPathComponent))
}

private func makeTrashEdit(_ note: NoteSnapshot, collectionToken: CollectionToken, text: String) -> EditSnapshot {
    EditSnapshot(id: note.id, collectionToken: collectionToken, revision: EditRevision(rawValue: 1),
        baseRevision: note.fileRevision, text: text)
}

private var trashHooks: FolderAccessHooks {
    FolderAccessHooks(bookmark: { Data($0.path.utf8) },
        resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
        start: { _ in true }, stop: { _ in })
}

private final class TrashAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bookmarks: [URL] = []
    private var resolutions: [URL] = []
    private var starts: [URL] = []

    var hooks: FolderAccessHooks {
        FolderAccessHooks(bookmark: { [self] url in
            lock.lock(); defer { lock.unlock() }
            bookmarks.append(url.standardizedFileURL)
            return Data(url.path.utf8)
        }, resolve: { [self] data in
            let url = URL(fileURLWithPath: String(decoding: data, as: UTF8.self)).standardizedFileURL
            lock.lock(); defer { lock.unlock() }
            resolutions.append(url)
            return (url, false)
        }, start: { [self] url in
            lock.lock(); defer { lock.unlock() }
            starts.append(url.standardizedFileURL)
            return true
        }, stop: { _ in })
    }

    var bookmarkedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return bookmarks }
    var resolvedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return resolutions }
    var startedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return starts }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        bookmarks.removeAll(); resolutions.removeAll(); starts.removeAll()
    }
}

private final class TrashResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: URL?
    var value: URL? { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ url: URL) { lock.lock(); defer { lock.unlock() }; result = url }
}
