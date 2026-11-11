import ramnotesDomain
import XCTest
import Synchronization
import Darwin
@testable import ramnotes

final class LocationTests: XCTestCase {
    func testRegisterFilePreservesOriginalAndIdentityAcrossRestart() async throws {
        let fixture = try TestFixture()
        let external = fixture.root.appendingPathComponent("external.txt")
        try Data("original text".utf8).write(to: external)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let first = try await store.registerFile(external, collectionToken: selection.collectionToken)
        let again = try await store.registerFile(external, collectionToken: selection.collectionToken)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(first.fileURL, external)
        XCTAssertEqual(first.text, "original text")
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "original text")
        let edit = EditSnapshot(id: first.id, collectionToken: first.collectionToken,
            revision: EditRevision(rawValue: 1), baseRevision: first.fileRevision, text: "edited original")
        guard case .saved = await store.save(edit) else { return XCTFail("Dropped note could not be saved") }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "edited original")
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(reopened.notes.map(\.id), [first.id])
        XCTAssertEqual(reopened.notes.first?.text, "edited original")
    }

    func testRegisterHardLinkDeduplicatesByVerifiedIdentity() async throws {
        let fixture = try TestFixture()
        let original = fixture.root.appendingPathComponent("original.txt")
        let hardLink = fixture.root.appendingPathComponent("hard-link.txt")
        try Data("same file".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()

        let first = try await store.registerFile(original, collectionToken: selection.collectionToken)
        let second = try await store.registerFile(hardLink, collectionToken: selection.collectionToken)

        XCTAssertEqual(second.id, first.id)
        let records = await store.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try Data(contentsOf: original), Data("same file".utf8))
        XCTAssertEqual(try Data(contentsOf: hardLink), Data("same file".utf8))
    }

    func testRegisterFilesKeepsSuccessfulBatchEntriesWhenAnotherFileFails() async throws {
        let fixture = try TestFixture()
        let valid = fixture.root.appendingPathComponent("valid.txt")
        let invalid = fixture.root.appendingPathComponent("invalid.txt")
        try Data("valid text".utf8).write(to: valid)
        try Data([0xff, 0xfe]).write(to: invalid)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()

        let results = await store.registerFiles([valid, invalid], collectionToken: selection.collectionToken)

        XCTAssertEqual(results.map(\.url), [valid, invalid])
        guard case let .success(registered) = results[0].outcome else { return XCTFail("Valid file was not registered") }
        XCTAssertEqual(registered.fileURL, valid)
        guard case .failure = results[1].outcome else { return XCTFail("Invalid UTF-8 file was accepted") }
        let records = await store.records
        XCTAssertEqual(records.values.map(\.id), [registered.id])
        XCTAssertEqual(try Data(contentsOf: invalid), Data([0xff, 0xfe]))
    }

    func testFileOnlyRepeatedSavesAndRestartPreserveBytesAndMetadata() async throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("external.txt")
        try Data([0xef, 0xbb, 0xbf] + Array("original\r\n".utf8)).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        var fileHooks = hooks
        fileHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
        let selection = try await store.openSelectedFolder()
        var note = try await store.registerFile(url, collectionToken: selection.collectionToken)
        let id = note.id
        for revision in 1...3 {
            let edit = EditSnapshot(id: id, collectionToken: note.collectionToken,
                revision: EditRevision(rawValue: UInt64(revision)), baseRevision: note.fileRevision,
                text: "save \(revision) 🌍\nnext\n", locationRevision: note.locationRevision)
            guard case .saved = await store.save(edit) else { return XCTFail("Repeated file save failed") }
            note = try await store.read(id, collectionToken: note.collectionToken)
            XCTAssertEqual(try Data(contentsOf: url), Data([0xef, 0xbb, 0xbf] + Array("save \(revision) 🌍\r\nnext\r\n".utf8)))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
        }
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
        let reopened = try await restarted.openSelectedFolder()
        let restored = try XCTUnwrap(reopened.notes.first { $0.id == id })
        let edit = EditSnapshot(id: id, collectionToken: restored.collectionToken,
            revision: EditRevision(rawValue: 4), baseRevision: restored.fileRevision,
            text: "after restart\n", locationRevision: restored.locationRevision)
        guard case .saved = await restarted.save(edit) else { return XCTFail("Restarted file save failed") }
        XCTAssertEqual(try Data(contentsOf: url), Data([0xef, 0xbb, 0xbf] + Array("after restart\r\n".utf8)))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(StorageFiles.temporaryPrefix) })
    }

    func testFileSaveCheckpointFailuresKeepJournalAndAllowRetry() async throws {
        for failBookmark in [true, false] {
            let fixture = try TestFixture()
            let url = fixture.root.appendingPathComponent("external.txt")
            try Data("original".utf8).write(to: url)
            let fail = Mutex(false)
            var fileHooks = hooks
            fileHooks.bookmark = { url in
                if failBookmark && fail.withLock({ $0 }) { throw NoteOperationError.inputOutput("bookmark failed") }
                return Data(url.path.utf8)
            }
            let catalog = fixture.root.appendingPathComponent("collection.json")
            let store = try NoteStore(support: fixture.root, fault: { stage in
                if case .destination = stage, fail.withLock({ $0 }), !failBookmark {
                    try FileManager.default.removeItem(at: catalog)
                    try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
                }
            }, folderAccessHooks: fileHooks)
            let selection = try await store.openSelectedFolder()
            let note = try await store.registerFile(url, collectionToken: selection.collectionToken)
            let catalogBytes = try Data(contentsOf: catalog)
            fail.withLock { $0 = true }
            let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken,
                revision: EditRevision(rawValue: 1), baseRevision: note.fileRevision, text: "retained")
            guard case .failed = await store.save(edit) else { return XCTFail("Checkpoint failure was ignored") }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "retained")
            let retained = await store.retainedBuffer(note.id)
            XCTAssertEqual(retained?.text, edit.text)
            let recovery = await store.retainedRecovery()
            XCTAssertTrue(recovery.edits.contains { $0.noteID == note.id && $0.text == edit.text })
            fail.withLock { $0 = false }
            if !failBookmark {
                try FileManager.default.removeItem(at: catalog)
                try catalogBytes.write(to: catalog)
            }
            guard case .saved = await store.retry(note.id) else { return XCTFail("Checkpoint retry failed") }
            let remaining = await store.retainedRecovery()
            XCTAssertFalse(remaining.edits.contains { $0.noteID == note.id })
        }
    }

    func testExternalReplacementDuringSaveReadPreservesExternalBytes() async throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("external.txt")
        try Data("original".utf8).write(to: url)
        let replaceOnRead = Mutex(false)
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks, readBody: { target in
            let data = try Data(contentsOf: target)
            if target == url, replaceOnRead.withLock({ flag in let old = flag; flag = false; return old }) {
                // Simulate an uncooperative writer replacing the resource after our initial identity check.
                try StorageFiles.atomic(Data("external replacement".utf8), at: target)
            }
            return data
        })
        let selection = try await store.openSelectedFolder()
        let note = try await store.registerFile(url, collectionToken: selection.collectionToken)
        replaceOnRead.withLock { $0 = true }
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken,
            revision: EditRevision(rawValue: 1), baseRevision: note.fileRevision, text: "retained local text")
        guard case let .recovered(recovery) = await store.save(edit) else { return XCTFail("Replacement must require conflict recovery") }
        XCTAssertEqual(recovery.text, edit.text)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external replacement")
    }

    func testDocumentStagingFailurePreservesOriginalBytes() throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("external.txt")
        let original = Data("original".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try StorageFiles.saveAuthorizedFile(Data("new".utf8), at: url,
            afterStaging: { throw NoteOperationError.inputOutput("staged failure") }))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try StorageFiles.saveAuthorizedFile(Data("retry".utf8), at: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("retry".utf8))
    }

    func testRegisterFileRejectsInvalidContentWithoutTrackingIt() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selection = try await store.openSelectedFolder()
        let external = fixture.root.appendingPathComponent("invalid.txt")
        try Data([0xff, 0xfe]).write(to: external)
        do {
            _ = try await store.registerFile(external, collectionToken: selection.collectionToken)
            XCTFail("Invalid UTF-8 accepted")
        } catch {}
        let notes = await store.records
        XCTAssertTrue(notes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: external), Data([0xff, 0xfe]))
    }

    private var hooks: FolderAccessHooks {
        FolderAccessHooks(bookmark: { Data($0.path.utf8) }, resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }, start: { _ in true }, stop: { _ in })
    }

    private func setup(_ fixture: TestFixture, fault: @escaping StorageFault = { _ in }) async throws -> (NoteStore, NoteSnapshot, URL) {
        let store = try NoteStore(support: fixture.root, fault: fault, folderAccessHooks: hooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: EditRevision(rawValue: 1), baseRevision: note.fileRevision, text: "retained content")
        guard case .saved = await store.save(edit) else { throw NoteOperationError.unavailable }
        let saved = try await store.read(note.id, collectionToken: note.collectionToken)
        let destination = fixture.root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (store, saved, destination)
    }

    private func move(_ store: NoteStore, _ note: NoteSnapshot, to url: URL) async -> NoteMoveResult {
        await store.moveNote(note.id, to: url, collectionToken: note.collectionToken, locationRevision: note.locationRevision, editRevision: note.editRevision)
    }

    func testFileOnlyMovePreservesIdentityAndReconcilesAfterRestart() async throws {
        for interrupted in [false, true] {
            let fixture = try TestFixture()
            var fileHooks = hooks
            fileHooks.start = { $0.pathExtension == "txt" }
            let bookmark = fileHooks.bookmark
            fileHooks.bookmark = { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try bookmark(url)
            }
            let store = try NoteStore(support: fixture.root, fault: {
                if interrupted && $0 == .moveVerified { throw NoteOperationError.cancelled }
            }, folderAccessHooks: fileHooks)
            let selection = try await store.openSelectedFolder()
            let note = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
            let directory = fixture.root.appendingPathComponent("Destination", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("renamed.txt")
            let bytes = try Data(contentsOf: note.fileURL)
            let result = await move(store, note, to: target)
            if interrupted {
                guard case .interrupted = result.outcome else { return XCTFail("Expected interrupted move: \(result.outcome)") }
            } else {
                guard case .moved = result.outcome else { return XCTFail("Expected move: \(result.outcome)") }
            }
            let restarted = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
            let reopened = try await restarted.openSelectedFolder()
            let moved = try await restarted.read(note.id, collectionToken: reopened.collectionToken)
            XCTAssertEqual(moved.id, note.id)
            XCTAssertEqual(moved.fileURL, target)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        }
    }

    func testMovePreservesIdentityBytesTimestampAndRejectsOldSaveAcrossRestart() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        let bytes = try Data(contentsOf: note.fileURL)
        let target = directory.appendingPathComponent("Unicode 文.txt")
        let result = await move(store, note, to: target)
        guard case .moved = result.outcome else { return XCTFail("Expected move: \(result.outcome)") }
        XCTAssertEqual(result.location.id, note.id)
        XCTAssertEqual(result.location.revision.rawValue, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        let moved = try await store.read(note.id, collectionToken: note.collectionToken)
        XCTAssertEqual(moved.fileRevision, note.fileRevision)
        let stale = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: EditRevision(rawValue: 2), baseRevision: note.fileRevision, text: "stale")
        guard case .failed(.staleLocation) = await store.save(stale) else { return XCTFail("Old location accepted") }
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertEqual(selection.notes.first(where: { $0.fileURL == target })?.id, note.id)
        XCTAssertEqual(selection.notes.count, 1)
    }

    func testNoOpCollisionCaseRenameAndInvalidName() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        guard case .unchanged = await move(store, note, to: note.fileURL).outcome else { return XCTFail("No-op failed") }
        let occupied = directory.appendingPathComponent("occupied.txt")
        try Data("other".utf8).write(to: occupied)
        guard case .failed(.destinationOccupied) = await move(store, note, to: occupied).outcome else { return XCTFail("Collision not reported") }
        guard case .failed(.invalidFilename) = await move(store, note, to: directory.appendingPathComponent(".txt")).outcome else { return XCTFail("Name accepted") }
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "other")
        let target = note.fileURL.deletingLastPathComponent().appendingPathComponent(note.fileURL.lastPathComponent.uppercased())
        guard case .moved = await move(store, note, to: target).outcome else { return XCTFail("Case-only rename failed") }
        XCTAssertEqual(try Data(contentsOf: target), Data(note.text.utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains(target.lastPathComponent))
        XCTAssertFalse(names.contains(note.fileURL.lastPathComponent))
    }

    func testRestartAtEveryDurableMoveBoundary() async throws {
        for stage in [StorageStage.movePrepared, .moveAfterFilesystem, .moveVerified, .moveSourceRemoved, .moveCatalog, .moveComplete] {
            let fixture = try TestFixture()
            let (store, note, directory) = try await setup(fixture, fault: { if $0 == stage { throw NoteOperationError.inputOutput("interruption") } })
            let target = directory.appendingPathComponent("moved.txt")
            guard case .interrupted = await move(store, note, to: target).outcome else { return XCTFail("Expected interruption at \(stage)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: note.fileURL.path) || FileManager.default.fileExists(atPath: target.path))
            let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
            let selection = try await restarted.openSelectedFolder()
            XCTAssertEqual(selection.notes.count, 1, "\(stage)")
            XCTAssertEqual(selection.notes.first?.id, note.id, "\(stage)")
            XCTAssertEqual(selection.notes.first?.fileURL, target, "\(stage)")
            let operations = await restarted.unfinishedLocationOperations()
            XCTAssertTrue(operations.isEmpty, "\(stage)")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), note.text)
        }
    }

    /// Forces the cross-volume path with an intent already on disk. This covers branches
    /// and faults only. Tests on a real mounted volume are separate.
    private func prepareCopy(_ fixture: TestFixture) async throws -> (NoteSnapshot, URL, UUID) {
        let (store, note, directory) = try await setup(fixture, fault: { if $0 == .movePrepared { throw NoteOperationError.cancelled } })
        let target = directory.appendingPathComponent("copy.txt")
        let result = await move(store, note, to: target)
        guard case let .interrupted(id) = result.outcome else { throw NoteOperationError.unavailable }
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        catalog.operations[id]?.crossVolume = true
        try CatalogPersistence.save(catalog, at: catalogURL)
        return (note, target, id)
    }

    func testCopyPreservesBytesPermissionsTimestampAndCleansOnlyVerifiedSource() async throws {
        let fixture = try TestFixture()
        let (note, target, _) = try await prepareCopy(fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: note.fileURL.path)
        let attribute = Data("disposable extended metadata".utf8)
        let set = attribute.withUnsafeBytes { setxattr(note.fileURL.path, "dev.ramnotes.cp03", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(set, 0)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertEqual(selection.notes.first?.id, note.id)
        XCTAssertEqual(selection.notes.first?.fileRevision, note.fileRevision)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        var restored = Data(count: attribute.count)
        let count = restored.withUnsafeMutableBytes { getxattr(target.path, "dev.ramnotes.cp03", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(count, attribute.count)
        XCTAssertEqual(restored, attribute)
    }

    func testCopyRemovalFailureRetainsBothAndRetriesWithoutCopyingAgain() async throws {
        let fixture = try TestFixture()
        let (note, target, id) = try await prepareCopy(fixture)
        let restarted = try NoteStore(support: fixture.root, fault: { if $0 == .moveSourceRemoval { throw NoteOperationError.permissionDenied } }, folderAccessHooks: hooks)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertFalse(selection.recoveryDiagnostics.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let destinationIdentity = try StorageFiles.fileResourceID(target)
        let retried = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        _ = try await retried.openSelectedFolder()
        XCTAssertEqual(try StorageFiles.fileResourceID(target), destinationIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
        let catalog = try CatalogPersistence.load(at: fixture.root.appendingPathComponent("collection.json"))
        XCTAssertEqual(catalog.operations[id]?.stage, .complete)
    }

    func testExternalSourceEditAfterCopyIsNeverRemoved() async throws {
        let fixture = try TestFixture()
        let (note, target, _) = try await prepareCopy(fixture)
        let restarted = try NoteStore(support: fixture.root, fault: { stage in
            if stage == .moveSourceRemoval { try Data("external change".utf8).write(to: note.fileURL) }
        }, folderAccessHooks: hooks)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertFalse(selection.recoveryDiagnostics.isEmpty)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "external change")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), note.text)
    }

    func testCancellationAfterIntentBeforeFilesystemDoesNotResumeCancelledMove() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture, fault: { if $0 == .movePrepared { throw CancellationError() } })
        let target = directory.appendingPathComponent("cancelled.txt")
        guard case .failed(.cancelled) = await move(store, note, to: target).outcome else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await restarted.openSelectedFolder()
        XCTAssertEqual(selected.notes.first?.fileURL, note.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRenameGapReconciliationProtectsReplacementAtFormerPath() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture, fault: { if $0 == .moveAfterFilesystem { throw NoteOperationError.cancelled } })
        let target = directory.appendingPathComponent("moved.txt")
        guard case .interrupted = await move(store, note, to: target).outcome else { return XCTFail("Expected gap interruption") }
        try Data("replacement at former path".utf8).write(to: note.fileURL)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await restarted.openSelectedFolder()
        XCTAssertEqual(selected.notes.first(where: { $0.fileURL == target })?.id, note.id)
        XCTAssertNotEqual(selected.notes.first(where: { $0.fileURL == note.fileURL })?.id, note.id)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "replacement at former path")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), note.text)
    }

    func testEditsDuringInterruptedCustomMoveRemainJournaledAndFollowRestart() async throws {
        let fixture = try TestFixture()
        let armed = Mutex(false)
        let (store, initial, directory) = try await setup(fixture, fault: { if $0 == .movePrepared && armed.withLock({ $0 }) { throw NoteOperationError.cancelled } })
        let custom = directory.appendingPathComponent("custom-source.txt")
        guard case .moved = await move(store, initial, to: custom).outcome else { return XCTFail("Initial move failed") }
        let note = try await store.read(initial.id, collectionToken: initial.collectionToken)
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = other.appendingPathComponent("new-location.txt")
        armed.withLock { $0 = true }
        guard case .interrupted = await move(store, note, to: target).outcome else { return XCTFail("Expected interruption") }
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: EditRevision(rawValue: 2), baseRevision: note.fileRevision,
            text: "typed while cleanup pending", locationRevision: note.locationRevision)
        guard case .failed(.locationOperationPending) = await store.save(edit) else { return XCTFail("Operation guard missing") }
        let durable = await store.retainedRecovery()
        XCTAssertEqual(durable.edits.first?.text, edit.text)
        let canDispose = await store.canDispose(note.id)
        XCTAssertFalse(canDispose)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await restarted.openSelectedFolder()
        XCTAssertEqual(selected.notes.first?.id, note.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), edit.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
    }

    func testCustomMoveIntoDefaultDeduplicatesAfterRestart() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        let custom = directory.appendingPathComponent("outside.txt")
        guard case .moved = await move(store, note, to: custom).outcome else { return XCTFail("Move failed") }
        let outside = try await store.read(note.id, collectionToken: note.collectionToken)
        let target = note.fileURL.deletingLastPathComponent().appendingPathComponent("returned.txt")
        guard case .moved = await move(store, outside, to: target).outcome else { return XCTFail("Return move failed") }
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await restarted.openSelectedFolder()
        XCTAssertEqual(selected.notes.count, 1)
        XCTAssertEqual(selected.notes.first?.id, note.id)
        XCTAssertEqual(selected.notes.first?.locationRevision.rawValue, 2)
    }

    func testDestinationEditBeforeCleanupKeepsVerifiedOriginal() async throws {
        let fixture = try TestFixture()
        let (note, target, _) = try await prepareCopy(fixture)
        let restarted = try NoteStore(support: fixture.root, fault: { stage in
            if stage == .moveSourceRemoval { try Data("external destination edit".utf8).write(to: target) }
        }, folderAccessHooks: hooks)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertFalse(selection.recoveryDiagnostics.isEmpty)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), note.text)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external destination edit")
    }

    func testMoveRetainsGlobalWindowAppearanceAndRecoveryAssociations() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        let metadata = MetadataStore(root: fixture.root)
        var state = NoteWindowMetadata(isOpen: true, frame: CGRect(x: 12, y: 34, width: 456, height: 567), displayID: 99,
            focusOrder: 7, fileResourceID: nil, lastKnownPath: note.fileURL.path, fontSize: 28)
        state.backgroundTone = .purple
        try await metadata.saveCollection(CollectionMetadata(notes: [note.id: state]))
        guard case .moved = await move(store, note, to: directory.appendingPathComponent("metadata.txt")).outcome else { return XCTFail("Move failed") }
        let reloaded = MetadataStore(root: fixture.root)
        let collection = await reloaded.loadCollection()
        XCTAssertEqual(collection.value.notes[note.id], state)
    }

    func testCopyRestartAtRemovalAndCatalogBoundaries() async throws {
        for stage in [StorageStage.moveAfterSourceRemoval, .moveSourceRemoved, .moveCatalog, .moveComplete] {
            let fixture = try TestFixture()
            let (note, target, _) = try await prepareCopy(fixture)
            let interrupted = try NoteStore(support: fixture.root, fault: { if $0 == stage { throw NoteOperationError.cancelled } }, folderAccessHooks: hooks)
            let first = try await interrupted.openSelectedFolder()
            XCTAssertFalse(first.recoveryDiagnostics.isEmpty, "\(stage)")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), note.text)
            let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
            let final = try await restarted.openSelectedFolder()
            XCTAssertEqual(final.notes.first?.id, note.id, "\(stage)")
            XCTAssertEqual(final.notes.count, 1, "\(stage)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: note.fileURL.path))
            XCTAssertEqual(final.notes.first?.fileRevision, note.fileRevision)
        }
    }

    func testUncheckpointedCopyNeverDeletesEitherFileBasedOnText() async throws {
        let fixture = try TestFixture()
        let (note, target, _) = try await prepareCopy(fixture)
        try StorageFiles.copyExclusive(note.fileURL, to: target)
        let copiedIdentity = try StorageFiles.fileResourceID(target)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertFalse(selection.recoveryDiagnostics.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.fileURL.path))
        XCTAssertEqual(try StorageFiles.fileResourceID(target), copiedIdentity)
        let unfinished = await restarted.unfinishedLocationOperations()
        XCTAssertEqual(unfinished.count, 1)
    }

    func testDestinationCreationRaceReturnsExactCollisionAndAllowsNewDecision() async throws {
        let fixture = try TestFixture()
        let target = fixture.root.appendingPathComponent("Destination/race.txt")
        let (store, note, _) = try await setup(fixture, fault: { if $0 == .moveFilesystem { try Data("other".utf8).write(to: target) } })
        let result = await move(store, note, to: target)
        guard case .failed(.destinationOccupied) = result.outcome else { return XCTFail("Expected exact collision: \(result.outcome)") }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "other")
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), note.text)
        let unfinished = await store.unfinishedLocationOperations()
        XCTAssertTrue(unfinished.isEmpty)
    }

    func testRenameRefreshesFilenameSearchWithoutChangingModificationOrder() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        let index = SearchIndex()
        let old = await index.search(notes: [note], query: note.fileURL.lastPathComponent)
        XCTAssertEqual(old.count, 1)
        let target = directory.appendingPathComponent("new-search-name.txt")
        guard case .moved = await move(store, note, to: target).outcome else { return XCTFail("Move failed") }
        let moved = try await store.read(note.id, collectionToken: note.collectionToken)
        let oldMatches = await index.search(notes: [moved], query: note.fileURL.lastPathComponent)
        let newMatches = await index.search(notes: [moved], query: "new-search-name")
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches.first?.note.id, note.id)
        XCTAssertEqual(moved.fileRevision?.modifiedAt, note.fileRevision?.modifiedAt)
    }

    func testRelinkToDifferentResourceKeepsPendingEditRecoverableWithoutOverwritingTarget() async throws {
        let fixture = try TestFixture()
        let (store, _, directory) = try await setup(fixture)
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let parent = try await store.folderAccess.acquire(directory)
        let note = try await store.registerCustomFile(source, parent: parent)
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "retained draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        try FileManager.default.removeItem(at: source)
        let target = directory.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: target.path)
        let linked = try await store.relinkNote(note.id, file: try await store.acquireFile(target),
            collectionToken: note.collectionToken, locationRevision: note.locationRevision)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(linked.id, note.id)
        XCTAssertNotEqual(linked.createdAt, note.createdAt)
        XCTAssertEqual(linked.createdAt, Date(timeIntervalSince1970: 2000))
        let laterEdit = EditSnapshot(id: linked.id, collectionToken: linked.collectionToken,
            revision: EditRevision(rawValue: 2), baseRevision: linked.fileRevision,
            text: "new target edit", locationRevision: linked.locationRevision)
        guard case .saved = await store.save(laterEdit) else { return XCTFail("New target edit did not save") }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new target edit")
        let recovery = await store.retainedRecovery()
        XCTAssertTrue(recovery.edits.contains { $0.noteID == note.id && $0.text == "retained draft" })
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        _ = try await restarted.openSelectedFolder()
        let afterRestart = await restarted.retainedRecovery()
        XCTAssertTrue(afterRestart.edits.contains { $0.noteID == note.id && $0.text == "retained draft" })
    }

    func testRelinkToSameResourceRenewsLocationAndPreservesNoteIdentity() async throws {
        let fixture = try TestFixture()
        let original = fixture.root.appendingPathComponent("same-resource.txt")
        try Data("original".utf8).write(to: original)
        var fileHooks = hooks
        fileHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.registerFile(original, collectionToken: selection.collectionToken)
        let relocated = fixture.root.appendingPathComponent("same-resource-moved.txt")
        try FileManager.default.moveItem(at: original, to: relocated)

        let renewed = try await store.relinkNote(note.id, file: try await store.acquireFile(relocated),
            collectionToken: note.collectionToken, locationRevision: note.locationRevision)

        XCTAssertEqual(renewed.id, note.id)
        XCTAssertEqual(renewed.fileURL, relocated)
        XCTAssertGreaterThan(renewed.locationRevision.rawValue, note.locationRevision.rawValue)
        XCTAssertEqual(renewed.text, "original")
        XCTAssertEqual(try String(contentsOf: relocated, encoding: .utf8), "original")
    }

    func testRelinkConflictPromotesOnceAndRejectsStaleEdit() async throws {
        let fixture = try TestFixture()
        let (store, _, directory) = try await setup(fixture)
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let parent = try await store.folderAccess.acquire(directory)
        let note = try await store.registerCustomFile(source, parent: parent)
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "retained draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        try FileManager.default.removeItem(at: source)
        let target = directory.appendingPathComponent("target.txt")
        try Data("unrelated".utf8).write(to: target)
        let linked = try await store.relinkNote(note.id, file: try await store.acquireFile(target),
            collectionToken: note.collectionToken, locationRevision: note.locationRevision)
        guard case .failed(.staleLocation) = await store.save(edit) else { return XCTFail("Old location accepted") }
        let editorEdit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: edit.revision,
            baseRevision: edit.baseRevision, text: edit.text, locationRevision: linked.locationRevision)
        _ = await store.submit(editorEdit)
        try await waitUntil { !(await store.hasPendingEdits()) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unrelated")
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let restored = try await restarted.openSelectedFolder()
        XCTAssertEqual(restored.notes.filter { $0.text == "retained draft" }.count, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unrelated")
    }

    func testRelinkToDifferentResourceDoesNotReplayOldBufferOverTargetAfterRestart() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, timing: StoreTiming(saveDebounce: .seconds(3600)), folderAccessHooks: hooks)
        _ = try await store.openSelectedFolder()
        let directory = fixture.root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let parent = try await store.folderAccess.acquire(directory)
        let note = try await store.registerCustomFile(source, parent: parent)
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "retained draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        try FileManager.default.removeItem(at: source)
        let target = directory.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        _ = try await store.relinkNote(note.id, file: try await store.acquireFile(target),
            collectionToken: note.collectionToken, locationRevision: note.locationRevision)
        let journal = try XCTUnwrap(RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load().records.first)
        XCTAssertEqual(journal.originalURL, source)
        XCTAssertEqual(journal.baseRevision, edit.baseRevision)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let restored = try await restarted.openSelectedFolder()
        XCTAssertEqual(restored.notes.first { $0.id == note.id }?.text, "original")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        let retained = await restarted.retainedRecovery()
        XCTAssertTrue(retained.edits.contains { $0.noteID == note.id && $0.text == "retained draft" })
    }

    func testRelinkDoesNotAutomaticallySaveExportedBuffer() async throws {
        let fixture = try TestFixture()
        let (store, _, directory) = try await setup(fixture)
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let parent = try await store.folderAccess.acquire(directory)
        let note = try await store.registerCustomFile(source, parent: parent)
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "exported draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        try await store.export(note.id, to: fixture.root.appendingPathComponent("export.txt"))
        try FileManager.default.removeItem(at: source)
        let target = directory.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        _ = try await store.relinkNote(note.id, file: try await store.acquireFile(target),
            collectionToken: note.collectionToken, locationRevision: note.locationRevision)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        let pending = await store.hasPendingEdits()
        XCTAssertFalse(pending)
        let retained = await store.retainedBuffer(note.id)
        XCTAssertEqual(retained?.text, "exported draft")
    }

    func testRelinkRejectsDuplicateAndRemovalForgetsNoteCompletely() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        let customURL = directory.appendingPathComponent("custom.txt")
        try Data("custom".utf8).write(to: customURL)
        let parent = try await store.folderAccess.acquire(directory)
        let custom = try await store.registerCustomFile(customURL, parent: parent)
        try FileManager.default.removeItem(at: customURL)
        _ = try await store.read(custom.id, collectionToken: custom.collectionToken)
        do {
            _ = try await store.relinkNote(custom.id, file: try await store.acquireFile(note.fileURL), collectionToken: custom.collectionToken, locationRevision: custom.locationRevision)
            XCTFail("Duplicate accepted")
        } catch {}
        let replacement = directory.appendingPathComponent("located.txt")
        try Data("located".utf8).write(to: replacement)
        let linked = try await store.relinkNote(custom.id, file: try await store.acquireFile(replacement), collectionToken: custom.collectionToken, locationRevision: custom.locationRevision)
        XCTAssertEqual(linked.id, custom.id)
        let edit = EditSnapshot(id: linked.id, collectionToken: linked.collectionToken, revision: EditRevision(rawValue: 1), baseRevision: linked.fileRevision, text: "unsaved", locationRevision: linked.locationRevision)
        _ = await store.submit(edit)
        try FileManager.default.removeItem(at: replacement)
        _ = try await store.read(linked.id, collectionToken: linked.collectionToken)
        try await store.removeUnavailableNote(linked.id, collectionToken: linked.collectionToken, locationRevision: linked.locationRevision)
        let recovery = await store.retainedRecovery()
        XCTAssertFalse(recovery.edits.contains { $0.noteID == linked.id })
        let buffer = await store.retainedBuffer(linked.id)
        XCTAssertNil(buffer)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertFalse(reopened.notes.contains { $0.id == linked.id })
        let retained = await restarted.retainedRecovery()
        XCTAssertFalse(retained.edits.contains { $0.noteID == linked.id })
        let catalog = try CatalogPersistence.load(at: fixture.root.appendingPathComponent("collection.json"))
        XCTAssertNil(catalog.notes[linked.id])
        XCTAssertFalse(catalog.operations.values.contains { $0.noteID == linked.id })
    }

    func testRemovalRejectsFileReturnedBeforeCommit() async throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("returned.txt")
        try Data("original".utf8).write(to: url)
        var fileHooks = hooks
        fileHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.registerFile(url, collectionToken: selection.collectionToken)

        try FileManager.default.removeItem(at: url)
        _ = try await store.read(note.id, collectionToken: note.collectionToken)
        try Data("returned original".utf8).write(to: url)

        do {
            try await store.removeUnavailableNote(note.id, collectionToken: note.collectionToken,
                locationRevision: note.locationRevision)
            XCTFail("A file that returned before removal was committed was untracked")
        } catch { XCTAssertEqual(error as? NoteOperationError, .originalNotMissing) }
        let records = await store.records
        XCTAssertNotNil(records[note.id])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "returned original")
    }

    func testRemovalForgetsUnreadableFileWithoutTouchingIt() async throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("unsupported.txt")
        try Data("initial text".utf8).write(to: url)
        var fileHooks = hooks
        fileHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.registerFile(url, collectionToken: selection.collectionToken)
        try Data([0xff, 0xfe]).write(to: url)
        _ = try await store.read(note.id, collectionToken: note.collectionToken)

        try await store.removeUnavailableNote(note.id, collectionToken: note.collectionToken,
            locationRevision: note.locationRevision)
        let records = await store.records
        XCTAssertNil(records[note.id])
        XCTAssertEqual(try Data(contentsOf: url), Data([0xff, 0xfe]))
    }
}

