import ramnotesDomain
import XCTest
@testable import ramnotes

final class DiscoveryLifecycleTests: XCTestCase {
    func testSearchTracksExternalRenameEditAndRemoval() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let originalURL = folder.appendingPathComponent("Original.txt")
        try Data("first version".utf8).write(to: originalURL)
        let collectionToken = CollectionToken()
        let initialNotes = try await store.discover(in: folder, collectionToken: collectionToken)
        let original = try XCTUnwrap(initialNotes.first)
        let index = SearchIndex()

        let initialResults = await index.search(notes: initialNotes, query: "updatedterm")
        XCTAssertTrue(initialResults.isEmpty)

        let renamedURL = folder.appendingPathComponent("Renamed.txt")
        try FileManager.default.moveItem(at: originalURL, to: renamedURL)
        try Data("body with UpdatedTerm".utf8).write(to: renamedURL)
        try await store.reconcile(collectionToken: collectionToken)

        let edited = try await store.read(original.id, collectionToken: collectionToken)
        XCTAssertEqual(edited.fileURL, renamedURL)
        XCTAssertEqual(edited.text, "body with UpdatedTerm")
        let editedResults = await index.search(notes: [edited], query: "updatedterm")
        XCTAssertEqual(editedResults.map(\.note.id), [original.id])

        try FileManager.default.removeItem(at: renamedURL)
        try await store.reconcile(collectionToken: collectionToken)
        let remaining = try await store.discover(in: folder, collectionToken: collectionToken)

