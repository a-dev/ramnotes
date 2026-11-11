import ramnotesDomain
import XCTest
@testable import ramnotes

private func replaceFolderTestFile(at url: URL, with text: String) throws {
    let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID()).tmp")
    try Data(text.utf8).write(to: replacement)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: replacement, to: url)
}

final class FolderTests: XCTestCase {
    func testScanRemovesOnlyStaleTemporaryFiles() throws {
        let fixture = try TestFixture()
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = folder.appendingPathComponent(StorageFiles.temporaryPrefix + "stale")
        let fresh = folder.appendingPathComponent(StorageFiles.temporaryPrefix + "fresh")
        for url in [stale, fresh] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        _ = try FolderScanner.candidates(in: folder) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testCandidateUnchangedIDsRequireUniqueFileAndParentIdentity() throws {
        let fixture = try TestFixture()
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("same.txt")
        try Data("note".utf8).write(to: url)
        let id = NoteID()
        let location = NoteLocationRecord(id: id, resource: "file-1", path: url.path,
            parentResource: "parent-1")
        func candidates(_ files: [FileCandidate], parent: String? = "parent-1",
                        failure: NoteOperationError? = nil) -> FolderScanner.Candidates {
            FolderScanner.Candidates(files: files, parentResource: parent, failure: failure)
        }
        let match = FileCandidate(url: url, resource: "file-1", parentResource: "parent-1")

        XCTAssertEqual(candidates([match]).unchangedIDs(previous: [location]), [id])
        XCTAssertTrue(candidates([match, match]).unchangedIDs(previous: [location]).isEmpty,
            "Hard links or duplicate candidate identities must force bookmark checks.")
        XCTAssertTrue(candidates([match]).unchangedIDs(previous: [location, location]).isEmpty,
            "Duplicate prior resource identities must not be trusted.")
        XCTAssertTrue(candidates([FileCandidate(url: url, resource: nil, parentResource: "parent-1")])
            .unchangedIDs(previous: [location]).isEmpty)
        var missingResource = location
        missingResource.resource = nil
        XCTAssertTrue(candidates([match]).unchangedIDs(previous: [missingResource]).isEmpty)
        var missingParent = location
        missingParent.parentResource = nil
        XCTAssertTrue(candidates([match]).unchangedIDs(previous: [missingParent]).isEmpty)
        XCTAssertTrue(candidates([FileCandidate(url: url, resource: "file-1", parentResource: nil)])
            .unchangedIDs(previous: [location]).isEmpty)
        XCTAssertTrue(candidates([match], parent: nil).unchangedIDs(previous: [location]).isEmpty,
            "A missing enumerated folder identity must not prove that a default-folder note is unchanged.")
        XCTAssertTrue(candidates([match], parent: "moved-parent").unchangedIDs(previous: [location]).isEmpty)
        XCTAssertTrue(candidates([FileCandidate(url: url, resource: "replacement", parentResource: "parent-1")])
            .unchangedIDs(previous: [location]).isEmpty)

        var unavailable = location
        unavailable.availability = .unavailable(reason: "permission denied")
        XCTAssertTrue(candidates([match]).unchangedIDs(previous: [unavailable]).isEmpty)
        XCTAssertTrue(candidates([match], failure: .permissionDenied).unchangedIDs(previous: [location]).isEmpty)
    }

    func testCandidateSnapshotMatchesPersistedRawPathWithDotSegment() throws {
        let fixture = try TestFixture()
        let actualFolder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: actualFolder, withIntermediateDirectories: true)
        let url = actualFolder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: url)
        let captured = FolderScanner.Candidates.capture(actualFolder, failure: nil)
        let discovered = try XCTUnwrap(captured.files.first)
        let rawURL = URL(fileURLWithPath: discovered.url.deletingLastPathComponent().path + "/./" + discovered.url.lastPathComponent)
        XCTAssertNotEqual(rawURL.path, rawURL.standardizedFileURL.path,
            "This fixture must preserve a path representation that standardization changes.")
        let candidate = FileCandidate(url: rawURL, resource: discovered.resource,
            parentResource: discovered.parentResource)
        let snapshot = FolderScanner.Candidates(files: [candidate], parentResource: captured.parentResource, failure: nil)
        let id = NoteID()
        let identity = NoteLocationRecord(id: id, resource: try StorageFiles.fileResourceID(url), path: rawURL.path,
            parentResource: try StorageFiles.fileResourceID(actualFolder))