final class DefaultFolderChangeTests: XCTestCase {
    private var hooks: FolderAccessHooks {
        FolderAccessHooks(bookmark: { Data($0.path.utf8) }, resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }, start: { _ in true }, stop: { _ in })
    }
    private func directory(_ name: String, _ fixture: TestFixture) throws -> URL {
        let url = fixture.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func start(_ fixture: TestFixture, fault: @escaping StorageFault = { _ in }) async throws -> (NoteStore, FolderSelection, NoteSnapshot) {
        let store = try NoteStore(support: fixture.root, fault: fault, folderAccessHooks: hooks)
        let root = await store.defaultFolder()
        try Data("old default".utf8).write(to: root.appendingPathComponent("Note.txt"))
        let selection = try await store.openSelectedFolder()
        return (store, selection, try XCTUnwrap(selection.notes.first))
    }

    func testUncheckedRetainsOldAndCustomNotesAndStopsOldSiblingDiscoveryAcrossRestart() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture)
        let customRoot = try directory("Custom", fixture)
        let customURL = customRoot.appendingPathComponent("custom.txt")
        try Data("custom".utf8).write(to: customURL)
        let access = FolderAccess(support: fixture.root, hooks: hooks)
        let custom = try await store.registerCustomFile(customURL, parent: access.acquire(customRoot))
        let destination = try directory("Destination", fixture)
        try Data("destination".utf8).write(to: destination.appendingPathComponent("external.TXT"))
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: false, from: selection.collectionToken)
        XCTAssertEqual(result.collectionToken, selection.collectionToken)
        XCTAssertEqual(result.batch?.entries.count, 0)
        let notes = await store.records
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes[old.id]?.fileURL, old.fileURL)
        XCTAssertEqual(notes[custom.id]?.fileURL, customURL)
        try Data("late sibling".utf8).write(to: old.fileURL.deletingLastPathComponent().appendingPathComponent("late.txt"))
        try await store.reconcile(collectionToken: selection.collectionToken)
        let live = await store.records
        XCTAssertEqual(live.count, 3)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let restored = try await restarted.openSelectedFolder()
        XCTAssertEqual(Set(restored.notes.map(\.id)), Set(live.keys))
        XCTAssertEqual(restored.url, destination)
    }

    func testLateCollisionUsesNextCandidateAndPreservesExtensionCase() async throws {
        let fixture = try TestFixture()
        let destination = try directory("Destination", fixture)
        let store = try NoteStore(support: fixture.root, fault: { stage in
            if stage == .defaultCommitted {
                try Data("late arrival".utf8).write(to: destination.appendingPathComponent("Note.TXT"))
            }
        }, folderAccessHooks: hooks)
        let root = await store.defaultFolder()
        try Data("source".utf8).write(to: root.appendingPathComponent("Note.TXT"))
        try Data("existing".utf8).write(to: destination.appendingPathComponent("Note (2).TXT"))
        let selection = try await store.openSelectedFolder()
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        let entry = try XCTUnwrap(result.batch?.entries.first)
        XCTAssertEqual(entry.state, .moved)
        XCTAssertEqual(entry.destination.lastPathComponent, "Note (3).TXT")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note.TXT"), encoding: .utf8), "late arrival")
        XCTAssertEqual(try String(contentsOf: entry.destination, encoding: .utf8), "source")
    }

    func testCheckedMovesOnlyCapturedMembersWithDeterministicCollisionNames() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture)
        let destination = try directory("Destination", fixture)
        try Data("occupied".utf8).write(to: destination.appendingPathComponent("note.TXT"))
        try Data("occupied two".utf8).write(to: destination.appendingPathComponent("Note (2).txt"))
        let customRoot = try directory("Custom", fixture)
        let customURL = customRoot.appendingPathComponent("custom.txt")
        try Data("custom".utf8).write(to: customURL)
        let custom = try await store.registerCustomFile(customURL, parent: FolderAccess(support: fixture.root, hooks: hooks).acquire(customRoot))
        let prepared = try await store.prepareDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        let late = old.fileURL.deletingLastPathComponent().appendingPathComponent("Late.txt")
        try Data("new arrival".utf8).write(to: late)
        let result = try await store.commitDefaultFolder(prepared)
        let entry = try XCTUnwrap(result.batch?.entries.first)
        XCTAssertEqual(entry.state, .moved)
        XCTAssertEqual(entry.destination.lastPathComponent, "Note (3).txt")
        let moved = try await store.read(old.id, collectionToken: old.collectionToken)
        XCTAssertEqual(moved.fileRevision, old.fileRevision)
        XCTAssertEqual(moved.fileURL, entry.destination)
        XCTAssertEqual(result.batch?.entries.count, 1)
        let customAfter = await store.records[custom.id]
        XCTAssertEqual(customAfter?.fileURL, customURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: late.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("note.TXT"), encoding: .utf8), "occupied")
        let again = try await store.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: old.collectionToken)
        XCTAssertEqual(again.batch, result.batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Note (4).txt").path))
    }

    func testPreparationFailureAndSameDirectoryAreNonmutating() async throws {
        let fixture = try TestFixture()
        let (store, selection, _) = try await start(fixture)
        let before = try Data(contentsOf: fixture.root.appendingPathComponent("collection.json"))
        let result = try await store.changeDefaultFolder(to: selection.url.appendingPathComponent("."), moveExisting: true, from: selection.collectionToken)
        XCTAssertTrue(result.unchanged)
        do {
            _ = try await store.changeDefaultFolder(to: fixture.root.appendingPathComponent("Missing"), moveExisting: true, from: selection.collectionToken)
            XCTFail("Missing destination accepted")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("collection.json")), before)
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, selection.url)
    }

    func testPartialFailureRetainsNewDefaultAndRetryNeverRepeatsSuccess() async throws {
        let fixture = try TestFixture()
        let gate = Mutex(0)
        let (store, selection, old) = try await start(fixture, fault: { stage in
            if stage == .defaultEntry {
                let fail = gate.withLock { value in value += 1; return value == 1 }
                if fail { throw NoteOperationError.permissionDenied }
            }
        })
        let peer = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
        let destination = try directory("Destination", fixture)
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        let batch = try XCTUnwrap(result.batch)
        XCTAssertEqual(batch.entries.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(batch.entries.filter { $0.state == .moved }.count, 1)
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, destination)
        let success = try XCTUnwrap(batch.entries.first { $0.state == .moved })
        let successfulBytes = try Data(contentsOf: success.destination)
        let successfulResource = try StorageFiles.fileResourceID(success.destination)
        let retry = try await store.retryDefaultFolderChange(batch.id, from: selection.collectionToken)
        XCTAssertTrue(retry.batch?.entries.allSatisfy { $0.state == .moved } == true)
        XCTAssertEqual(try StorageFiles.fileResourceID(success.destination), successfulResource)
        XCTAssertEqual(try Data(contentsOf: success.destination), successfulBytes)
        let records = await store.records
        XCTAssertEqual(Set(records.keys), [old.id, peer.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
    }

    func testRestartResumesPendingBatchAtEveryDurableBoundary() async throws {
        for boundary in [StorageStage.defaultCommitted, .defaultAfterMove, .defaultCheckpoint, .defaultComplete] {
            let fixture = try TestFixture()
            let (store, selection, old) = try await start(fixture, fault: { if $0 == boundary { throw NoteOperationError.inputOutput("interrupted") } })
            let peer = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
            let destination = try directory("Destination", fixture)
            let interrupted = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
            XCTAssertNotNil(interrupted.error, "\(boundary)")
            XCTAssertEqual(interrupted.folder, destination)
            let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
            let restored = try await restarted.openSelectedFolder()
            XCTAssertEqual(Set(restored.notes.map(\.id)), [old.id, peer.id], "\(boundary)")
            XCTAssertTrue(restored.notes.allSatisfy { $0.fileURL.deletingLastPathComponent() == destination }, "\(boundary)")
            let batches = await restarted.defaultFolderBatches()
            XCTAssertTrue(batches.allSatisfy { $0.state == .settled }, "\(boundary)")
        }
    }

    func testSecondDecisionRejectsObsoleteRetryAndPreparation() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture, fault: { if $0 == .defaultEntry { throw NoteOperationError.permissionDenied } })
        let destination = try directory("Destination", fixture)
        let another = try directory("Another", fixture)
        let stale = try await store.prepareDefaultFolder(to: another, moveExisting: true, from: selection.collectionToken)
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        do { _ = try await store.commitDefaultFolder(stale); XCTFail("Stale preparation accepted") } catch { }
        _ = try await store.changeDefaultFolder(to: another, moveExisting: false, from: selection.collectionToken)
        do { _ = try await store.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: selection.collectionToken); XCTFail("Obsolete destination accepted") } catch { }
        let note = await store.records[old.id]
        XCTAssertEqual(note?.fileURL, old.fileURL)
    }

    func testCapturedNoteMovedElsewhereCannotBeMovedByBatch() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture)
        let destination = try directory("Destination", fixture)
        let elsewhere = try directory("Elsewhere", fixture).appendingPathComponent("custom.txt")
        let prepared = try await store.prepareDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        guard case .moved = await store.moveNote(old.id, to: elsewhere, collectionToken: old.collectionToken, locationRevision: old.locationRevision, editRevision: old.editRevision).outcome else { return XCTFail("Move failed") }
        do { _ = try await store.commitDefaultFolder(prepared); XCTFail("Changed membership accepted") } catch { }
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, selection.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}