        let removedResults = await index.search(notes: remaining, query: "updatedterm")
        XCTAssertTrue(removedResults.isEmpty)
    }

    func testDefaultChangeRetainsCollectionAndSearchIncludesCustomNotes() async throws {
        let fixture = try TestFixture()
        var hooks = FolderAccessHooks()
        hooks.start = { _ in true }
        hooks.stop = { _ in }
        hooks.bookmark = { Data($0.path.utf8) }
        hooks.resolve = { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, folderAccessHooks: hooks)

        let firstFolder = fixture.root.appendingPathComponent("First", isDirectory: true)
        let secondFolder = fixture.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try Data("firstfolderterm".utf8).write(to: firstFolder.appendingPathComponent("First.txt"))
        try Data("secondfolderterm".utf8).write(to: secondFolder.appendingPathComponent("Second.txt"))

        let oldGeneration = CollectionToken()
        let firstNotes = try await store.discover(in: firstFolder, collectionToken: oldGeneration)
        let firstNote = try XCTUnwrap(firstNotes.first)
        let newGeneration = try await store.switchFolder(to: secondFolder, from: oldGeneration)
        let currentNotes = Array(await store.records.values)
        XCTAssertEqual(newGeneration, oldGeneration)
        let index = SearchIndex()

        let retained = try await store.read(firstNote.id, collectionToken: oldGeneration)
        XCTAssertEqual(retained.text, "firstfolderterm")

        let oldFolderResults = await index.search(notes: currentNotes, query: "firstfolderterm")
        let currentFolderResults = await index.search(notes: currentNotes, query: "secondfolderterm")
        XCTAssertEqual(oldFolderResults.count, 1)
        XCTAssertEqual(currentFolderResults.count, 1)
    }

    func testRetryMakesPreviouslyInvalidUTF8NoteSearchable() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Recoverable.txt")
        try Data([0x66, 0x80, 0x6f]).write(to: url)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let unavailable = try XCTUnwrap(notes.first)
        let index = SearchIndex()

        guard case .unavailable = unavailable.availability else {
            return XCTFail("Invalid UTF-8 should be represented as unavailable content")
        }
        let unavailableResults = await index.search(notes: [unavailable], query: "recoveredbodyterm")
        XCTAssertTrue(unavailableResults.isEmpty)

        try Data("recoveredbodyterm is available now".utf8).write(to: url)
        let retryMessage = try await store.retryAvailability(unavailable.id, collectionToken: collectionToken)
        let refreshed = try await store.read(unavailable.id, collectionToken: collectionToken)

        XCTAssertEqual(retryMessage, "Content available.")
        XCTAssertEqual(refreshed.availability, .available)
        let refreshedResults = await index.search(notes: [refreshed], query: "recoveredbodyterm")
        XCTAssertEqual(refreshedResults.map(\.note.id), [unavailable.id])
    }

    func testDirtyRecoverySearchTrashAndStableDiscoveryMetadata() async throws {
        let fixture = try TestFixture()
        let trashRoot = fixture.root.appendingPathComponent("SyntheticTrash", isDirectory: true)
        let trashService = TrashService(move: { url in
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let target = trashRoot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, trashService: trashService)
        let folder = await store.defaultFolder()
        let originalURL = folder.appendingPathComponent("Existing.txt")
        let peerURL = folder.appendingPathComponent("Peer.txt")
        try Data("baseline focusorderterm".utf8).write(to: originalURL)
        try Data("peer focusorderterm".utf8).write(to: peerURL)
        let collectionToken = CollectionToken()
        let discovered = try await store.discover(in: folder, collectionToken: collectionToken)
        let original = try XCTUnwrap(discovered.first { $0.fileURL == originalURL })
        let peer = try XCTUnwrap(discovered.first { $0.fileURL == peerURL })
        let index = SearchIndex()

        let savedPeerEdit = EditSnapshot(
            id: peer.id,
            collectionToken: collectionToken,
            revision: EditRevision(rawValue: 1),
            baseRevision: peer.fileRevision,
            text: "saved peer focusorderterm"
        )
        _ = await store.submit(savedPeerEdit)
        try await store.flush()
        let savedPeer = try await store.read(peer.id, collectionToken: collectionToken)
        XCTAssertEqual(savedPeer.fileURL.lastPathComponent, peerURL.lastPathComponent)
        XCTAssertEqual(savedPeer.text, savedPeerEdit.text)

        let newerDate = Date(timeIntervalSince1970: 2_000_000_000)
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: originalURL.path)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: peerURL.path)
        let orderSnapshots = try await store.discover(in: folder, collectionToken: collectionToken)
        let orderBeforeFocus = await index.search(notes: orderSnapshots, query: "focusorderterm")
        XCTAssertEqual(orderBeforeFocus.map(\.note.id), [original.id, peer.id])

        let focusedPeer = try await store.read(peer.id, collectionToken: collectionToken)
        XCTAssertEqual(focusedPeer.fileRevision?.modifiedAt, olderDate)
        let snapshotsAfterFocus = orderSnapshots.map { $0.id == peer.id ? focusedPeer : $0 }
        let orderAfterFocus = await index.search(notes: snapshotsAfterFocus, query: "focusorderterm")
        XCTAssertEqual(orderAfterFocus.map(\.note.id), orderBeforeFocus.map(\.note.id))

        let dirtyEdit = EditSnapshot(
            id: original.id,
            collectionToken: collectionToken,
            revision: EditRevision(rawValue: 1),
            baseRevision: original.fileRevision,
            text: "unsavedrecoveryterm local draft"
        )
        let dirtySnapshot = NoteSnapshot(
            id: original.id,
            collectionToken: collectionToken,
            fileURL: original.fileURL,
            fileRevision: original.fileRevision,
            text: dirtyEdit.text,
            availability: .available,
            editRevision: dirtyEdit.revision
        )
        let unsavedResults = await index.search(notes: [dirtySnapshot, savedPeer], query: "unsavedrecoveryterm")
        XCTAssertEqual(unsavedResults.map(\.note.id), [original.id])

        _ = await store.submit(dirtyEdit)
        try Data("external replacement".utf8).write(to: originalURL)
        try await store.flush()
        try await store.reconcile(collectionToken: collectionToken)
        let afterConflict = try await store.discover(in: folder, collectionToken: collectionToken)
        let recoveryResults = await index.search(notes: afterConflict, query: "unsavedrecoveryterm")
        XCTAssertEqual(recoveryResults.count, 1)
        let recovery = try XCTUnwrap(recoveryResults.first?.note)
        XCTAssertTrue(recovery.fileURL.lastPathComponent.hasPrefix("rn-"))
        XCTAssertEqual(recovery.text, dirtyEdit.text)
        let recoveryFilename = recovery.fileURL.lastPathComponent

        try await store.moveToTrash(recovery.id, collectionToken: collectionToken)
        let afterTrash = try await store.discover(in: folder, collectionToken: collectionToken)
        let trashedResults = await index.search(notes: afterTrash, query: "unsavedrecoveryterm")
        XCTAssertTrue(trashedResults.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.fileURL.path))
        let removedRecovery = await store.records[recovery.id]
        XCTAssertNil(removedRecovery)
    }

    func testSearchFindsTermInOneMegabyteNoteAmongThousandNotes() async throws {
        let notes = (0..<1_000).map { number in
            snapshot(
                filename: "Note-\(number).txt",
                text: "A searchable note body with ordinary content \(number)."
            )
        }
        let stressNote = snapshot(
            filename: "Stress.txt",
            text: String(repeating: "x", count: 1_000_000) + " targetterm"
        )
        let index = SearchIndex()
        let results = await index.search(notes: notes + [stressNote], query: "targetterm")

        XCTAssertEqual(results.map(\.note.id), [stressNote.id])
    }

    func testSearchCorpusPerformance() {
        let notes = (0..<1_000).map { number in
            snapshot(
                filename: "Note-\(number).txt",
                text: "A searchable note body with ordinary content \(number)."
            )
        }
        let stressNote = snapshot(
            filename: "Stress.txt",
            text: String(repeating: "x", count: 1_000_000) + " targetterm"
        )
        measure(metrics: [XCTClockMetric()]) {
            let completed = expectation(description: "Search finishes")
            Task {
                let index = SearchIndex()
                let results = await index.search(notes: notes + [stressNote], query: "targetterm")
                XCTAssertEqual(results.map(\.note.id), [stressNote.id])
                completed.fulfill()
            }
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
        }
    }
}

private func snapshot(filename: String, text: String) -> NoteSnapshot {
    NoteSnapshot(
        id: NoteID(),
        collectionToken: CollectionToken(),
        fileURL: URL(fileURLWithPath: "/notes/" + filename),
        fileRevision: FileRevision(fingerprint: "test", modifiedAt: .distantPast),
        text: text,
        availability: .available
    )
}