        XCTAssertEqual(snapshot.unchangedIDs(previous: [identity]), [id])
    }

    func testPreparedScanRejectsReplacementAfterCandidateEnumeration() throws {
        let fixture = try TestFixture()
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: url)
        let id = NoteID()
        let identity = NoteLocationRecord(id: id, resource: try StorageFiles.fileResourceID(url), path: url.path,
            parentResource: try StorageFiles.resourceID(folder))
        let identities = IdentityMap(catalog: CollectionCatalog(notes: [id: identity]))
        let prepared = FolderScanner.Candidates.capture(folder, failure: nil)
        try replaceFolderTestFile(at: url, with: "replacement")

        XCTAssertThrowsError(try FolderScanner(readBody: { try Data(contentsOf: $0) }).run(folder,
            identities: identities, cache: [:], collectionToken: CollectionToken(), custom: [],
            prepared: prepared, check: {})) { error in
            XCTAssertEqual(error as? NoteOperationError, .conflict)
        }
    }

    func testPreparedScanRejectsReplacementDuringSnapshotRead() throws {
        let fixture = try TestFixture()
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: url)
        let id = NoteID()
        let identity = NoteLocationRecord(id: id, resource: try StorageFiles.fileResourceID(url), path: url.path,
            parentResource: try StorageFiles.resourceID(folder))
        let identities = IdentityMap(catalog: CollectionCatalog(notes: [id: identity]))
        let prepared = FolderScanner.Candidates.capture(folder, failure: nil)
        XCTAssertThrowsError(try FolderScanner(readBody: { file in
            let data = try Data(contentsOf: file)
            try replaceFolderTestFile(at: file, with: "replacement")
            return data
        }).run(folder, identities: identities, cache: [:], collectionToken: CollectionToken(), custom: [],
            prepared: prepared, check: {})) { error in
            XCTAssertEqual(error as? NoteOperationError, .conflict)
        }
    }


    func testDefaultChangeFlushesAndRetainsOldFolderAuthorization() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let defaultSelection = try await store.openSelectedFolder()
        let defaultFolder = await store.defaultFolder()
        XCTAssertEqual(defaultSelection.url, defaultFolder)
        XCTAssertEqual(hooks.counts.started, 0)

        let firstFolder = try makeFolder(named: "First", in: fixture.root, text: "first contents")
        let secondFolder = try makeFolder(named: "Second", in: fixture.root, text: "second contents")
        let firstGeneration = try await store.switchFolder(to: firstFolder, from: defaultSelection.collectionToken)
        let firstNotes = try await store.discover(in: firstFolder, collectionToken: firstGeneration)
        let firstNote = try XCTUnwrap(firstNotes.first)
        _ = await store.submit(makeFolderEdit(firstNote, collectionToken: firstGeneration, revision: 1, text: "flushed before switch"))

        let secondGeneration = try await store.switchFolder(to: secondFolder, from: firstGeneration)
        let secondNotes = try await store.discover(in: secondFolder, collectionToken: secondGeneration)
        let secondNote = try XCTUnwrap(secondNotes.first)

        XCTAssertNotEqual(firstNote.id, secondNote.id)
        XCTAssertEqual(try String(contentsOf: firstNote.fileURL, encoding: .utf8), "flushed before switch")
        XCTAssertEqual(secondNote.text, "second contents")
        XCTAssertEqual(hooks.counts.started, 2)
        XCTAssertEqual(hooks.counts.stopped, 0, "Old notes retain their parent grant")

        _ = try await store.switchFolder(to: defaultFolder, from: secondGeneration)
        XCTAssertEqual(hooks.counts.started, 2)
        XCTAssertEqual(hooks.counts.stopped, 0, "Both old parents still contain tracked notes")
    }

    func testPreparedDefaultFolderGrantLivesThroughCommitAndReleasesWhenDiscarded() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let selection = try await store.openSelectedFolder()
        let abandoned = try makeFolder(named: "Abandoned", in: fixture.root, text: "abandoned")
        var prepared: PreparedDefaultFolderChange? = try await store.prepareDefaultFolder(to: abandoned, moveExisting: false, from: selection.collectionToken)
        XCTAssertEqual(hooks.counts.started, 1)
        XCTAssertEqual(hooks.counts.stopped, 0)
        XCTAssertNotNil(prepared)
        prepared = nil
        XCTAssertEqual(hooks.counts.stopped, 1)

        let destination = try makeFolder(named: "Destination", in: fixture.root, text: "destination")
        prepared = try await store.prepareDefaultFolder(to: destination, moveExisting: false, from: selection.collectionToken)
        let result = try await store.commitDefaultFolder(try XCTUnwrap(prepared))
        XCTAssertEqual(result.folder, destination)
        XCTAssertEqual(result.batch?.entries.count, 0)
        prepared = nil
        XCTAssertEqual(hooks.counts.started, 2)
        XCTAssertEqual(hooks.counts.stopped, 1, "The committed folder remains accessible")
    }

    func testFailedDefaultCommitReleasesPreparedGrant() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock,
            fault: { if $0 == .defaultCommit { throw NoteOperationError.permissionDenied } }, folderAccessHooks: hooks.hooks)
        let selection = try await store.openSelectedFolder()
        let destination = try makeFolder(named: "Destination", in: fixture.root, text: "destination")
        var prepared: PreparedDefaultFolderChange? = try await store.prepareDefaultFolder(to: destination, moveExisting: false, from: selection.collectionToken)
        do {
            _ = try await store.commitDefaultFolder(try XCTUnwrap(prepared))
            XCTFail("Expected commit failure")
        } catch { }
        XCTAssertEqual(hooks.counts.stopped, 0)
        prepared = nil
        XCTAssertEqual(hooks.counts.stopped, 1)
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, selection.url)
    }

    func testCancelledPickerLeavesFolderAndGenerationUnchanged() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: FolderHookRecorder().hooks)
        let folder = try makeFolder(named: "Selected", in: fixture.root, text: "note")
        let collectionToken = try await store.switchFolder(to: folder, from: (await store.currentFolder()).collectionToken)

        do {
            _ = try await store.switchFolder(to: nil, from: collectionToken)
            XCTFail("A cancelled folder picker should not switch folders")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .cancelled)
        }

        let current = await store.currentFolder()
        XCTAssertEqual(current.url, folder)
        XCTAssertEqual(current.collectionToken, collectionToken)
    }

    func testFailedPendingSaveBlocksSwitchAndKeepsOldFolderActive() async throws {
        let fixture = try TestFixture()
        let hookRecorder = FolderHookRecorder()
        let fault = FolderFaultController(failingDestination: true)
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, fault: fault.handler, folderAccessHooks: hookRecorder.hooks)
        let firstFolder = try makeFolder(named: "First", in: fixture.root, text: "old")
        let secondFolder = try makeFolder(named: "Second", in: fixture.root, text: "new")
        let collectionToken = try await store.switchFolder(to: firstFolder, from: (await store.currentFolder()).collectionToken)
        let notes = try await store.discover(in: firstFolder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        _ = await store.submit(makeFolderEdit(note, collectionToken: collectionToken, revision: 1, text: "pending data"))

        do {
            _ = try await store.switchFolder(to: secondFolder, from: collectionToken)
            XCTFail("A failed flush should prevent switching folders")
        } catch {
            // The pending edit stays available to retry or export.
        }

        let current = await store.currentFolder()
        let pending = await store.hasPendingEdits()
        let disposable = await store.canDispose(note.id)
        XCTAssertEqual(current.url, firstFolder)
        XCTAssertEqual(current.collectionToken, collectionToken)
        XCTAssertTrue(pending)
        XCTAssertFalse(disposable)
        XCTAssertEqual(hookRecorder.counts.started, 1, "The new folder should not be acquired before the flush succeeds")
    }

    func testDroppedFileWithoutScopeRegistersThroughBookmark() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let selection = try await store.openSelectedFolder()
        let folder = try makeFolder(named: "Dropped", in: fixture.root, text: "dropped contents")
        let dropped = folder.appendingPathComponent("Untitled.txt")
        try Data("dropped contents".utf8).write(to: dropped)
        hooks.requireBookmarkScope(dropped)

        let note = try await store.registerFile(dropped, collectionToken: selection.collectionToken)

        XCTAssertEqual(note.text, "dropped contents")
        XCTAssertEqual(hooks.counts.started, 1)
        XCTAssertEqual(hooks.counts.resolved, 1)
    }

    func testDeniedFileRegistrationStillFailsAfterBookmarkRoundTrip() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let selection = try await store.openSelectedFolder()
        let folder = try makeFolder(named: "Denied", in: fixture.root, text: "denied")
        let denied = folder.appendingPathComponent("Untitled.txt")
        try Data("denied".utf8).write(to: denied)
        hooks.deny(denied)

        do {
            _ = try await store.registerFile(denied, collectionToken: selection.collectionToken)
            XCTFail("A file without any grant should not register")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .permissionDenied)
        }
        XCTAssertEqual(hooks.counts.started, 0)
    }

    func testDeniedOrMissingFolderAcquisitionPreservesOldLeaseAndBalancesAccess() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let selected = try makeFolder(named: "Selected", in: fixture.root, text: "note")
        let collectionToken = try await store.switchFolder(to: selected, from: (await store.currentFolder()).collectionToken)
        let denied = fixture.root.appendingPathComponent("Denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        hooks.deny(denied)

        do {
            _ = try await store.switchFolder(to: denied, from: collectionToken)
            XCTFail("Denied scope should not be acquired")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .permissionDenied)
        }
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, selected)

        let missing = fixture.root.appendingPathComponent("Missing", isDirectory: true)
        do {
            _ = try await store.switchFolder(to: missing, from: collectionToken)
            XCTFail("A missing folder should not be selected")
        } catch { }
        XCTAssertEqual(hooks.counts.started, 2)
        XCTAssertEqual(hooks.counts.stopped, 1, "The failed acquisition must release its temporary lease")

        _ = try await store.switchFolder(to: await store.defaultFolder(), from: collectionToken)
        XCTAssertEqual(hooks.counts.started, 2)
        XCTAssertEqual(hooks.counts.stopped, 1, "Only the failed acquisition releases its lease; tracked notes retain the old parent")
    }

    func testDefaultChangeRetainsOldSavesWhileRejectingWrongDirectoryFixtureScan() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: FolderHookRecorder().hooks)
        let firstFolder = try makeFolder(named: "First", in: fixture.root, text: "first")
        let secondFolder = try makeFolder(named: "Second", in: fixture.root, text: "second")
        let firstGeneration = try await store.switchFolder(to: firstFolder, from: (await store.currentFolder()).collectionToken)
        let firstNotes = try await store.discover(in: firstFolder, collectionToken: firstGeneration)
        let firstNote = try XCTUnwrap(firstNotes.first)
        let oldEdit = makeFolderEdit(firstNote, collectionToken: firstGeneration, revision: 1, text: "stale content")
        let secondGeneration = try await store.switchFolder(to: secondFolder, from: firstGeneration)
        let secondNotes = await store.records
        let secondNote = try XCTUnwrap(secondNotes.values.first { $0.fileURL.deletingLastPathComponent() == secondFolder })

        guard case .saved = await store.save(oldEdit) else {
            return XCTFail("The retained old note must remain writable")
        }
        do {
            _ = try await store.discover(in: firstFolder, collectionToken: firstGeneration)
            XCTFail("Stale discovery must be rejected")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .staleCollection)
        }
        await store.externalEvent(collectionToken: firstGeneration)

        let current = await store.currentFolder()
        let active = await store.records[secondNote.id]
        XCTAssertEqual(current.url, secondFolder)
        XCTAssertEqual(current.collectionToken, secondGeneration)
        XCTAssertEqual(active?.text, "second")
        XCTAssertEqual(try String(contentsOf: secondNote.fileURL, encoding: .utf8), "second")
    }

    func testRestartResolvesAndRefreshesPersistedStaleBookmark() async throws {
        let fixture = try TestFixture()
        let folder = try makeFolder(named: "Selected", in: fixture.root, text: "persisted")
        let hooks = FolderHookRecorder()
        do {
            let originalStore = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
            _ = try await originalStore.switchFolder(to: folder, from: (await originalStore.currentFolder()).collectionToken)
        }

        let restarted = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let selection = try await restarted.openSelectedFolder()
        let notes = try await restarted.discover(in: folder, collectionToken: selection.collectionToken)

        XCTAssertEqual(selection.url, folder)
        XCTAssertEqual(notes.first?.text, "persisted")
        XCTAssertGreaterThanOrEqual(hooks.counts.resolved, 1, "Folder and registered file locators resolve independently")
        XCTAssertGreaterThanOrEqual(hooks.counts.bookmarked, 2, "Restart should resolve the saved bookmark and persist a refreshed bookmark")
        XCTAssertEqual(hooks.lastResolvedStale, true)
    }

    func testExportRetainsBufferAndJournalAndAllowsSwitchAfterOldFolderDisappears() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: FolderHookRecorder().hooks)
        let firstFolder = try makeFolder(named: "First", in: fixture.root, text: "original")
        let secondFolder = try makeFolder(named: "Second", in: fixture.root, text: "other")
        let collectionToken = try await store.switchFolder(to: firstFolder, from: (await store.currentFolder()).collectionToken)
        let notes = try await store.discover(in: firstFolder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        let edit = makeFolderEdit(note, collectionToken: collectionToken, revision: 1, text: "retained exported draft")
        _ = await store.submit(edit)
        let movedFolder = fixture.root.appendingPathComponent("First unavailable", isDirectory: true)
        try FileManager.default.moveItem(at: firstFolder, to: movedFolder)
        let exportURL = fixture.root.appendingPathComponent("explicit-export.txt")
        try await store.export(note.id, to: exportURL)

        let newGeneration = try await store.switchFolder(to: secondFolder, from: collectionToken)
        let retained = await store.retainedBuffer(note.id)
        let recoveries = await store.retainedRecovery()

        XCTAssertEqual(try Data(contentsOf: exportURL), Data(edit.text.utf8))
        XCTAssertEqual(retained?.text, edit.text)
        let seeded = await store.retainedEdits()
        XCTAssertEqual(seeded[note.id]?.text, edit.text, "The same collection retains its exported buffer")
        XCTAssertTrue(recoveries.edits.contains(where: { $0.noteID == note.id && $0.text == edit.text }))
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, secondFolder)
        XCTAssertEqual(newGeneration, collectionToken)
    }

    func testReturningToDefaultPreservesPerNoteHighWaterState() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: FolderHookRecorder().hooks)
        let firstFolder = try makeFolder(named: "First", in: fixture.root, text: "first")
        let secondFolder = try makeFolder(named: "Second", in: fixture.root, text: "second")
        let firstGeneration = try await store.switchFolder(to: firstFolder, from: (await store.currentFolder()).collectionToken)
        let firstNotes = try await store.discover(in: firstFolder, collectionToken: firstGeneration)
        let note = try XCTUnwrap(firstNotes.first)
        _ = await store.submit(makeFolderEdit(note, collectionToken: firstGeneration, revision: 3, text: "saved in first"))

        let secondGeneration = try await store.switchFolder(to: secondFolder, from: firstGeneration)
        let returnedGeneration = try await store.switchFolder(to: firstFolder, from: secondGeneration)
        let returnedNotes = try await store.discover(in: firstFolder, collectionToken: returnedGeneration)
        let returned = try XCTUnwrap(returnedNotes.first)
        let status = await store.status(note.id)
        let journal = await store.journalRecords[note.id]

        XCTAssertEqual(returned.id, note.id, "Identity survives leaving and returning to a folder")
        XCTAssertEqual(status, .saved(EditRevision(rawValue: 3)), "Default changes preserve edit high-water state")
        XCTAssertNil(journal)
        let edit = makeFolderEdit(returned, collectionToken: returnedGeneration, revision: 4, text: "typed after return")
        let submitted = await store.submit(edit)
        XCTAssertEqual(submitted, .pending(edit.revision))
        try await store.flush()
        XCTAssertEqual(try String(contentsOf: returned.fileURL, encoding: .utf8), "typed after return")
    }

    func testRecoveryJournalFollowsFolderIdentityAndIgnoresReusedPath() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let originalFolder = try makeFolder(named: "Original", in: fixture.root, text: "same base")
        let originalStore = try NoteStore(
            support: fixture.root,
            clock: fixture.clock,
            fault: FolderFaultController(failingDestination: true).handler,
            folderAccessHooks: hooks.hooks
        )
        let originalGeneration = try await originalStore.switchFolder(
            to: originalFolder,
            from: (await originalStore.currentFolder()).collectionToken
        )
        let originalNotes = try await originalStore.discover(in: originalFolder, collectionToken: originalGeneration)
        let originalNote = try XCTUnwrap(originalNotes.first)
        let edit = makeFolderEdit(originalNote, collectionToken: originalGeneration, revision: 1, text: "journal belongs to renamed folder")
        _ = await originalStore.submit(edit)
        guard case .failed(.permissionDenied) = await originalStore.save(edit) else {
            return XCTFail("Injected destination failure should leave the folder-bound journal")
        }
        let originalRecovery = await originalStore.retainedRecovery()
        let savedJournal = try XCTUnwrap(originalRecovery.edits.first)
        let savedRecord = await originalStore.journalRecords[savedJournal.noteID]
        XCTAssertNotNil(savedRecord?.folderIdentity)

        let renamedFolder = fixture.root.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: originalFolder, to: renamedFolder)
        let replacementFolder = try makeFolder(named: "Original", in: fixture.root, text: "same base")
        let restarted = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks.hooks)
        let replacementGeneration = try await restarted.switchFolder(
            to: replacementFolder,
            from: (await restarted.currentFolder()).collectionToken
        )
        let replacementNotes = try await restarted.discover(in: replacementFolder, collectionToken: replacementGeneration)
        let replacementNotices = await restarted.recoveryNotices()
        let replacementRecovery = await restarted.retainedRecovery()
        let retainedJournal = try XCTUnwrap(replacementRecovery.edits.first)

        XCTAssertEqual(replacementNotes.first?.text, "same base")
        XCTAssertTrue(replacementNotices.isEmpty)
        XCTAssertEqual(retainedJournal.id, savedJournal.id)
        XCTAssertEqual(retainedJournal.text, edit.text)

        let renamedGeneration = try await restarted.switchFolder(to: renamedFolder, from: replacementGeneration)
        let restored = try await restarted.read(originalNote.id, collectionToken: renamedGeneration)
        let remainingRecovery = await restarted.retainedRecovery()

        XCTAssertEqual(restored.fileURL, renamedFolder.appendingPathComponent("Same.txt"))
        XCTAssertEqual(restored.text, edit.text)
        XCTAssertFalse(remainingRecovery.edits.contains(where: { $0.id == savedJournal.id }))
    }

    func testFinalCompositionAfterExportRemainsPendingWhenFolderIsUnavailable() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: FolderHookRecorder().hooks)
        let folder = try makeFolder(named: "Selected", in: fixture.root, text: "base")
        let collectionToken = try await store.switchFolder(to: folder, from: (await store.currentFolder()).collectionToken)
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        try await store.setWriting(true, for: note.id)
        let initialComposition = makeFolderEdit(note, collectionToken: collectionToken, revision: 1, text: "exported draft")
        _ = await store.submit(initialComposition)
        let exportURL = fixture.root.appendingPathComponent("composition-export.txt")
        try await store.export(note.id, to: exportURL)

        let movedFolder = fixture.root.appendingPathComponent("Unavailable", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: movedFolder)
        let finalComposition = makeFolderEdit(note, collectionToken: collectionToken, revision: 2, text: "new final marked text")
        do { try await store.finishWriting(finalComposition) } catch { }

        let pending = await store.hasPendingEdits()
        let canDispose = await store.canDispose(note.id)
        let retained = await store.retainedBuffer(note.id)
        let recoveries = await store.retainedRecovery()
        let journal = try XCTUnwrap(recoveries.edits.first)
        XCTAssertTrue(pending)
        XCTAssertFalse(canDispose)
        XCTAssertEqual(retained?.revision, finalComposition.revision)
        XCTAssertEqual(retained?.text, finalComposition.text)
        XCTAssertEqual(journal.editRevision, finalComposition.revision)
        XCTAssertEqual(journal.text, finalComposition.text)
        XCTAssertEqual(try Data(contentsOf: exportURL), Data(initialComposition.text.utf8))
    }

    func testFinishWritingEndsSessionIfFinalRevisionWasAlreadySaved() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: FolderHookRecorder().hooks)
        let folder = try makeFolder(named: "Selected", in: fixture.root, text: "base")
        let collectionToken = try await store.switchFolder(to: folder, from: (await store.currentFolder()).collectionToken)
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        try await store.setWriting(true, for: note.id)
        let finalComposition = makeFolderEdit(note, collectionToken: collectionToken, revision: 1, text: "already saved composition")
        _ = await store.submit(finalComposition)
        guard case .saved = await store.save(finalComposition) else {
            return XCTFail("The final composition should save before the writing session ends")
        }

        try await store.finishWriting(finalComposition)

        let stillPendingWriting = await store.writing.contains(note.id)
        let canDispose = await store.canDispose(note.id)
        XCTAssertFalse(stillPendingWriting)
        XCTAssertTrue(canDispose)
        XCTAssertEqual(try Data(contentsOf: note.fileURL), Data(finalComposition.text.utf8))
    }

    func testExportReplacesConfirmedExistingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("export.txt")
        try StorageFiles.export(Data("first, longer text".utf8), to: url)
        try StorageFiles.export(Data("second".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("second".utf8))
    }

    func testEvictedStampMatchesOnlyUnchangedDownloadedFile() {
        let date = Date(timeIntervalSince1970: 1_000)
        let downloaded = StorageFiles.Stamp(resource: "r", size: 47, modified: date, changed: date, downloading: nil, created: nil)
        func evicted(resource: String = "r", size: Int = 47, modified: Date = date) -> StorageFiles.Stamp {
            StorageFiles.Stamp(resource: resource, size: size, modified: modified, changed: date.addingTimeInterval(9),
                               downloading: .notDownloaded, created: nil, dataless: true)
        }
        XCTAssertTrue(evicted().isEvictedCopy(of: downloaded))
        XCTAssertFalse(evicted(resource: "other").isEvictedCopy(of: downloaded))
        XCTAssertFalse(evicted(size: 48).isEvictedCopy(of: downloaded))
        XCTAssertFalse(evicted(modified: date.addingTimeInterval(1)).isEvictedCopy(of: downloaded))
        XCTAssertFalse(downloaded.isEvictedCopy(of: downloaded))
    }
}