extension DefaultFolderChangeTests {
    func testSaveAndCatalogCommitFailuresLeaveOldDefaultAndFilesUntouched() async throws {
        for stage in [StorageStage.destination, .defaultCommit] {
            let fixture = try TestFixture()
            let gate = Mutex(false)
            let (store, selection, old) = try await start(fixture, fault: { if $0 == stage && gate.withLock({ $0 }) { throw NoteOperationError.permissionDenied } })
            let destination = try directory("Destination", fixture)
            let prepared = try await store.prepareDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
            if stage == .destination {
                _ = await store.submit(EditSnapshot(id: old.id, collectionToken: old.collectionToken, revision: EditRevision(rawValue: 1), baseRevision: old.fileRevision, text: "dirty"))
            }
            let before = try Data(contentsOf: fixture.root.appendingPathComponent("collection.json"))
            gate.withLock { $0 = true }
            do { _ = try await store.commitDefaultFolder(prepared); XCTFail("Barrier failure committed \(stage)") } catch { }
            let current = await store.currentFolder()
            XCTAssertEqual(current.url, selection.url)
            XCTAssertEqual(current.collectionToken, selection.collectionToken)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.fileURL.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("collection.json")), before)
        }
    }

    func testCancellationBeforeCommitAndBetweenFilesIsDurableAndExplicitlyRetryable() async throws {
        for boundary in [StorageStage.defaultPrepared, .defaultCommitted, .defaultCheckpoint] {
            let fixture = try TestFixture()
            let (store, selection, old) = try await start(fixture, fault: { if $0 == boundary { withUnsafeCurrentTask { $0?.cancel() } } })
            let peer = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
            let destination = try directory("Destination", fixture)
            let task = Task { try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken) }
            if boundary == .defaultPrepared {
                do { _ = try await task.value; XCTFail("Cancelled preparation committed") } catch is CancellationError { }
                let current = await store.currentFolder()
                XCTAssertEqual(current.url, selection.url)
            } else {
                let result = try await task.value
                XCTAssertEqual(result.batch?.state, .paused)
                let movedCount = result.batch?.entries.filter { $0.state == .moved }.count
                XCTAssertEqual(movedCount, boundary == .defaultCommitted ? 0 : 1)
                let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
                let restored = try await restarted.openSelectedFolder()
                XCTAssertEqual(Set(restored.notes.map(\.id)), [old.id, peer.id])
                let batches = await restarted.defaultFolderBatches()
                XCTAssertEqual(batches.first?.state, .paused)
                XCTAssertEqual(batches.first?.entries.filter { $0.state == .moved }.count, movedCount)
                let retry = try await restarted.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: restored.collectionToken)
                XCTAssertTrue(retry.batch?.entries.allSatisfy { $0.state == .moved } == true)
            }
        }
    }

    func testInterruptedSingleMoveInsideBatchIsResolvedWithoutDuplicateOnRetry() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture, fault: { if $0 == .moveAfterFilesystem { throw NoteOperationError.inputOutput("interrupted after rename") } })
        let destination = try directory("Destination", fixture)
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        XCTAssertEqual(result.batch?.entries.first?.state, .failed)
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let restored = try await restarted.openSelectedFolder()
        XCTAssertEqual(restored.notes.first?.id, old.id)
        XCTAssertEqual(restored.notes.first?.fileURL, destination.appendingPathComponent("Note.txt"))
        let retried = try await restarted.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: restored.collectionToken)
        XCTAssertEqual(retried.batch?.entries.first?.state, .moved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Note.txt"])
    }

    func testRetryRevalidatesBindingAfterAnOrdinaryAtomicSave() async throws {
        let fixture = try TestFixture()
        let once = Mutex(true)
        let (store, selection, old) = try await start(fixture, fault: { if $0 == .defaultEntry && once.withLock({ value in let prior = value; value = false; return prior }) { throw NoteOperationError.permissionDenied } })
        let destination = try directory("Destination", fixture)
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        let edit = EditSnapshot(id: old.id, collectionToken: old.collectionToken, revision: EditRevision(rawValue: 1), baseRevision: old.fileRevision, text: "newer edit")
        guard case .saved = await store.save(edit) else { return XCTFail("Custom note save failed") }
        let retry = try await store.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: old.collectionToken)
        XCTAssertEqual(retry.batch?.entries.first?.state, .moved)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note.txt"), encoding: .utf8), "newer edit")
    }
}

extension DefaultFolderChangeTests {
    func testRetryFinishesInterruptedMoveBeforeSavingNewerJournaledText() async throws {
        let fixture = try TestFixture()
        let gate = Mutex(true)
        let (store, selection, old) = try await start(fixture, fault: { if $0 == .moveAfterFilesystem && gate.withLock({ $0 }) { throw NoteOperationError.permissionDenied } })
        let destination = try directory("Destination", fixture)
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: old.collectionToken)
        _ = await store.submit(EditSnapshot(id: old.id, collectionToken: old.collectionToken, revision: EditRevision(rawValue: 1), baseRevision: old.fileRevision, text: "newer journaled text"))
        gate.withLock { $0 = false }
        let retry = try await store.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: selection.collectionToken)
        XCTAssertEqual(retry.batch?.entries.first?.state, .moved)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note.txt"), encoding: .utf8), "newer journaled text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL.path))
        let disposable = await store.canDispose(old.id)
        XCTAssertTrue(disposable)
    }

    func testBatchCollisionRaceRetainsOccupantAndChoosesNewSuffixOnRetry() async throws {
        let fixture = try TestFixture()
        let destination = try directory("Destination", fixture)
        let once = Mutex(true)
        let (store, selection, old) = try await start(fixture, fault: { if $0 == .moveFilesystem && once.withLock({ value in let prior = value; value = false; return prior }) {
            try Data("race occupant".utf8).write(to: destination.appendingPathComponent("Note.txt"))
        } })
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        XCTAssertEqual(result.batch?.entries.first?.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.fileURL.path))
        let retry = try await store.retryDefaultFolderChange(try XCTUnwrap(result.batch?.id), from: selection.collectionToken)
        XCTAssertEqual(retry.batch?.entries.first?.destination.lastPathComponent, "Note (2).txt")
        XCTAssertEqual(retry.batch?.entries.first?.state, .moved)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note.txt"), encoding: .utf8), "race occupant")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note (2).txt"), encoding: .utf8), old.text)
    }

    func testHardLinkInDestinationCannotStealCapturedIdentity() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture)
        let destination = try directory("Destination", fixture)
        let target = destination.appendingPathComponent("linked.txt")
        try FileManager.default.linkItem(at: old.fileURL, to: target)
        do { _ = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken); XCTFail("Ambiguous hard link accepted") } catch { }
        let current = await store.currentFolder()
        XCTAssertEqual(current.url, selection.url)
        XCTAssertEqual(try Data(contentsOf: target), Data(old.text.utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.fileURL.path))
    }
}

extension DefaultFolderChangeTests {
    func testRestartAfterMoveBeforeBatchCheckpointKeepsNewerSavedReplacement() async throws {
        let fixture = try TestFixture()
        let (store, selection, old) = try await start(fixture, fault: { if $0 == .defaultAfterMove { throw NoteOperationError.inputOutput("batch checkpoint interrupted") } })
        let destination = try directory("Destination", fixture)
        _ = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: selection.collectionToken)
        let moved = try await store.read(old.id, collectionToken: old.collectionToken)
        guard case .saved = await store.save(EditSnapshot(id: moved.id, collectionToken: moved.collectionToken,
            revision: EditRevision(rawValue: 1), baseRevision: moved.fileRevision, text: "saved after interrupted checkpoint", locationRevision: moved.locationRevision)) else { return XCTFail("Save failed") }
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let restored = try await restarted.openSelectedFolder()
        XCTAssertEqual(restored.notes.count, 1)
        XCTAssertEqual(restored.notes.first?.id, old.id)
        XCTAssertEqual(restored.notes.first?.text, "saved after interrupted checkpoint")
        let batches = await restarted.defaultFolderBatches()
        XCTAssertEqual(batches.first?.entries.first?.state, .moved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Note.txt"])
    }
}

extension DefaultFolderChangeTests {
    func testExternalCustomMoveReplaysJournalAfterRestartBeforeAutosave() async throws {
        let fixture = try TestFixture()
        let resolutions = Mutex<[String: String]>([:])
        var followingHooks = hooks
        followingHooks.resolve = { data in
            let path = String(decoding: data, as: UTF8.self)
            return (URL(fileURLWithPath: resolutions.withLock { $0[path] ?? path }), false)
        }
        let store = try NoteStore(support: fixture.root, timing: StoreTiming(saveDebounce: .seconds(3600)), folderAccessHooks: followingHooks)
        let selection = try await store.openSelectedFolder()
        let a = try directory("A", fixture)
        let b = try directory("B", fixture)
        let source = a.appendingPathComponent("note.txt")
        let target = b.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: source)
        let note = try await store.registerCustomFile(source, parent: FolderAccess(support: fixture.root, hooks: followingHooks).acquire(a))
        let edit = EditSnapshot(id: note.id, collectionToken: selection.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "retained draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        try FileManager.default.moveItem(at: source, to: target)
        resolutions.withLock { $0[source.path] = target.path }
        try await store.reconcile(collectionToken: selection.collectionToken)
        let journal = try XCTUnwrap(RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load().records.first)
        XCTAssertEqual(journal.originalURL, target)
        XCTAssertEqual(journal.folderIdentity, try StorageFiles.resourceID(b))
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: followingHooks)
        let restored = try await restarted.openSelectedFolder()
        let recovered = try XCTUnwrap(restored.notes.first { $0.id == note.id })
        XCTAssertEqual(recovered.fileURL, target)
        XCTAssertEqual(recovered.text, "retained draft")
    }

    func testSaveTimeCustomMoveCheckpointsJournalBeforeReplacement() async throws {
        let fixture = try TestFixture()
        let resolutions = Mutex<[String: String]>([:])
        var followingHooks = hooks
        followingHooks.resolve = { data in
            let path = String(decoding: data, as: UTF8.self)
            return (URL(fileURLWithPath: resolutions.withLock { $0[path] ?? path }), false)
        }
        let store = try NoteStore(support: fixture.root, timing: StoreTiming(saveDebounce: .seconds(3600)),
            fault: { if $0 == .destination { throw NoteOperationError.permissionDenied } }, folderAccessHooks: followingHooks)
        let selection = try await store.openSelectedFolder()
        let a = try directory("A", fixture)
        let b = try directory("B", fixture)
        let source = a.appendingPathComponent("note.txt")
        let target = b.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: source)
        let note = try await store.registerCustomFile(source, parent: FolderAccess(support: fixture.root, hooks: followingHooks).acquire(a))
        let edit = EditSnapshot(id: note.id, collectionToken: selection.collectionToken, revision: .init(rawValue: 1),
            baseRevision: note.fileRevision, text: "save-time draft", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        try FileManager.default.moveItem(at: source, to: target)
        resolutions.withLock { $0[source.path] = target.path }
        guard case .failed(.permissionDenied) = await store.save(edit) else { return XCTFail("Expected replacement failure") }
        let journal = try XCTUnwrap(RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in }).load().records.first)
        XCTAssertEqual(journal.originalURL, target)
        XCTAssertEqual(journal.folderIdentity, try StorageFiles.resourceID(b))
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: followingHooks)
        let restored = try await restarted.openSelectedFolder()
        let recovered = try XCTUnwrap(restored.notes.first { $0.id == note.id })
        XCTAssertEqual(recovered.fileURL, target)
        XCTAssertEqual(recovered.text, "save-time draft")
    }

    func testNewDestinationDiscoveryPersistsLocatorBeforeFollowingFileOutsideDefault() async throws {
        let fixture = try TestFixture()
        let resolutions = Mutex<[String: String]>([:])
        var followingHooks = hooks
        followingHooks.resolve = { data in
            let path = String(decoding: data, as: UTF8.self)
            return (URL(fileURLWithPath: resolutions.withLock { $0[path] ?? path }), false)
        }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: followingHooks)
        let selection = try await store.openSelectedFolder()
        let destination = try directory("Destination", fixture)
        let file = destination.appendingPathComponent("external.txt")
        try Data("external note".utf8).write(to: file)
        _ = try await store.changeDefaultFolder(to: destination, moveExisting: false, from: selection.collectionToken)
        let discovered = await store.records.values.first { $0.fileURL == file }
        let note = try XCTUnwrap(discovered)
        let catalog = try CatalogPersistence.load(at: fixture.root.appendingPathComponent("collection.json"))
        XCTAssertNotNil(catalog.notes[note.id]?.fileAccess)
        let customRoot = try directory("Moved outside", fixture)
        let moved = customRoot.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("unrelated sibling".utf8).write(to: customRoot.appendingPathComponent("sibling.txt"))
        resolutions.withLock { $0[file.path] = moved.path }
        try await store.reconcile(collectionToken: note.collectionToken)
        let notes = await store.records
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[note.id]?.fileURL, moved)
    }
}