private struct FolderCounts: Equatable {
    var started: Int
    var stopped: Int
    var bookmarked: Int = 0
    var resolved: Int = 0
}

private final class FolderHookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var stopped = 0
    private var bookmarked = 0
    private var resolved = 0
    private var deniedPaths: Set<String> = []
    private var unscopedPaths: Set<String> = []
    private var scopedPaths: Set<String> = []
    private var resolvedStale: Bool?
    private var redirects: [String: URL] = [:]

    var hooks: FolderAccessHooks {
        FolderAccessHooks(
            bookmark: { [self] url in
                lock.lock(); defer { lock.unlock() }
                bookmarked += 1
                return Data(url.path.utf8)
            },
            resolve: { [self] data in
                lock.lock(); defer { lock.unlock() }
                resolved += 1
                resolvedStale = true
                let path = String(decoding: data, as: UTF8.self)
                scopedPaths.insert(path)
                return (redirects[path] ?? URL(fileURLWithPath: path), true)
            },
            start: { [self] url in
                lock.lock(); defer { lock.unlock() }
                let path = url.standardizedFileURL.path
                if deniedPaths.contains(path) || (unscopedPaths.contains(path) && !scopedPaths.contains(path)) { return false }
                started += 1
                return true
            },
            stop: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                stopped += 1
            }
        )
    }

    var counts: FolderCounts {
        lock.lock(); defer { lock.unlock() }
        return FolderCounts(started: started, stopped: stopped, bookmarked: bookmarked, resolved: resolved)
    }

    var lastResolvedStale: Bool? {
        lock.lock(); defer { lock.unlock() }
        return resolvedStale
    }

    func redirect(_ old: URL, to new: URL) {
        lock.lock(); defer { lock.unlock() }
        redirects[old.path] = new
    }

    func deny(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        deniedPaths.insert(url.standardizedFileURL.path)
    }

    /// Models a dropped URL: access starts only after a bookmark round trip adds the scope.
    func requireBookmarkScope(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        unscopedPaths.insert(url.standardizedFileURL.path)
    }
}