extension DefaultFolderChangeTests {
    func testReusedOldDefaultPathDoesNotCaptureHistoricalParentBinding() async throws {
        let fixture = try TestFixture()
        let (_, selection, old) = try await start(fixture)
        let archived = fixture.root.appendingPathComponent("Archived notes", isDirectory: true)
        try FileManager.default.moveItem(at: selection.url, to: archived)
        try FileManager.default.createDirectory(at: selection.url, withIntermediateDirectories: true)
        try Data("replacement folder note".utf8).write(to: old.fileURL)
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let current = try await store.openSelectedFolder()
        let replacement = try XCTUnwrap(current.notes.first { $0.id != old.id })
        let destination = try directory("Destination", fixture)
        let result = try await store.changeDefaultFolder(to: destination, moveExisting: true, from: current.collectionToken)
        XCTAssertEqual(result.batch?.entries.map { $0.sourceID }, [replacement.id])
        XCTAssertEqual(result.batch?.entries.first?.state, .moved)
        XCTAssertEqual(try String(contentsOf: archived.appendingPathComponent("Note.txt"), encoding: .utf8), "old default")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note.txt"), encoding: .utf8), "replacement folder note")
    }
}

extension LocationTests {
    func testAccessClassificationMatchesDomainsAndPreservesBookmarkError() throws {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(NoteFailureMapping.accessFailure(denied).reason, .permission)
        XCTAssertEqual(NoteFailureMapping.accessFailure(NSError(domain: "Other", code: NSFileReadNoPermissionError)).reason, .unknown)
        XCTAssertEqual(NoteFailureMapping.accessFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))).reason, .unavailableVolume)
        XCTAssertEqual(NoteFailureMapping.accessFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))).reason, .missingFile)
        XCTAssertEqual(NoteFailureMapping.accessFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))).reason, .permission)
        XCTAssertFalse(NoteFailureMapping.accessFailure(NoteOperationError.unsupportedEncoding).requiresFolderAccess)
        let cloud = NoteAccessFailure(reason: .cloudPlaceholder, domain: NSCocoaErrorDomain, code: 0, message: "Download required")
        XCTAssertFalse(NoteFailureMapping.accessFailure(NoteOperationError.accessFailure(cloud)).requiresFolderAccess)
        let access = FolderAccess(support: URL(fileURLWithPath: "/tmp/unused"), hooks: FolderAccessHooks(resolve: { _ in throw denied }))
        XCTAssertThrowsError(try access.restore(NoteAccessDescriptor(url: URL(fileURLWithPath: "/tmp/custom"), bookmark: Data(), scope: .folder))) { error in
            guard case let .accessFailure(failure) = error as? NoteOperationError else { return XCTFail("Lost bookmark error") }
            XCTAssertTrue(failure.requiresFolderAccess)
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
            XCTAssertEqual(failure.code, NSFileReadNoPermissionError)
        }
    }

    func testUnmountedVolumeIsNotReportedAsStaleBookmark() throws {
        let unmounted = NoteOperationError.accessFailure(NoteAccessFailure(reason: .unavailableVolume, domain: NSPOSIXErrorDomain,
                                                                           code: Int(ENODEV), message: "Disk"))
        let access = FolderAccess(support: URL(fileURLWithPath: "/tmp/unused"), hooks: FolderAccessHooks(resolve: { _ in throw unmounted }))
        for scope in [NoteAccessDescriptor.Scope.file, .folder] {
            XCTAssertThrowsError(try access.restore(NoteAccessDescriptor(url: URL(fileURLWithPath: "/Volumes/Disk/a.txt"), bookmark: Data(), scope: scope))) { error in
                guard case let .accessFailure(failure) = error as? NoteOperationError else { return XCTFail("Lost volume error") }
                XCTAssertEqual(failure.reason, .unavailableVolume)
                XCTAssertFalse(failure.requiresFolderAccess)
            }
        }
    }

    func testMountedVolumeBookmarkIsNotUnmounted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(FolderAccessHooks.unmountedVolume(of: try file.bookmarkData()))
    }

    func testRenewFolderAccessPreservesIdentityRetainedEditAndRestart() async throws {
        let fixture = try TestFixture()
        let (original, note, directory) = try await setup(fixture)
        let target = directory.appendingPathComponent("custom.txt")
        _ = await move(original, note, to: target)
        let denied = Mutex(true)
        var injected = hooks
        injected.resolve = { data in
            let url = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
            if (url == directory || url == target) && denied.withLock({ $0 }) { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
            return (url, false)
        }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: injected)
        let selection = try await store.openSelectedFolder()
        let unavailable = try XCTUnwrap(selection.notes.first(where: { $0.id == note.id }))
        XCTAssertTrue(unavailable.accessFailure?.requiresFolderAccess == true)
        let refreshed = try await store.read(note.id, collectionToken: selection.collectionToken)
        XCTAssertEqual(refreshed.accessFailure, unavailable.accessFailure)
        let message = try await store.retryAvailability(note.id, collectionToken: selection.collectionToken)
        XCTAssertEqual(message, unavailable.accessFailure.map { String(localized: $0.message) })
        let edit = EditSnapshot(id: note.id, collectionToken: selection.collectionToken, revision: EditRevision(rawValue: 20),
            baseRevision: note.fileRevision, text: "retained repair", locationRevision: unavailable.locationRevision)
        _ = await store.submit(edit)
        guard case let .failed(.accessFailure(saveFailure)) = await store.save(edit) else { return XCTFail("Save lost authorization reason") }
        XCTAssertEqual(saveFailure, unavailable.accessFailure)
        denied.withLock { $0 = false }
        let repaired = try await store.renewFileAccess(note.id, file: try await store.acquireFile(target), collectionToken: selection.collectionToken, locationRevision: unavailable.locationRevision)
        XCTAssertEqual(repaired.id, note.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "retained repair")
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let reopened = try await restarted.openSelectedFolder()
        XCTAssertEqual(reopened.notes.first(where: { $0.id == note.id })?.availability, .available)
    }

    func testRenewRejectsWrongFolderReplacementAndStaleRevision() async throws {
        let fixture = try TestFixture()
        let (store, note, directory) = try await setup(fixture)
        try Data(note.text.utf8).write(to: directory.appendingPathComponent("wrong.txt"))
        do {
            _ = try await store.renewFileAccess(note.id, file: try await store.acquireFile(directory.appendingPathComponent("wrong.txt")), collectionToken: note.collectionToken, locationRevision: note.locationRevision)
            XCTFail("Accepted another file with matching text")
        } catch { XCTAssertEqual(error as? NoteOperationError, .notOriginalFile) }
        // Replace by rename while retaining the original inode, so inode reuse is impossible.
        try FileManager.default.moveItem(at: note.fileURL, to: note.fileURL.appendingPathExtension("old"))
        try Data("replacement".utf8).write(to: note.fileURL)
        do {
            _ = try await store.renewFileAccess(note.id, file: try await store.acquireFile(note.fileURL), collectionToken: note.collectionToken, locationRevision: note.locationRevision)
            XCTFail("Accepted a replacement")
        } catch {}
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "replacement")
        do {
            _ = try await store.renewFileAccess(note.id, file: try await store.acquireFile(note.fileURL), collectionToken: CollectionToken(), locationRevision: note.locationRevision)
            XCTFail("Accepted stale collection")
        } catch { XCTAssertEqual(error as? NoteOperationError, .staleCollection) }
        do {
            _ = try await store.renewFileAccess(note.id, file: try await store.acquireFile(note.fileURL), collectionToken: note.collectionToken, locationRevision: LocationRevision(rawValue: 99))
            XCTFail("Accepted stale location")
        } catch { XCTAssertEqual(error as? NoteOperationError, .staleLocation) }
    }
}