private final class FolderFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var failDestination: Bool

    init(failingDestination: Bool) { failDestination = failingDestination }

    var handler: StorageFault {
        { [self] stage in
            guard case .destination = stage else { return }
            lock.lock(); defer { lock.unlock() }
            if failDestination { throw NoteOperationError.permissionDenied }
        }
    }
}

private func makeFolder(named name: String, in root: URL, text: String) throws -> URL {
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: folder.appendingPathComponent("Same.txt"))
    return folder
}

private func makeFolderEdit(_ note: NoteSnapshot, collectionToken: CollectionToken, revision: UInt64, text: String) -> EditSnapshot {
    EditSnapshot(id: note.id, collectionToken: collectionToken, revision: EditRevision(rawValue: revision), baseRevision: note.fileRevision, text: text)
}

extension FolderTests {
    func testSharedLeasesStartOnceAndStopAfterLastOwner() throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let folder = try makeFolder(named: "Shared", in: fixture.root, text: "shared")
        let access = FolderAccess(support: fixture.root, hooks: hooks.hooks)
        var first: FolderLease? = try access.acquire(folder)
        var second: FolderLease? = try access.acquire(folder)
        XCTAssertTrue(first === second)
        XCTAssertEqual(hooks.counts.started, 1)
        first = nil
        XCTAssertEqual(hooks.counts.stopped, 0)
        second = nil
        XCTAssertEqual(hooks.counts.stopped, 1)
    }

    func testAcquireRejectsUnreadableFolderWithPermissionFailure() throws {
        let fixture = try TestFixture()
        let folder = try makeFolder(named: "Locked", in: fixture.root, text: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let access = FolderAccess(support: fixture.root, hooks: FolderHookRecorder().hooks)
        XCTAssertThrowsError(try access.acquire(folder)) { error in
            let failure = NoteFailureMapping.accessFailure(error, bookmark: false)
            XCTAssertEqual(failure.reason, .permission)
        }
    }

    func testUnchangedReconcileRetainsPresentersAndMoveRebindsOnlyAffectedFile() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let selection = try await store.openSelectedFolder()
        let parentURL = try makeFolder(named: "Custom", in: fixture.root, text: "custom")
        let peerURL = parentURL.appendingPathComponent("peer.txt")
        try Data("peer".utf8).write(to: peerURL)
        let parent = try await store.folderAccess.acquire(parentURL)
        let custom = try await store.registerCustomFile(parentURL.appendingPathComponent("Same.txt"), parent: parent)
        let peer = try await store.registerCustomFile(peerURL, parent: parent)
        let original = await store.fileObservers
        let directory = await store.observer
        try await store.reconcile(collectionToken: selection.collectionToken)
        let unchanged = await store.fileObservers
        let unchangedDirectory = await store.observer
        XCTAssertTrue(directory === unchangedDirectory)
        XCTAssertTrue(original[custom.id] === unchanged[custom.id])
        XCTAssertTrue(original[peer.id] === unchanged[peer.id])
        let result = await store.moveNote(custom.id, to: parentURL.appendingPathComponent("renamed.txt"),
            collectionToken: custom.collectionToken, locationRevision: custom.locationRevision, editRevision: custom.editRevision)
        guard case .moved = result.outcome else { return XCTFail("Move failed") }
        let moved = await store.fileObservers
        XCTAssertFalse(original[custom.id] === moved[custom.id])
        XCTAssertTrue(original[peer.id] === moved[peer.id])
        XCTAssertEqual(moved[custom.id]?.presentedItemURL?.lastPathComponent, "renamed.txt")
    }

    func testCollectionLoadsOnlySelectedCustomFileAndSavesOnlyItsBody() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let reads = CollectionReadRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks, readBody: reads.read)
        let selection = try await store.openSelectedFolder()
        let defaultURL = selection.url.appendingPathComponent("arbitrary.TXT")
        try Data("same contents".utf8).write(to: defaultURL)
        try await store.reconcile(collectionToken: selection.collectionToken)
        let parentURL = try makeFolder(named: "Custom", in: fixture.root, text: "same contents")
        let sibling = parentURL.appendingPathComponent("unselected.txt")
        try Data("private sibling".utf8).write(to: sibling)
        let access = await store.folderAccess
        let parent = try access.acquire(parentURL)
        let custom = try await store.registerCustomFile(parentURL.appendingPathComponent("Same.txt"), parent: parent)
        let records = await store.records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.values.map(\.id)).count, 2)
        XCTAssertFalse(records.values.contains { $0.fileURL == sibling })
        reads.clear()
        let edit = EditSnapshot(id: custom.id, collectionToken: selection.collectionToken, revision: .init(rawValue: 1),
            baseRevision: custom.fileRevision, text: "custom save", locationRevision: custom.locationRevision)
        guard case .saved = await store.save(edit) else { return XCTFail("Custom save failed") }
        XCTAssertEqual(Set(reads.paths), [custom.fileURL.path])
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(Set(reopened.notes.map(\.id)), Set(records.keys))
        XCTAssertFalse(reopened.notes.contains { $0.fileURL == sibling })
        XCTAssertEqual(reopened.notes.first { $0.id == custom.id }?.text, "custom save")
    }

    func testExternalMovesAcrossDefaultBoundaryKeepIdentityAndExcludeSiblings() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let selected = try await store.openSelectedFolder()
        let original = try await store.create(in: selected.url, collectionToken: selected.collectionToken)
        let parent = try makeFolder(named: "Outside", in: fixture.root, text: "unselected sibling")
        let movedURL = parent.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: original.fileURL, to: movedURL)
        hooks.redirect(original.fileURL, to: movedURL)
        try await store.reconcile(collectionToken: selected.collectionToken)
        let outside = await store.records
        XCTAssertEqual(outside.count, 1)
        let custom = try XCTUnwrap(outside[original.id])
        XCTAssertEqual(custom.fileURL, movedURL)
        XCTAssertEqual(custom.availability, .available)
        XCTAssertGreaterThan(custom.locationRevision.rawValue, original.locationRevision.rawValue)
        let backURL = selected.url.appendingPathComponent("back.TXT")
        try FileManager.default.moveItem(at: movedURL, to: backURL)
        hooks.redirect(movedURL, to: backURL)
        hooks.redirect(original.fileURL, to: backURL)
        try await store.reconcile(collectionToken: selected.collectionToken)
        let inside = await store.records
        XCTAssertEqual(inside.count, 1)
        XCTAssertEqual(inside[original.id]?.fileURL, backURL)
        XCTAssertGreaterThan(inside[original.id]?.locationRevision.rawValue ?? 0, custom.locationRevision.rawValue)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(reopened.notes.map(\.id), [original.id])
    }

    func testAncestorPathAliasDoesNotDuplicateAnAlreadyDiscoveredDefaultFile() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let selected = try await store.openSelectedFolder()
        let note = try await store.create(in: selected.url, collectionToken: selected.collectionToken)
        let alias = fixture.root.appendingPathComponent("AncestorAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let aliasedParent = alias.appendingPathComponent("Notes", isDirectory: true)
        let access = await store.folderAccess
        let same = try await store.registerCustomFile(aliasedParent.appendingPathComponent(note.fileURL.lastPathComponent),
            parent: access.acquire(aliasedParent))
        XCTAssertEqual(same.id, note.id)
        try await store.reconcile(collectionToken: selected.collectionToken)
        let records = await store.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[note.id]?.id, note.id)
    }

    func testFinalCompositionAfterExternalRenameUsesVerifiedCurrentLocation() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root)
        let selected = try await store.openSelectedFolder()
        let note = try await store.create(in: selected.url, collectionToken: selected.collectionToken)
        try await store.setWriting(true, for: note.id)
        let moved = selected.url.appendingPathComponent("composing.txt")
        try FileManager.default.moveItem(at: note.fileURL, to: moved)
        try await store.reconcile(collectionToken: selected.collectionToken)
        let final = EditSnapshot(id: note.id, collectionToken: selected.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "final composition", locationRevision: note.locationRevision)
        try await store.finishWriting(final)
        try await store.flush(note.id)
        let writing = await store.writing
        XCTAssertFalse(writing.contains(note.id))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), final.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
    }

    func testCustomSaveFollowsVerifiedBookmarkInsteadOfReplacementAtOldPath() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let selected = try await store.openSelectedFolder()
        let parent = try makeFolder(named: "Custom", in: fixture.root, text: "original")
        let access = await store.folderAccess
        let note = try await store.registerCustomFile(parent.appendingPathComponent("Same.txt"), parent: access.acquire(parent))
        let moved = parent.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: note.fileURL, to: moved)
        try Data("unrelated replacement".utf8).write(to: note.fileURL)
        hooks.redirect(note.fileURL, to: moved)
        let edit = EditSnapshot(id: note.id, collectionToken: selected.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "saved to original", locationRevision: note.locationRevision)
        guard case .saved = await store.save(edit) else { return XCTFail("Verified bookmark move must save to original") }
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), edit.text)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "unrelated replacement")
        let records = await store.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[note.id]?.fileURL, moved)
    }

    func testDefaultDirectoryBookmarkRelocationPreservesCollectionAndNote() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let old = try makeFolder(named: "Selected", in: fixture.root, text: "same content")
        let token = try await store.switchFolder(to: old, from: (await store.currentFolder()).collectionToken)
        let before = await store.records
        let note = try XCTUnwrap(before.values.first)
        let moved = fixture.root.appendingPathComponent("RenamedFolder", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: moved)
        hooks.redirect(old, to: moved)
        hooks.redirect(note.fileURL, to: moved.appendingPathComponent(note.fileURL.lastPathComponent))
        try await store.reconcile(collectionToken: token)
        let current = await store.currentFolder()
        let after = await store.records
        XCTAssertEqual(current.collectionToken, token)
        XCTAssertEqual(current.url, moved)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[note.id]?.text, note.text)
        XCTAssertEqual(after[note.id]?.fileURL.deletingLastPathComponent(), moved)
    }

    func testCustomAtomicReplacementKeepsIdentityAndAccessLossRetainsJournal() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let selected = try await store.openSelectedFolder()
        let parent = try makeFolder(named: "Custom", in: fixture.root, text: "before")
        let access = await store.folderAccess
        let original = try await store.registerCustomFile(parent.appendingPathComponent("Same.txt"), parent: access.acquire(parent))
        try StorageFiles.atomic(Data("external replacement".utf8), at: original.fileURL)
        try await store.reconcile(collectionToken: selected.collectionToken)
        let records = await store.records
        XCTAssertEqual(records[original.id]?.text, "external replacement")
        XCTAssertEqual(records[original.id]?.locationRevision, original.locationRevision)
        hooks.deny(original.fileURL)
        let reads = CollectionReadRecorder()
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks, readBody: reads.read)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(reopened.notes.map(\.id), [original.id])
        XCTAssertNotEqual(reopened.notes.first?.availability, .available)
        XCTAssertTrue(reads.paths.isEmpty)
        let edit = EditSnapshot(id: original.id, collectionToken: reopened.collectionToken, revision: .init(rawValue: 1),
            baseRevision: original.fileRevision, text: "retained despite denial", locationRevision: original.locationRevision)
        guard case .failed = await restarted.save(edit) else { return XCTFail("Denied access must fail") }
        let recovery = await restarted.retainedRecovery()
        XCTAssertEqual(recovery.edits.first?.text, edit.text)
        XCTAssertEqual(try String(contentsOf: original.fileURL, encoding: .utf8), "external replacement")
    }

    func testDirtyRenameRebindsRetainedEditAndRejectsAlreadyDispatchedSave() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root)
        let selected = try await store.openSelectedFolder()
        let note = try await store.create(in: selected.url, collectionToken: selected.collectionToken)
        let edit = EditSnapshot(id: note.id, collectionToken: selected.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "retained draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        let moved = selected.url.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: note.fileURL, to: moved)
        try await store.reconcile(collectionToken: selected.collectionToken)
        guard case .failed(.staleLocation) = await store.save(edit) else { return XCTFail("Old dispatched save accepted") }
        let retained = await store.retainedBuffer(note.id)
        XCTAssertGreaterThan(retained?.locationRevision.rawValue ?? 0, edit.locationRevision.rawValue)
        try await store.flush(note.id)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), edit.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
    }

    func testUnavailableCustomFileRemainsTrackedWithoutSiblingDiscovery() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let selection = try await store.openSelectedFolder()
        let parentURL = try makeFolder(named: "Custom", in: fixture.root, text: "original")
        let access = await store.folderAccess
        let note = try await store.registerCustomFile(parentURL.appendingPathComponent("Same.txt"), parent: access.acquire(parentURL))
        try FileManager.default.removeItem(at: note.fileURL)
        try Data("unrelated".utf8).write(to: parentURL.appendingPathComponent("Other.txt"))
        try await store.reconcile(collectionToken: selection.collectionToken)
        let records = await store.records
        XCTAssertEqual(records.count, 1)
        let unavailable = try XCTUnwrap(records[note.id])
        XCTAssertNotEqual(unavailable.availability, .available)
        let edit = EditSnapshot(id: note.id, collectionToken: selection.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "retained local text", locationRevision: note.locationRevision)
        guard case .failed = await store.save(edit) else { return XCTFail("Missing custom file must not be recreated") }
        let retained = await store.retainedBuffer(note.id)
        XCTAssertEqual(retained?.text, edit.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(reopened.notes.map(\.id), [note.id])
        let restored = await restarted.retainedBuffer(note.id)
        XCTAssertEqual(restored?.text, edit.text)
    }

    func testDeniedDefaultStillLoadsCustomAndDoesNotReadDeniedBodies() async throws {
        let fixture = try TestFixture()
        let hooks = FolderHookRecorder()
        let selected = try makeFolder(named: "SelectedDefault", in: fixture.root, text: "default")
        let customParent = try makeFolder(named: "Custom", in: fixture.root, text: "custom")
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks)
        let token = try await store.switchFolder(to: selected, from: (await store.currentFolder()).collectionToken)
        let access = await store.folderAccess
        let custom = try await store.registerCustomFile(customParent.appendingPathComponent("Same.txt"), parent: access.acquire(customParent))
        hooks.deny(selected)
        let reads = CollectionReadRecorder()
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks.hooks, readBody: reads.read)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(reopened.notes.count, 2)
        XCTAssertEqual(reopened.notes.first { $0.id == custom.id }?.text, "custom")
        XCTAssertNotEqual(reopened.notes.first { $0.id != custom.id }?.availability, .available)
        XCTAssertFalse(reads.paths.contains(selected.appendingPathComponent("Same.txt").path))
        _ = token
    }

    func testPublishedLocationRevisionRejectsOldSaveAndOldCollectionCallback() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root)
        let selected = try await store.openSelectedFolder()
        let note = try await store.create(in: selected.url, collectionToken: selected.collectionToken)
        let renamed = selected.url.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: note.fileURL, to: renamed)
        try await store.reconcile(collectionToken: selected.collectionToken)
        let currentRecords = await store.records
        let current = try XCTUnwrap(currentRecords[note.id])
        XCTAssertGreaterThan(current.locationRevision.rawValue, note.locationRevision.rawValue)
        let stale = EditSnapshot(id: note.id, collectionToken: selected.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "must not write", locationRevision: note.locationRevision)
        guard case .failed(.staleLocation) = await store.save(stale) else { return XCTFail("Old location accepted") }
        let before = await store.reconcileCount
        await store.externalEvent(collectionToken: CollectionToken())
        let after = await store.reconcileCount
        XCTAssertEqual(after, before)
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
    }
}

private final class CollectionReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func clear() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
    var read: @Sendable (URL) throws -> Data { { [self] url in
        lock.lock(); values.append(url.path); lock.unlock()
        return try Data(contentsOf: url)
    } }
}