extension LocationTests {
    func testRenewRetainedEditConflictsWithoutOverwritingExternalChange() async throws {
        let fixture = try TestFixture()
        let (store, note, _) = try await setup(fixture)
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: EditRevision(rawValue: 20),
            baseRevision: note.fileRevision, text: "local repair buffer", locationRevision: note.locationRevision)
        _ = await store.submit(edit)
        // An in-place external write keeps identity but changes the base revision.
        try Data("external repair content".utf8).write(to: note.fileURL)
        _ = try await store.renewFileAccess(note.id, file: try await store.acquireFile(note.fileURL), collectionToken: note.collectionToken, locationRevision: note.locationRevision)
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "external repair content")
        let status = await store.status(note.id)
        guard case let .recoverable(_, recoveryURL) = status else { return XCTFail("Expected conflict recovery, got \(String(describing: status))") }
        XCTAssertEqual(try String(contentsOf: recoveryURL, encoding: .utf8), edit.text)
    }

    func testFailedRenewBookmarkPersistenceRetainsLocationAndBalancesScopes() async throws {
        let fixture = try TestFixture()
        let (original, note, directory) = try await setup(fixture)
        _ = await move(original, note, to: directory.appendingPathComponent("custom.txt"))
        let fail = Mutex(false)
        let counts = Mutex((starts: 0, stops: 0))
        var injected = hooks
        injected.start = { _ in counts.withLock { $0.starts += 1 }; return true }
        injected.stop = { _ in counts.withLock { $0.stops += 1 } }
        injected.bookmark = { url in
            if fail.withLock({ $0 }) { throw NoteOperationError.inputOutput("bookmark persistence failed") }
            return Data(url.path.utf8)
        }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: injected)
        let selected = try await store.openSelectedFolder()
        let tracked = try XCTUnwrap(selected.notes.first(where: { $0.id == note.id }))
        let catalog = try Data(contentsOf: fixture.root.appendingPathComponent("collection.json"))
        fail.withLock { $0 = true }
        for _ in 0..<3 {
            do {
                _ = try await store.renewFileAccess(note.id, file: try await store.acquireFile(directory.appendingPathComponent("custom.txt")), collectionToken: selected.collectionToken, locationRevision: tracked.locationRevision)
                XCTFail("Accepted failed bookmark persistence")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("collection.json")), catalog)
        let current = await store.records[note.id]
        XCTAssertEqual(current?.locationRevision, tracked.locationRevision)
        // Existing store-owned grants are shared, with no new starts on repeated failure.
        XCTAssertEqual(counts.withLock { $0.starts - $0.stops }, 1)
    }

    func testLegacyParentGrantMigratesToFileBookmarkAndReleasesParent() async throws {
        let fixture = try TestFixture()
        let external = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let file = external.appendingPathComponent("legacy.txt")
        try Data("legacy note".utf8).write(to: file)
        let started = Mutex<[URL]>([])
        let stopped = Mutex<[URL]>([])
        let fileBookmarkCreated = Mutex(true)
        var trackingHooks = hooks
        trackingHooks.bookmark = { url in
            if url.standardizedFileURL == file.standardizedFileURL { fileBookmarkCreated.withLock { $0 = true } }
            return Data(url.path.utf8)
        }
        trackingHooks.start = { url in
            guard url.standardizedFileURL != file.standardizedFileURL || fileBookmarkCreated.withLock({ $0 }) else { return false }
            started.withLock { $0.append(url.standardizedFileURL) }
            return true
        }
        trackingHooks.stop = { url in stopped.withLock { $0.append(url.standardizedFileURL) } }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: trackingHooks)
        let selected = try await store.openSelectedFolder()
        let note = try await store.registerFile(file, collectionToken: selected.collectionToken)
        let metadataStore = MetadataStore(root: fixture.root)
        var metadata = CollectionMetadata()
        var noteMetadata = NoteWindowMetadata(isOpen: true, frame: CGRect(x: 11, y: 22, width: 333, height: 444),
            focusOrder: 7, lastKnownPath: file.path, fontSize: 19, backgroundTone: .purple)
        noteMetadata.editorPosition = EditorPosition(selections: [.init(location: 3, length: 2)], scrollX: 4, scrollY: 5,
            hasActiveCaret: true, fileModifiedAt: note.fileRevision?.modifiedAt)
        metadata.notes[note.id] = noteMetadata
        try await metadataStore.saveCollection(metadata)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        var legacy = try XCTUnwrap(catalog.notes[note.id])
        legacy.access = NoteAccessDescriptor(url: external, bookmark: Data(external.path.utf8), scope: .folder)
        legacy.fileAccess = nil
        catalog.notes[note.id] = legacy
        try CatalogPersistence.save(catalog, at: catalogURL)

        let startsBeforeMigration = started.withLock { $0.count }
        // A parent-derived URL has no independent file scope until its bookmark exists.
        fileBookmarkCreated.withLock { $0 = false }
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: trackingHooks)
        let reopened = try await restarted.openSelectedFolder()

        let migrated = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        XCTAssertEqual(reopened.notes.first(where: { $0.id == note.id })?.text, "legacy note")
        XCTAssertNil(migrated.access)
        XCTAssertEqual(migrated.fileAccess?.url, file)
        XCTAssertEqual(migrated.fileAccess?.scope, .file)
        XCTAssertNotNil(migrated.fileAccess?.bookmark)
        let migrationStarts = Array(started.withLock { $0.dropFirst(startsBeforeMigration) })
        XCTAssertEqual(migrationStarts.filter { $0 == external.standardizedFileURL }.count, 1)
        XCTAssertEqual(migrationStarts.filter { $0 == file.standardizedFileURL }.count, 1)
        XCTAssertEqual(stopped.withLock { $0.filter { $0 == external.standardizedFileURL }.count }, 1,
            "The temporary legacy parent grant is released after the durable migration checkpoint")
        let loadedMetadata = await metadataStore.loadCollection()
        XCTAssertEqual(loadedMetadata.value, metadata,
            "Location migration must leave window, tint, and editor metadata unchanged")
    }

    func testValidFileBookmarkMigratesEvenWhenLegacyParentBookmarkIsBroken() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("legacy.txt")
        try Data("file grant wins".utf8).write(to: file)
        let starts = Mutex<[URL]>([])
        var trackingHooks = hooks
        trackingHooks.start = { url in starts.withLock { $0.append(url.standardizedFileURL) }; return true }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: trackingHooks)
        let selected = try await store.openSelectedFolder()
        let note = try await store.registerFile(file, collectionToken: selected.collectionToken)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        var legacy = try XCTUnwrap(catalog.notes[note.id])
        legacy.access = NoteAccessDescriptor(url: parent, bookmark: Data(parent.path.utf8), scope: .folder)
        legacy.access?.bookmark = Data("broken parent bookmark".utf8)
        catalog.notes[note.id] = legacy
        try CatalogPersistence.save(catalog, at: catalogURL)
        var selective = trackingHooks
        selective.resolve = { data in
            guard data != Data("broken parent bookmark".utf8) else { throw NoteOperationError.permissionDenied }
            return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        }

        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: selective)
        let reopened = try await restarted.openSelectedFolder()

        let migrated = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        XCTAssertEqual(reopened.notes.first(where: { $0.id == note.id })?.availability, .available)
        XCTAssertNil(migrated.access)
        XCTAssertEqual(migrated.fileAccess?.scope, .file)
        XCTAssertEqual(starts.withLock { $0.filter { $0 == parent.standardizedFileURL }.count }, 0,
            "A valid file bookmark must be sufficient without starting the legacy parent scope")
    }

    func testReadingOneCustomNoteResolvesOnlyItsBookmark() async throws {
        let fixture = try TestFixture()
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let first = outside.appendingPathComponent("first.txt")
        let second = outside.appendingPathComponent("second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let resolved = Mutex<[String]>([])
        var tracking = hooks
        tracking.resolve = { data in
            resolved.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
            return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: tracking)
        let selected = try await store.openSelectedFolder()
        let one = try await store.registerFile(first, collectionToken: selected.collectionToken)
        _ = try await store.registerFile(second, collectionToken: selected.collectionToken)
        resolved.withLock { $0.removeAll() }

        _ = try await store.read(one.id, collectionToken: selected.collectionToken)

        let paths = resolved.withLock { $0 }
        XCTAssertFalse(paths.contains(second.standardizedFileURL.path), "Reading one note must not resolve another note's bookmark")
    }

    func testFailedLegacyMigrationRetainsDescriptorsAndRetriesAfterPartialCheckpoint() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("legacy.txt")
        try Data("migration retry".utf8).write(to: file)
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await store.openSelectedFolder()
        let note = try await store.registerFile(file, collectionToken: selected.collectionToken)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        var legacy = try XCTUnwrap(catalog.notes[note.id])
        legacy.access = NoteAccessDescriptor(url: parent, bookmark: Data(parent.path.utf8), scope: .folder)
        legacy.fileAccess = nil
        catalog.notes[note.id] = legacy
        try CatalogPersistence.save(catalog, at: catalogURL)
        let original = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        let failBookmark = Mutex(true)
        var failing = hooks
        failing.bookmark = { url in
            if failBookmark.withLock({ $0 }) { throw NoteOperationError.inputOutput("injected bookmark failure") }
            return Data(url.path.utf8)
        }

        let failedRestart = try NoteStore(support: fixture.root, folderAccessHooks: failing)
        let failedSelection = try await failedRestart.openSelectedFolder()
        let failedNote = try XCTUnwrap(failedSelection.notes.first(where: { $0.id == note.id }))
        let afterFailure = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        XCTAssertEqual(afterFailure, original)
        guard case .unavailable = failedNote.availability else { return XCTFail("Expected a transient migration availability failure") }
        XCTAssertTrue(failedNote.accessFailure?.requiresFolderAccess == true)

        failBookmark.withLock { $0 = false }
        let retry = try NoteStore(support: fixture.root, folderAccessHooks: failing)
        let retried = try await retry.openSelectedFolder()
        let afterRetry = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        XCTAssertEqual(retried.notes.first(where: { $0.id == note.id })?.availability, .available)
        XCTAssertNil(afterRetry.access)
        XCTAssertEqual(afterRetry.fileAccess?.scope, .file)
        XCTAssertNotNil(afterRetry.fileAccess?.bookmark)
    }

    func testLegacyMigrationCatalogCheckpointFailureRetainsCatalogAndRetries() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("legacy.txt")
        try Data("catalog retry".utf8).write(to: file)
        let initial = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await initial.openSelectedFolder()
        let note = try await initial.registerFile(file, collectionToken: selected.collectionToken)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        var legacy = try XCTUnwrap(catalog.notes[note.id])
        legacy.access = NoteAccessDescriptor(url: parent, bookmark: Data(parent.path.utf8), scope: .folder)
        legacy.fileAccess = nil
        catalog.notes[note.id] = legacy
        try CatalogPersistence.save(catalog, at: catalogURL)
        let originalCatalog = try Data(contentsOf: catalogURL)
        let fail = Mutex(true)
        let failedStore = try NoteStore(support: fixture.root, fault: { stage in
            if case .accessMigrationCatalog = stage, fail.withLock({ $0 }) {
                throw NoteOperationError.inputOutput("injected migration catalog failure")
            }
        }, folderAccessHooks: hooks)

        let failed = try await failedStore.openSelectedFolder()
        let failedNote = try XCTUnwrap(failed.notes.first(where: { $0.id == note.id }))
        XCTAssertEqual(try Data(contentsOf: catalogURL), originalCatalog)
        XCTAssertNotNil(failedNote.accessFailure)

        fail.withLock { $0 = false }
        let retry = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let retried = try await retry.openSelectedFolder()
        let migrated = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        XCTAssertEqual(retried.notes.first(where: { $0.id == note.id })?.availability, .available)
        XCTAssertNil(migrated.access)
        XCTAssertEqual(migrated.fileAccess?.scope, .file)
        XCTAssertNotNil(migrated.fileAccess?.bookmark)
    }

    func testPerNoteMigrationCheckpointsSuccessAndPreservesFailedNoteJournalForRetry() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let failedFile = parent.appendingPathComponent("A failed.txt")
        let successfulFile = parent.appendingPathComponent("B successful.txt")
        try Data("failed note".utf8).write(to: failedFile)
        try Data("successful note".utf8).write(to: successfulFile)
        let initial = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await initial.openSelectedFolder()
        let failedNote = try await initial.registerFile(failedFile, collectionToken: selected.collectionToken)
        let successfulNote = try await initial.registerFile(successfulFile, collectionToken: selected.collectionToken)
        let journalStore = RecoveryStore(root: fixture.root.appendingPathComponent("Recovery"), fault: { _ in })
        var journal = RecoveryRecord(id: UUID(), noteID: failedNote.id, collectionToken: failedNote.collectionToken,
            originalURL: failedFile, baseRevision: failedNote.fileRevision, editRevision: EditRevision(rawValue: 1),
            text: "retained draft", createdAt: Date(timeIntervalSince1970: 10), reason: .saveFailure)
        journal.trackingRemoved = true
        try journalStore.retain(journal)
        let journalURL = fixture.root.appendingPathComponent("Recovery/Retained", isDirectory: true)
            .appendingPathComponent(journal.id.uuidString + ".json")
        let journalBytes = try Data(contentsOf: journalURL)

        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        for id in [failedNote.id, successfulNote.id] {
            var legacy = try XCTUnwrap(catalog.notes[id])
            legacy.access = NoteAccessDescriptor(url: parent, bookmark: Data(parent.path.utf8), scope: .folder)
            legacy.fileAccess = nil
            catalog.notes[id] = legacy
        }
        try CatalogPersistence.save(catalog, at: catalogURL)
        let legacyFailed = try XCTUnwrap(catalog.notes[failedNote.id])
        let failingPath = Mutex(true)
        let started = Mutex<[URL]>([])
        var migrationHooks = hooks
        migrationHooks.start = { url in started.withLock { $0.append(url.standardizedFileURL) }; return true }
        migrationHooks.bookmark = { url in
            if url.standardizedFileURL == failedFile.standardizedFileURL && failingPath.withLock({ $0 }) {
                throw NoteOperationError.inputOutput("injected per-note bookmark failure")
            }
            return Data(url.path.utf8)
        }

        let retryableStore = try NoteStore(support: fixture.root, folderAccessHooks: migrationHooks)
        let firstOpen = try await retryableStore.openSelectedFolder()
        let partial = try CatalogPersistence.load(at: catalogURL)
        let stillLegacy = try XCTUnwrap(partial.notes[failedNote.id])
        let migrated = try XCTUnwrap(partial.notes[successfulNote.id])
        XCTAssertEqual(stillLegacy, legacyFailed)
        XCTAssertNil(migrated.access)
        XCTAssertEqual(migrated.fileAccess?.scope, .file)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes,
            "A failed location migration must preserve the retained recovery journal bytes")
        XCTAssertEqual(firstOpen.notes.first(where: { $0.id == successfulNote.id })?.availability, .available)

        let startsBeforeRetry = started.withLock { $0.count }
        failingPath.withLock { $0 = false }
        _ = try await retryableStore.customLocations(defaultURL: firstOpen.url)
        let retryStarts = Array(started.withLock { $0.dropFirst(startsBeforeRetry) })
        XCTAssertEqual(retryStarts.filter { $0 == parent.standardizedFileURL }.count, 1,
            "Retry should use the parent only for the still-legacy failed note")
        let afterRetry = try CatalogPersistence.load(at: catalogURL)
        XCTAssertNil(afterRetry.notes[failedNote.id]?.access)
        XCTAssertNil(afterRetry.notes[successfulNote.id]?.access)
        XCTAssertNotNil(afterRetry.notes[failedNote.id]?.fileAccess?.bookmark)
        XCTAssertNotNil(afterRetry.notes[successfulNote.id]?.fileAccess?.bookmark)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
    }

    func testWrongFileBookmarkResourceRetainsLegacyParentDescriptor() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("tracked.txt")
        let impostor = parent.appendingPathComponent("impostor.txt")
        try Data("tracked".utf8).write(to: file)
        try Data("impostor".utf8).write(to: impostor)
        let initial = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await initial.openSelectedFolder()
        let note = try await initial.registerFile(file, collectionToken: selected.collectionToken)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        var legacy = try XCTUnwrap(catalog.notes[note.id])
        legacy.access = NoteAccessDescriptor(url: parent, bookmark: Data("damaged legacy parent".utf8), scope: .folder)
        legacy.fileAccess = NoteAccessDescriptor(url: impostor, bookmark: Data(impostor.path.utf8), scope: .file)
        catalog.notes[note.id] = legacy
        try CatalogPersistence.save(catalog, at: catalogURL)
        let original = legacy

        var guardedHooks = hooks
        guardedHooks.resolve = { data in
            guard data != Data("damaged legacy parent".utf8) else { throw NoteOperationError.permissionDenied }
            return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        }
        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: guardedHooks)
        _ = try await restarted.openSelectedFolder()

        let after = try XCTUnwrap(CatalogPersistence.load(at: catalogURL).notes[note.id])
        XCTAssertEqual(after.access, original.access,
            "A file bookmark resolving to another resource must not clear the legacy parent grant")
    }

    func testMigrationRejectsFileBookmarkPathOwnedByAnotherCatalogIdentity() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let originalURL = parent.appendingPathComponent("original.txt")
        let trackedAlias = parent.appendingPathComponent("tracked-alias.txt")
        try Data("same underlying file".utf8).write(to: originalURL)
        try FileManager.default.linkItem(at: originalURL, to: trackedAlias)
        let initial = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let selected = try await initial.openSelectedFolder()
        let first = try await initial.registerFile(originalURL, collectionToken: selected.collectionToken)
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        var catalog = try CatalogPersistence.load(at: catalogURL)
        var firstLegacy = try XCTUnwrap(catalog.notes[first.id])
        firstLegacy.access = NoteAccessDescriptor(url: parent, bookmark: Data(parent.path.utf8), scope: .folder)
        firstLegacy.fileAccess = NoteAccessDescriptor(url: trackedAlias, bookmark: Data(trackedAlias.path.utf8), scope: .file)
        catalog.notes[first.id] = firstLegacy

        let secondID = NoteID()
        let second = NoteLocationRecord(id: secondID, resource: firstLegacy.resource, path: trackedAlias.path,
            parentResource: firstLegacy.parentResource,
            fileAccess: NoteAccessDescriptor(url: trackedAlias, bookmark: Data(trackedAlias.path.utf8), scope: .file))
        catalog.notes[secondID] = second
        try CatalogPersistence.save(catalog, at: catalogURL)

        let restarted = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        _ = try await restarted.customLocations(defaultURL: selected.url)

        let after = try CatalogPersistence.load(at: catalogURL)
        XCTAssertEqual(Set(after.notes.keys), Set([first.id, secondID]),
            "Migration must not let IdentityMap displace the identity already tracked at the target path")
        XCTAssertEqual(after.notes[first.id], firstLegacy,
            "A path collision must preserve the first identity and its legacy parent descriptor")
        XCTAssertNotNil(after.notes[secondID])
        let failure = await restarted.accessFailures[first.id]
        XCTAssertNotNil(failure)
    }

    func testLiteralVersionOneCatalogKeepsUnfinishedOperationGrantEvidence() async throws {
        let fixture = try TestFixture()
        let parent = fixture.root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("legacy.txt")
        try Data("unfinished operation".utf8).write(to: file)
        let noteID = "11111111-2222-3333-4444-555555555555"
        let operationID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let parentURL = parent.absoluteString
        let json = #"""
        {
          "version": 1,
          "defaultFolder": null,
          "notes": [
            {"rawValue":"\#(noteID)"},
            {"id":{"rawValue":"\#(noteID)"},"resource":"file-resource-1","path":"\#(file.path)",
             "parentResource":"parent-resource-1",
             "access":{"url":"\#(parentURL)","bookmark":"YnJva2VuLXBhcmVudA==","scope":"folder"},
             "availability":{"available":{}},"revision":{"rawValue":0}}
          ],
          "operations": [
            "\#(operationID)",
            {"id":"\#(operationID)","noteID":{"rawValue":"\#(noteID)"},
             "source":{"id":{"rawValue":"\#(noteID)"},"resource":"file-resource-1","path":"\#(file.path)",
               "parentResource":"parent-resource-1",
               "access":{"url":"\#(parentURL)","bookmark":"YnJva2VuLXBhcmVudA==","scope":"folder"},
               "availability":{"available":{}},"revision":{"rawValue":0}},
             "destination":{"url":"\#(parentURL)","bookmark":"YnJva2VuLWRlc3RpbmF0aW9u","scope":"folder"},
             "expectedEditRevision":{"rawValue":1},"stage":"prepared","crossVolume":false}
          ],
          "recoveryLinks": [],
          "defaultDecision":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
          "defaultBatches": []
        }
        """#
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        try Data(json.utf8).write(to: catalogURL)
        let original = try CatalogPersistence.load(at: catalogURL)
        let originalNote = try XCTUnwrap(original.notes[NoteID(UUID(uuidString: noteID)! )])
        let originalOperation = try XCTUnwrap(original.operations[UUID(uuidString: operationID)!])
        var fileHooks = hooks
        fileHooks.resolve = { data in
            if data == Data("broken-parent".utf8) || data == Data("broken-destination".utf8) {
                throw NoteOperationError.permissionDenied
            }
            return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
        }

        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileHooks)
        _ = try await store.openSelectedFolder()

        let after = try CatalogPersistence.load(at: catalogURL)
        XCTAssertEqual(after.notes[originalNote.id], originalNote,
            "The unfinished operation keeps its legacy source grant evidence unchanged")
        XCTAssertEqual(after.operations[originalOperation.id], originalOperation)
    }

    func testSaveCopyCreatesNewNoteAndLeavesRetainedOriginalEditsUntouched() async throws {
        let fixture = try TestFixture()
        let originalURL = fixture.root.appendingPathComponent("original.txt")
        let copyURL = fixture.root.appendingPathComponent("copy.txt")
        try Data("disk original".utf8).write(to: originalURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, timing: StoreTiming(saveDebounce: .seconds(30)),
                                  folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let original = try await store.registerFile(originalURL, collectionToken: selection.collectionToken)
        let edit = EditSnapshot(id: original.id, collectionToken: selection.collectionToken,
            revision: EditRevision(rawValue: 1), baseRevision: original.fileRevision, text: "retained original edit",
            locationRevision: original.locationRevision)
        _ = await store.submit(edit)
        let journalBefore = await store.journalRecords[original.id]
        let statusBefore = await store.status(original.id)
        let retained = try await store.copySource(original.id, collectionToken: selection.collectionToken)
        XCTAssertEqual(retained.editRevision, edit.revision)
        XCTAssertEqual(retained.text, edit.text)
        let grant = try await store.acquireDestinationFile(copyURL)

        let copy = try await store.createCopy(from: original, editRevision: retained.editRevision,
            text: "copy editor text", to: grant)

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.fileURL, copyURL)
        XCTAssertEqual(copy.text, "copy editor text")
        XCTAssertEqual(try Data(contentsOf: copyURL), Data("copy editor text".utf8))
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("disk original".utf8))
        let statusAfter = await store.status(original.id)
        let journalAfter = await store.journalRecords[original.id]
        let originalRecord = await store.records[original.id]
        XCTAssertEqual(statusAfter, statusBefore)
        XCTAssertEqual(journalAfter, journalBefore)
        XCTAssertEqual(originalRecord?.id, original.id)
    }

    func testSaveCopyRejectsTrackedDestinationBeforeWriting() async throws {
        let fixture = try TestFixture()
        let sourceURL = fixture.root.appendingPathComponent("source.txt")
        let trackedURL = fixture.root.appendingPathComponent("tracked.txt")
        try Data("source".utf8).write(to: sourceURL)
        try Data("tracked".utf8).write(to: trackedURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let source = try await store.registerFile(sourceURL, collectionToken: selection.collectionToken)
        _ = try await store.registerFile(trackedURL, collectionToken: selection.collectionToken)
        let grant = try await store.acquireDestinationFile(trackedURL)

        do {
            _ = try await store.createCopy(from: source, editRevision: source.editRevision, text: "replacement", to: grant)
            XCTFail("Expected a tracked destination to be rejected")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .destinationOccupied)
        }
        XCTAssertEqual(try Data(contentsOf: trackedURL), Data("tracked".utf8))
    }


    func testSaveCopyAllowsUnavailableSourceAndDoesNotRegisterBeforeVerification() async throws {
        let fixture = try TestFixture()
        let originalURL = fixture.root.appendingPathComponent("original.txt")
        let copyURL = fixture.root.appendingPathComponent("copy.txt")
        try Data("disk original".utf8).write(to: originalURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, fault: { stage in
            if case .copyVerification = stage { throw NoteOperationError.permissionDenied }
        }, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let original = try await store.registerFile(originalURL, collectionToken: selection.collectionToken)
        let unavailable = NoteSnapshot(id: original.id, collectionToken: original.collectionToken, fileURL: original.fileURL,
            fileRevision: original.fileRevision, text: original.text, availability: .missingOriginal,
            editRevision: original.editRevision, locationRevision: original.locationRevision)
        let grant = try await store.acquireDestinationFile(copyURL)
        let countBefore = await store.records.count

        do {
            _ = try await store.createCopy(from: unavailable, editRevision: unavailable.editRevision,
                text: "retained conflict text", to: grant)
            XCTFail("Expected injected verification failure")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .permissionDenied)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        let recordsAfter = await store.records
        XCTAssertEqual(recordsAfter.count, countBefore)
        XCTAssertEqual(recordsAfter[original.id]?.id, original.id)
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("disk original".utf8))
    }

    func testVerifiedCopyOfUnsavedTextReleasesTheFailedNote() async throws {
        let fixture = try TestFixture()
        let originalURL = fixture.root.appendingPathComponent("original.txt")
        let copyURL = fixture.root.appendingPathComponent("copy.txt")
        let otherURL = fixture.root.appendingPathComponent("other.txt")
        try Data("disk original".utf8).write(to: originalURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, fault: { stage in
            if case .destination = stage { throw NoteOperationError.inputOutput("destination write failed") }
        }, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let original = try await store.registerFile(originalURL, collectionToken: selection.collectionToken)
        let edit = EditSnapshot(id: original.id, collectionToken: selection.collectionToken,
            revision: EditRevision(rawValue: 1), baseRevision: original.fileRevision, text: "copy me",
            locationRevision: original.locationRevision)
        _ = await store.submit(edit)
        guard case .failed = await store.save(edit) else { return XCTFail("The save should fail") }
        let blocked = await store.canDispose(original.id)
        XCTAssertFalse(blocked)

        // A copy of different text must not release the note.
        _ = try await store.createCopy(from: original, editRevision: edit.revision, text: "other",
            to: try await store.acquireDestinationFile(otherURL))
        let stillBlocked = await store.canDispose(original.id)
        XCTAssertFalse(stillBlocked)

        _ = try await store.createCopy(from: original, editRevision: edit.revision, text: "copy me",
            to: try await store.acquireDestinationFile(copyURL))
        let released = await store.canDispose(original.id)
        let status = await store.status(original.id)
        XCTAssertTrue(released)
        XCTAssertEqual(status, StorageSaveStatus.recoverable(edit.revision, copyURL.standardizedFileURL))
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("disk original".utf8))
    }

    func testSaveCopyCatalogFailureLeavesOriginalStateAndDoesNotRegisterCopy() async throws {
        let fixture = try TestFixture()
        let originalURL = fixture.root.appendingPathComponent("original.txt")
        let copyURL = fixture.root.appendingPathComponent("copy.txt")
        try Data("disk original".utf8).write(to: originalURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, fault: { stage in
            if case .copyCatalog = stage { throw NoteOperationError.permissionDenied }
        }, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let original = try await store.registerFile(originalURL, collectionToken: selection.collectionToken)
        let edit = EditSnapshot(id: original.id, collectionToken: selection.collectionToken,
            revision: EditRevision(rawValue: 1), baseRevision: original.fileRevision, text: "retained original edit",
            locationRevision: original.locationRevision)
        _ = await store.submit(edit)
        let journalBefore = await store.journalRecords[original.id]
        let statusBefore = await store.status(original.id)
        let grant = try await store.acquireDestinationFile(copyURL)

        do {
            _ = try await store.createCopy(from: original, editRevision: edit.revision,
                text: "copy text", to: grant)
            XCTFail("Expected injected catalog failure")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .permissionDenied)
        }

        let statusAfter = await store.status(original.id)
        let journalAfter = await store.journalRecords[original.id]
        let recordsAfter = await store.records
        XCTAssertEqual(statusAfter, statusBefore)
        XCTAssertEqual(journalAfter, journalBefore)
        XCTAssertEqual(recordsAfter.count, 1)
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("disk original".utf8))
        XCTAssertEqual(try Data(contentsOf: copyURL), Data("copy text".utf8))
    }


    func testSaveCopyOverwritesEligibleUntrackedDestinationAfterPanelConfirmation() async throws {
        let fixture = try TestFixture()
        let sourceURL = fixture.root.appendingPathComponent("source.txt")
        let destinationURL = fixture.root.appendingPathComponent("untracked.txt")
        try Data("source".utf8).write(to: sourceURL)
        try Data("previous untracked contents".utf8).write(to: destinationURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let source = try await store.registerFile(sourceURL, collectionToken: selection.collectionToken)
        let grant = try await store.acquireDestinationFile(destinationURL)

        let copy = try await store.createCopy(from: source, editRevision: source.editRevision,
            text: "new copy text", to: grant)

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new copy text".utf8))
    }


    func testSaveCopyRejectsStaleEditRevisionBeforeCreatingDestination() async throws {
        let fixture = try TestFixture()
        let sourceURL = fixture.root.appendingPathComponent("source.txt")
        let copyURL = fixture.root.appendingPathComponent("copy.txt")
        try Data("source".utf8).write(to: sourceURL)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let source = try await store.registerFile(sourceURL, collectionToken: selection.collectionToken)
        let grant = try await store.acquireDestinationFile(copyURL)

        do {
            _ = try await store.createCopy(from: source, editRevision: EditRevision(rawValue: 1),
                text: "stale text", to: grant)
            XCTFail("Expected stale editor state to be rejected")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .conflict)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("source".utf8))
    }

    func testClosedMissingCopySourceRequiresRetainedText() async throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("missing-source.txt")
        try Data("original".utf8).write(to: url)
        var fileOnlyHooks = hooks
        fileOnlyHooks.start = { $0.pathExtension == "txt" }
        let store = try NoteStore(support: fixture.root, folderAccessHooks: fileOnlyHooks)
        let selection = try await store.openSelectedFolder()
        let note = try await store.registerFile(url, collectionToken: selection.collectionToken)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await store.copySource(note.id, collectionToken: selection.collectionToken)
            XCTFail("Unavailable bytes must not become an empty copy")
        } catch let error as NoteOperationError {
            XCTAssertEqual(error, .unavailable)
        }
        let records = await store.records
        XCTAssertNotNil(records[note.id])
    }

}

extension DefaultFolderChangeTests {
    func testRenameThenMovedDefaultFolderLeavesNoRowsForOldPaths() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, folderAccessHooks: hooks)
        let first = try directory("First", fixture)
        try Data("one".utf8).write(to: first.appendingPathComponent("disk-1.txt"))
        try Data("two".utf8).write(to: first.appendingPathComponent("disk-2.txt"))
        let initial = try await store.openSelectedFolder()
        let firstResult = try await store.changeDefaultFolder(to: first, moveExisting: false, from: initial.collectionToken)
        _ = try await store.discover(in: first, collectionToken: firstResult.collectionToken)

        for name in ["disk-1", "disk-2"] {
            try FileManager.default.moveItem(at: first.appendingPathComponent("\(name).txt"), to: first.appendingPathComponent("\(name)-renamed.txt"))
        }
        try await store.reconcile(collectionToken: firstResult.collectionToken)

        let second = try directory("Second", fixture)
        let moved = try await store.changeDefaultFolder(to: second, moveExisting: true, from: firstResult.collectionToken)
        try await store.reconcile(collectionToken: moved.collectionToken)
        // The old folder disappears, as an ejected volume does.
        try FileManager.default.moveItem(at: first, to: fixture.root.appendingPathComponent("Ejected"))
        try await store.reconcile(collectionToken: moved.collectionToken)

        let records = await store.records.values
        let paths = records.map { $0.fileURL.path }.sorted()
        XCTAssertEqual(records.filter { $0.fileURL.deletingLastPathComponent().standardizedFileURL == first.standardizedFileURL }.map(\.fileURL.lastPathComponent), [],
                       "Rows for old paths: \(paths)")
        XCTAssertEqual(records.count, 2, "Notes: \(paths)")
    }
}

extension LocationTests {
    /// The volume UUID survives a remount. The volumeIdentifier can change.
    func testFileIDUsesVolumeUUIDAndFileIDAndChangesOnReplacement() throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("stable.txt")
        try Data("one".utf8).write(to: file)
        let values = try file.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        let volume = try XCTUnwrap(values.volumeUUIDString)
        let inode = try XCTUnwrap(values.fileIdentifier)
        let id = try XCTUnwrap(StorageFiles.fileResourceID(file))
        XCTAssertEqual(id, "vol:\(volume):\(inode)")
        XCTAssertEqual(try StorageFiles.fileResourceID(file), id)
        XCTAssertEqual(try StorageFiles.resourceID(fixture.root), "vol:\(volume):\(try XCTUnwrap(fixture.root.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier))")

        let renamed = fixture.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertEqual(try StorageFiles.fileResourceID(renamed), id, "A rename keeps the ID")

        try Data("two".utf8).write(to: renamed, options: .atomic)
        XCTAssertNotEqual(try StorageFiles.fileResourceID(renamed), id, "An atomic replacement is a different file")
    }
}

final class CatalogForgettingTests: XCTestCase {
    func testForgettingDropsEveryReferenceToTheNote() {
        let gone = NoteID(), kept = NoteID()
        let goneRecord = NoteLocationRecord(id: gone, resource: nil, path: "/gone.txt")
        let keptRecord = NoteLocationRecord(id: kept, resource: nil, path: "/kept.txt")
        let access = NoteAccessDescriptor(url: URL(fileURLWithPath: "/dest"), bookmark: nil, scope: .folder)
        var catalog = CollectionCatalog()
        catalog.notes = [gone: goneRecord, kept: keptRecord]
        let op = LocationOperation(id: UUID(), noteID: gone, source: goneRecord, destination: access,
                                   expectedEditRevision: EditRevision(rawValue: 0), stage: .prepared)
        catalog.operations[op.id] = op
        let onlyGone = DefaultFolderBatch(id: UUID(), decision: UUID(), sourceFolder: URL(fileURLWithPath: "/"), sourceResource: nil,
            destination: access, destinationResource: "r", moveExisting: true, state: .paused,
            entries: [.init(source: goneRecord, destination: URL(fileURLWithPath: "/dest/gone.txt"), state: .failed)])
        var mixed = onlyGone
        mixed = DefaultFolderBatch(id: UUID(), decision: mixed.decision, sourceFolder: mixed.sourceFolder, sourceResource: nil,
            destination: access, destinationResource: "r", moveExisting: true, state: .paused,
            entries: mixed.entries + [.init(source: keptRecord, destination: URL(fileURLWithPath: "/dest/kept.txt"), state: .failed)])
        catalog.defaultBatches = [onlyGone.id: onlyGone, mixed.id: mixed]
        let link = UUID()
        catalog.recoveryLinks[link] = RecoveryNotice(originalURL: URL(fileURLWithPath: "/gone.txt"),
            recoveryURL: URL(fileURLWithPath: "/r.txt"), originalMissing: true, recoveryNoteID: kept, sourceNoteID: gone)

        let forgotten = catalog.forgetting([gone])

        XCTAssertNil(forgotten.notes[gone])
        XCTAssertNotNil(forgotten.notes[kept])
        XCTAssertTrue(forgotten.operations.isEmpty)
        XCTAssertNil(forgotten.defaultBatches[onlyGone.id])
        XCTAssertEqual(forgotten.defaultBatches[mixed.id]?.entries.map(\.source.id), [kept])
        XCTAssertTrue(forgotten.recoveryLinks.isEmpty)
    }

    /// A catalog saved before batches were pruned can keep entries for notes it no longer
    /// registers. Startup must drop them, or the batch stays retryable and fails forever.
    func testStartupDropsBatchEntriesForUnregisteredNotes() throws {
        let gone = NoteID(), kept = NoteID()
        let goneRecord = NoteLocationRecord(id: gone, resource: nil, path: "/gone.txt")
        let keptRecord = NoteLocationRecord(id: kept, resource: nil, path: "/kept.txt")
        let access = NoteAccessDescriptor(url: URL(fileURLWithPath: "/dest"), bookmark: nil, scope: .folder)
        func batch(_ records: [NoteLocationRecord]) -> DefaultFolderBatch {
            DefaultFolderBatch(id: UUID(), decision: UUID(), sourceFolder: URL(fileURLWithPath: "/"), sourceResource: nil,
                destination: access, destinationResource: "r", moveExisting: true, state: .paused,
                entries: records.map { .init(source: $0, destination: URL(fileURLWithPath: "/dest" + $0.path), state: .failed) })
        }
        let onlyGone = batch([goneRecord]), mixed = batch([goneRecord, keptRecord])
        var catalog = CollectionCatalog()
        catalog.notes = [kept: keptRecord]
        catalog.defaultBatches = [onlyGone.id: onlyGone, mixed.id: mixed]

        let pruned = catalog.pruningOrphans()

        XCTAssertNil(pruned.defaultBatches[onlyGone.id])
        XCTAssertEqual(pruned.defaultBatches[mixed.id]?.entries.map(\.source.id), [kept])
    }
}

extension LocationTests {
    /// Each forget path leaves no durable trace: after a restart and the app's window-state
    /// pruning, the NoteID is in no file under the support directory.
    func testRemovedNoteLeavesNoDurableTraceAfterRestart() async throws { try await assertNoDurableTrace(.removeFromList) }
    func testTrashedNoteLeavesNoDurableTraceAfterRestart() async throws { try await assertNoDurableTrace(.trash) }
    func testRescanDroppingGoneTrashedFileLeavesNoDurableTraceAfterRestart() async throws { try await assertNoDurableTrace(.rescan) }

    private enum ForgetPath { case removeFromList, trash, rescan }

    private func assertNoDurableTrace(_ path: ForgetPath, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try TestFixture()
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        let trashRoot = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
        let trash = TrashService(move: { url in
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let target = trashRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        func makeStore() throws -> NoteStore { try NoteStore(support: fixture.root, trashService: trash, folderAccessHooks: hooks) }
        let goneID: NoteID
        let keptID: NoteID
        let customURL: URL
        do {
            let store = try makeStore()
            let selection = try await store.openSelectedFolder()
            keptID = try await store.create(in: selection.url, collectionToken: selection.collectionToken).id
            let directory = fixture.root.appendingPathComponent("Destination", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            customURL = directory.appendingPathComponent("gone.txt")
            try Data("gone".utf8).write(to: customURL)
            let parent = try await store.folderAccess.acquire(directory)
            let custom = try await store.registerCustomFile(customURL, parent: parent)
            goneID = custom.id
            let recovery = await store.recovery
            try recovery.write(RecoveryRecord(id: UUID(), noteID: custom.id, collectionToken: custom.collectionToken,
                originalURL: customURL, baseRevision: nil, editRevision: .init(rawValue: 1),
                text: "journaled", createdAt: .distantPast, reason: .saveFailure))
        }
        // Window state, a recovery notice, and a failed default-folder batch entry.
        try await MetadataStore(root: fixture.root).saveCollection(CollectionMetadata(notes: [
            goneID: NoteWindowMetadata(isOpen: true), keptID: NoteWindowMetadata(isOpen: false)]))
        var catalog = try CatalogPersistence.load(at: catalogURL)
        let goneRecord = try XCTUnwrap(catalog.notes[goneID], file: file, line: line)
        let keptRecord = try XCTUnwrap(catalog.notes[keptID], file: file, line: line)
        catalog.recoveryLinks[UUID()] = RecoveryNotice(originalURL: URL(fileURLWithPath: goneRecord.path),
            recoveryURL: URL(fileURLWithPath: keptRecord.path), originalMissing: true, recoveryNoteID: keptID, sourceNoteID: goneID)
        let access = NoteAccessDescriptor(url: fixture.root.appendingPathComponent("Elsewhere"), bookmark: nil, scope: .folder)
        let batch = DefaultFolderBatch(id: UUID(), decision: UUID(), sourceFolder: fixture.root, sourceResource: nil,
            destination: access, destinationResource: "r", moveExisting: true, state: .paused,
            entries: [.init(source: goneRecord, destination: access.url.appendingPathComponent("gone.txt"), state: .failed),
                      .init(source: keptRecord, destination: access.url.appendingPathComponent("kept.txt"), state: .failed)])
        catalog.defaultBatches[batch.id] = batch
        if path == .rescan { catalog.notes[goneID]?.availability = .trashed }
        try CatalogPersistence.save(catalog, at: catalogURL)
        if path != .trash { try FileManager.default.removeItem(at: customURL) }
        let needle = Data(goneID.rawValue.uuidString.utf8)
        XCTAssertFalse(Self.filesContaining(needle, under: fixture.root).isEmpty, "Fixture must seed the NoteID", file: file, line: line)

        let store = try makeStore()
        let selection = try await store.openSelectedFolder()
        switch path {
        case .removeFromList:
            let before = await store.records[goneID]
            let gone = try XCTUnwrap(before, file: file, line: line)
            _ = try? await store.read(goneID, collectionToken: gone.collectionToken)
            let after = await store.records[goneID]
            let current = try XCTUnwrap(after, file: file, line: line)
            try await store.removeUnavailableNote(goneID, collectionToken: current.collectionToken, locationRevision: current.locationRevision)
        case .trash:
            try await store.moveToTrash(goneID, collectionToken: selection.collectionToken)
        case .rescan:
            try await store.reconcile(collectionToken: selection.collectionToken)
        }
        let forgotten = await store.records[goneID]
        XCTAssertNil(forgotten, file: file, line: line)

        // Relaunch: a new store and metadata store on the same support directory, pruned by the app's own function.
        let restarted = try makeStore()
        _ = try await restarted.openSelectedFolder()
        let metadata = MetadataStore(root: fixture.root)
        let stored = await metadata.loadCollection().value
        let registered = await restarted.registeredNoteIDs()
        let pruned = try XCTUnwrap(WindowStatePruning.prune(stored, registered: registered),
            "The stored window state still holds the forgotten note", file: file, line: line)
        XCTAssertNotNil(pruned.notes[keptID], file: file, line: line)
        try await metadata.saveCollection(pruned)

        XCTAssertEqual(Self.filesContaining(needle, under: fixture.root), [], file: file, line: line)
        XCTAssertEqual(Self.filesContaining(Data(goneID.rawValue.uuidString.lowercased().utf8), under: fixture.root), [], file: file, line: line)
    }

    private static func filesContaining(_ needle: Data, under root: URL) -> [String] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? []
        return files.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && (try? Data(contentsOf: url))?.range(of: needle) != nil
        }.map(\.lastPathComponent)
    }

    func testPruningFinishedKeepsUnfinishedWorkAndRetryableBatches() {
        let note = NoteID(), other = NoteID()
        let record = NoteLocationRecord(id: note, resource: nil, path: "/a.txt")
        let otherRecord = NoteLocationRecord(id: other, resource: nil, path: "/b.txt")
        let access = NoteAccessDescriptor(url: URL(fileURLWithPath: "/dest"), bookmark: nil, scope: .folder)
        func operation(_ id: NoteID, _ source: NoteLocationRecord, _ stage: LocationOperationStage) -> LocationOperation {
            LocationOperation(id: UUID(), noteID: id, source: source, destination: access, expectedEditRevision: EditRevision(rawValue: 0), stage: stage)
        }
        func batch(_ state: DefaultFolderBatch.State, _ entryState: DefaultFolderBatch.Entry.State, _ source: NoteLocationRecord) -> DefaultFolderBatch {
            DefaultFolderBatch(id: UUID(), decision: UUID(), sourceFolder: URL(fileURLWithPath: "/"), sourceResource: nil,
                destination: access, destinationResource: "r", moveExisting: true, state: state,
                entries: [.init(source: source, destination: URL(fileURLWithPath: "/dest/x.txt"), state: entryState)])
        }
        let doneOp = operation(note, record, .complete), openOp = operation(other, otherRecord, .sourceRemoved)
        let settled = batch(.settled, .moved, record), failed = batch(.settled, .failed, otherRecord)
        var catalog = CollectionCatalog()
        catalog.operations = [doneOp.id: doneOp, openOp.id: openOp]
        catalog.defaultBatches = [settled.id: settled, failed.id: failed]

        let pruned = catalog.pruningFinished()

        XCTAssertNil(pruned.defaultBatches[settled.id])
        XCTAssertNotNil(pruned.defaultBatches[failed.id])
        XCTAssertNil(pruned.operations[doneOp.id])
        XCTAssertNotNil(pruned.operations[openOp.id])

        var running = batch(.running, .pending, record)
        running.state = .running
        catalog.defaultBatches = [running.id: running]
        XCTAssertNotNil(catalog.pruningFinished().operations[doneOp.id], "a running batch may still need the finished operation")
    }
}
