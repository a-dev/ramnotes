import ramnotesDomain
import XCTest
import Darwin
@testable import ramnotes

final class StorageTests: XCTestCase {
    func testCloudDownloadRequestFailureRemainsPlaceholderAndRetryReadsExactBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data([0xef, 0xbb, 0xbf] + Array("hello\r\nworld".utf8))
        try bytes.write(to: url)
        let requestError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
            userInfo: [NSLocalizedDescriptionKey: "Network is unavailable"])

        XCTAssertThrowsError(try StorageFiles.read(url, readBody: { _ in
            XCTFail("A placeholder read must wait for the requested download")
            return bytes
        }, startDownload: { _ in }, isPlaceholder: { _ in true })) { error in
            guard case let .accessFailure(access) = error as? NoteOperationError else {
                return XCTFail("Expected a placeholder access failure")
            }
            XCTAssertEqual(access.reason, .cloudPlaceholder)
            XCTAssertEqual(String(localized: access.message), "iCloud download requested…")
        }

        XCTAssertThrowsError(try StorageFiles.read(url, readBody: { _ in
            XCTFail("Placeholder bytes must never be read")
            return bytes
        }, startDownload: { _ in throw requestError }, isPlaceholder: { _ in true })) { error in
            guard case let .accessFailure(access) = error as? NoteOperationError else {
                return XCTFail("Expected a placeholder access failure")
            }
            XCTAssertEqual(access.reason, .cloudPlaceholder)
            XCTAssertEqual(access.domain, requestError.domain)
            XCTAssertEqual(access.code, requestError.code)
            XCTAssertTrue(String(localized: access.message).contains("Network is unavailable"))
            XCTAssertTrue(String(localized: access.message).contains("Open the note again to retry"))
        }

        let read = try StorageFiles.read(url, readBody: { _ in bytes }, isPlaceholder: { _ in false })
        XCTAssertEqual(read.text, "hello\r\nworld")
        XCTAssertEqual(read.revision.fingerprint, StorageFiles.digest(bytes))
    }

    func testIdentityResolutionRejectsDuplicateResourcesAndPersistedCandidates() throws {
        let id = NoteID()
        let a = URL(fileURLWithPath: "/notes/A.txt")
        let b = URL(fileURLWithPath: "/notes/B.txt")
        let old = NoteLocationRecord(id: id, resource: "resource", path: a.path)
        let links = try IdentityResolution.resolve([
            .init(url: a, resource: "resource"), .init(url: b, resource: "resource")
        ], previous: [old])
        XCTAssertFalse(links.contains { $0.id == id })
        XCTAssertEqual(Set(links.map(\.id)).count, 2)
        let duplicateCandidateID = NoteID()
        let duplicate = try IdentityResolution.resolve([.init(url: a, resource: "resource")],
            previous: [old, .init(id: duplicateCandidateID, resource: "resource", path: b.path)])
        XCTAssertEqual(duplicate.count, 1)
        let duplicateResult = try XCTUnwrap(duplicate.first)
        XCTAssertFalse([id, duplicateCandidateID].contains(duplicateResult.id))
        let replacementCandidateID = NoteID()
        let replacement = try IdentityResolution.resolve([.init(url: a, resource: "replacement")],
            previous: [old, .init(id: replacementCandidateID, resource: "resource", path: b.path)])
        XCTAssertEqual(replacement.count, 1)
        let replacementResult = try XCTUnwrap(replacement.first)
        // Two stored candidates share this resource identity. The path alone cannot identify the note.
        XCTAssertFalse([id, replacementCandidateID].contains(replacementResult.id))
    }

    func testHardLinkedFilesNeverClaimOriginalIdentity() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let a = folder.appendingPathComponent("A.txt")
        let b = folder.appendingPathComponent("B.txt")
        try Data("shared".utf8).write(to: a)
        let collectionToken = CollectionToken()
        let original = try await store.discover(in: folder, collectionToken: collectionToken)
        let id = try XCTUnwrap(original.first?.id)
        try FileManager.default.linkItem(at: a, to: b)
        let linked = try await store.discover(in: folder, collectionToken: collectionToken)
        XCTAssertEqual(linked.count, 2)
        XCTAssertFalse(linked.contains { $0.id == id })
        XCTAssertEqual(Set(linked.map(\.id)).count, 2)
    }

    func testMissingResourceUsesOnlyUniquePathContinuity() throws {
        let a = URL(fileURLWithPath: "/notes/A.txt")
        let id = NoteID()
        let old = NoteLocationRecord(id: id, resource: nil, path: a.path)
        let resolved = try IdentityResolution.resolve([.init(url: a, resource: nil)], previous: [old])
        XCTAssertEqual(resolved.first?.id, id)
        let duplicateCandidateID = NoteID()
        let duplicate = try IdentityResolution.resolve([.init(url: a, resource: nil)],
            previous: [old, .init(id: duplicateCandidateID, resource: nil, path: a.path)])
        XCTAssertEqual(duplicate.count, 1)
        let duplicateResult = try XCTUnwrap(duplicate.first)
        XCTAssertFalse([id, duplicateCandidateID].contains(duplicateResult.id))
    }

    func testPreparatoryDiscoveryDoesNotLoadBodiesOrConsumeRenameAndReplacementEvents() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let a = folder.appendingPathComponent("A.txt")
        let b = folder.appendingPathComponent("B.txt")
        try Data("original".utf8).write(to: a)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let original = try XCTUnwrap(notes.first)
        let identityURL = fixture.root.appendingPathComponent("collection.json")
        let before = try Data(contentsOf: identityURL)
        try FileManager.default.moveItem(at: a, to: b)
        try Data([0xff]).write(to: a)
        let lookup = try await store.discoverIdentities(in: folder)
        XCTAssertEqual(lookup.mapping.first { $0.path == b.path }?.id, original.id)
        XCTAssertNotEqual(lookup.mapping.first { $0.path == a.path }?.id, original.id)
        XCTAssertEqual(try Data(contentsOf: identityURL), before)
        let stream = await store.events()
        try await store.reconcile(collectionToken: collectionToken)
        await store.emit(.failed(nil, .cancelled))
        var changed: NoteSnapshot?
        var added: NoteSnapshot?
        for await event in stream {
            if case .failed(nil, .cancelled) = event { break }
            if case .changed(let note) = event { changed = note }
            if case .discovered(let note) = event { added = note }
        }
        XCTAssertEqual(changed?.id, original.id)
        XCTAssertEqual(changed?.fileURL, b)
        XCTAssertEqual(added?.fileURL, a)
        XCTAssertNotEqual(added?.availability, .available)
    }

    func testInterruptedLoadingLeavesMappingsAndRecordsUnchanged() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        try Data("original".utf8).write(to: folder.appendingPathComponent("A.txt"))
        let collectionToken = CollectionToken()
        let original = try await store.discover(in: folder, collectionToken: collectionToken)
        let identityURL = fixture.root.appendingPathComponent("collection.json")
        let before = try Data(contentsOf: identityURL)
        try Data("new".utf8).write(to: folder.appendingPathComponent("B.txt"))
        let task = Task {
            try await store.scan(in: folder, collectionToken: collectionToken, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: identityURL), before)
        let records = await store.records
        XCTAssertEqual(Set(records.keys), Set(original.map(\.id)))
    }

    func testMissingDefaultFolderIsDistinctFromMissingNote() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let token = CollectionToken()
        let note = try await store.create(in: folder, collectionToken: token)
        try FileManager.default.removeItem(at: note.fileURL)
        let noteMissing = try await store.isDefaultFolderMissing(collectionToken: token)
        XCTAssertFalse(noteMissing)
        try FileManager.default.removeItem(at: folder)
        let folderMissing = try await store.isDefaultFolderMissing(collectionToken: token)
        XCTAssertTrue(folderMissing)
    }

    func testMissingDefaultFolderWithDeletedParent() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let parent = fixture.root.appendingPathComponent("Parent", isDirectory: true)
        let folder = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = CollectionToken()
        _ = try await store.discover(in: folder, collectionToken: token)
        try FileManager.default.removeItem(at: parent)
        let missing = try await store.isDefaultFolderMissing(collectionToken: token)
        XCTAssertTrue(missing)
    }

    func testCreateNoteWhenExistingNoteFileIsMissing() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let token = CollectionToken()
        let original = try await store.create(in: folder, collectionToken: token)
        try FileManager.default.removeItem(at: original.fileURL)
        _ = try await store.read(original.id, collectionToken: token)

        let created = try await store.create(in: folder, collectionToken: token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.fileURL.path))
        XCTAssertNotEqual(created.id, original.id)
    }

    func testCreateRegistersNewNoteWithoutScanningFolder() async throws {
        let fixture = try TestFixture()
        let reads = BodyReads()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, readBody: reads.read)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Existing.txt")
        try Data("original".utf8).write(to: url)
        let collectionToken = CollectionToken()
        let original = try await store.discover(in: folder, collectionToken: collectionToken)
        let id = try XCTUnwrap(original.first?.id)
        let stream = await store.events()
        try Data("external".utf8).write(to: url)
        let passes = await store.reconcileCount
        reads.reset()

        let created = try await store.create(in: folder, collectionToken: collectionToken)
        await store.emit(.failed(nil, .cancelled))
        var discovered: NoteSnapshot?
        for await event in stream {
            if case .failed(nil, .cancelled) = event { break }
            if case let .discovered(note) = event { discovered = note }
        }
        let afterPasses = await store.reconcileCount
        XCTAssertEqual(afterPasses, passes, "New Note must not reconcile the folder.")
        XCTAssertEqual(reads.urls, [created.fileURL], "Only the new file may be read.")
        XCTAssertEqual(discovered, created)
        let existing = await store.records[id]
        XCTAssertEqual(existing?.text, "original", "External changes wait for their own event.")

        // The adopted identity is saved. A later scan keeps it and still reports the external change.
        try await store.reconcile(collectionToken: collectionToken)
        let records = await store.records
        XCTAssertEqual(records[created.id]?.fileURL, created.fileURL)
        XCTAssertEqual(records[id]?.text, "external")
        XCTAssertEqual(records.count, 2)
    }

    func testDiscoverEmptyFolderReturnsNoNotes() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let notes = try await store.discover(in: folder, collectionToken: CollectionToken())

        XCTAssertTrue(notes.isEmpty)
    }

    func testDiscoverReadsUnicodeUppercaseExtensionAndEmptyNoteTitle() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let blankURL = folder.appendingPathComponent("Blank.txt")
        let unicodeURL = folder.appendingPathComponent("Été.TXT")
        try Data().write(to: blankURL)
        try Data("  \nこんにちは 🌿\nbody".utf8).write(to: unicodeURL)

        let notes = try await store.discover(in: folder, collectionToken: CollectionToken())
        let byFilename = Dictionary(uniqueKeysWithValues: notes.map { ($0.fileURL.lastPathComponent, $0) })

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(byFilename["Blank.txt"]?.text, "")
        XCTAssertEqual(byFilename["Blank.txt"]?.title, "Blank")
        XCTAssertEqual(byFilename["Été.TXT"]?.text, "  \nこんにちは 🌿\nbody")
        XCTAssertEqual(byFilename["Été.TXT"]?.title, "こんにちは 🌿")
        XCTAssertEqual(byFilename["Été.TXT"]?.availability, .available)
    }

    func testInvalidUTF8IsUnavailableWithEmptyText() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Invalid.txt")
        let invalidBytes = Data([0xff, 0xfe, 0xfd])
        try invalidBytes.write(to: url)

        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)
        let read = try await store.read(note.id, collectionToken: collectionToken)

        XCTAssertEqual(note.availability, read.availability)
        XCTAssertNotEqual(note.availability, .available)
        XCTAssertEqual(note.text, "")
        XCTAssertEqual(read.text, "")
        XCTAssertNil(note.fileRevision)
        XCTAssertEqual(try Data(contentsOf: url), invalidBytes)
    }

    func testDiscoverSkipsNestedMarkdownAndSymbolicLinks() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("Nested.txt"))
        try Data("markdown".utf8).write(to: folder.appendingPathComponent("Readme.md"))
        let target = folder.appendingPathComponent("Target.txt")
        try Data("target".utf8).write(to: target)
        let link = folder.appendingPathComponent("Link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let notes = try await store.discover(in: folder, collectionToken: CollectionToken())

        XCTAssertEqual(notes.map { $0.fileURL.lastPathComponent }, ["Target.txt"])
    }

    func testCreateRetriesOccupiedShortNameWithoutOverwriting() async throws {
        let fixture = try TestFixture()
        let entropy = FilenameEntropySequence()
        let generator = NoteFilenameGenerator(randomIndex: { _ in entropy.next() })
        let occupiedName = "rn-acid-acid-acid.txt"
        let firstName = "rn-acorn-acorn-acorn.txt"
        let secondName = "rn-acre-acre-acre.txt"
        let store = try NoteStore(support: fixture.root, clock: fixture.clock, filenameGenerator: generator)
        let folder = await store.defaultFolder()
        let expectedFirst = folder.appendingPathComponent(occupiedName)
        try Data("collision".utf8).write(to: expectedFirst)
        let collectionToken = CollectionToken()

        let first = try await store.create(in: folder, collectionToken: collectionToken)
        let second = try await store.create(in: folder, collectionToken: collectionToken)

        XCTAssertEqual(first.fileURL.lastPathComponent, firstName)
        XCTAssertEqual(second.fileURL.lastPathComponent, secondName)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.text, "")
        XCTAssertEqual(second.text, "")
        XCTAssertEqual(try Data(contentsOf: expectedFirst), Data("collision".utf8))
    }

    func testRenameAndStoreRestartPreserveNoteIdentity() async throws {
        let fixture = try TestFixture()
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        let originalURL = folder.appendingPathComponent("Original.txt")
        let renamedURL = folder.appendingPathComponent("Renamed.txt")
        let collectionToken = CollectionToken()
        let firstStore = try NoteStore(support: fixture.root, clock: fixture.clock)
        try Data("Stable identity".utf8).write(to: originalURL)
        let originalNotes = try await firstStore.discover(in: folder, collectionToken: collectionToken)
        let original = try XCTUnwrap(originalNotes.first)
        try FileManager.default.moveItem(at: originalURL, to: renamedURL)

        let restartedStore = try NoteStore(support: fixture.root, clock: fixture.clock)
        let restartedNotes = try await restartedStore.discover(in: folder, collectionToken: collectionToken)
        let afterRestart = try XCTUnwrap(restartedNotes.first)
        let read = try await restartedStore.read(original.id, collectionToken: collectionToken)

        XCTAssertEqual(afterRestart.id, original.id)
        XCTAssertEqual(afterRestart.fileURL, renamedURL)
        XCTAssertEqual(read.id, original.id)
        XCTAssertEqual(read.text, "Stable identity")
    }

    func testKnownPathAtomicReplacementPreservesIdentityAndReadsNewContents() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Replace.txt")
        try Data("before".utf8).write(to: url)
        let collectionToken = CollectionToken()
        let originalNotes = try await store.discover(in: folder, collectionToken: collectionToken)
        let original = try XCTUnwrap(originalNotes.first)
        let oldResource = try StorageFiles.resourceID(url)

        let temporaryURL = folder.appendingPathComponent("Replacement.tmp")
        try Data("after".utf8).write(to: temporaryURL)
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let newResource = try StorageFiles.resourceID(URL(fileURLWithPath: url.path))
        XCTAssertNotEqual(oldResource, newResource, "Atomic replacement should create a new file resource")

        let replacementNotes = try await store.discover(in: folder, collectionToken: collectionToken)
        let replacement = try XCTUnwrap(replacementNotes.first)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.text, "after")
    }

    func testUnreadableFileIsUnavailableWhenPermissionsAreEnforced() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Unreadable.txt")
        try Data("restricted".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        guard (try? Data(contentsOf: url)) == nil else {
            throw XCTSkip("The current test process can still read a mode-000 file; permission enforcement cannot be verified here.")
        }

        let notes = try await store.discover(in: folder, collectionToken: CollectionToken())
        let note = try XCTUnwrap(notes.first)
        XCTAssertNotEqual(note.availability, .available)
        XCTAssertEqual(note.text, "")
    }
}

extension StorageTests {
    func testUnsupportedCompleteCatalogVersionIsRejectedWithoutReplacingFile() throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("collection.json")
        let fixtureJSON = #"""
        {
          "version": 999,
          "defaultFolder": null,
          "notes": [],
          "operations": [],
          "recoveryLinks": [],
          "defaultDecision": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "defaultBatches": []
        }
        """#
        let bytes = Data(fixtureJSON.utf8)
        try bytes.write(to: url)

        XCTAssertThrowsError(try CatalogPersistence.load(at: url))
        XCTAssertThrowsError(try CatalogPersistence.save(CollectionCatalog(), at: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPreMigrationJournalRetainsTextIdentityAndPendingPromotion() throws {
        let fixture = try TestFixture()
        let root = fixture.root.appendingPathComponent("LegacyRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Version-one bytes generated from the 1701cde record schema, independently of current encoding.
        let bytes = Data(#"""
        {"payload":"eyJjb2xsZWN0aW9uVG9rZW4iOnsicmF3VmFsdWUiOiJBQUFBQUFBQS1CQkJCLTRDQ0MtOERERC1FRUVFRUVFRUVFRUUifSwibm90ZUlEIjp7InJhd1ZhbHVlIjoiMTExMTExMTEtMjIyMi00MzMzLTg0NDQtNTU1NTU1NTU1NTU1In0sImJhc2VSZXZpc2lvbiI6eyJtb2RpZmllZEF0Ijo3MjE2OTI4MDAsImZpbmdlcnByaW50IjoiMDEyMzQ1Njc4OWFiY2RlZiJ9LCJmb2xkZXJJZGVudGl0eSI6InZvbHVtZTpmb2xkZXItNDIiLCJ0cmFja2luZ1JlbW92ZWQiOmZhbHNlLCJlZGl0UmV2aXNpb24iOnsicmF3VmFsdWUiOjl9LCJvcmlnaW5hbFVSTCI6ImZpbGU6XC9cL1wvVXNlcnNcL2FuZHJlaVwvTm90ZXNcL2xlZ2FjeS50eHQiLCJwcm9tb3Rpb25VUkwiOiJmaWxlOlwvXC9cL1VzZXJzXC9hbmRyZWlcL1JlY292ZXJ5XC9sZWdhY3ktcmVjb3ZlcmVkLnR4dCIsInByb21vdGlvblBhcmVudFJlc291cmNlIjoidm9sdW1lOmRlc3RpbmF0aW9uLWZvbGRlciIsInJlYXNvbiI6InNhdmVGYWlsdXJlIiwidGV4dCI6IkxlZ2FjeSBwZW5kaW5nIHRleHRcbndpdGggVW5pY29kZTogY2Fmw6kg8J+MvyIsImlkIjoiOTk5OTk5OTktODg4OC00Nzc3LTg2NjYtNTU1NTU1NTU1NTU1IiwicHJvbW90aW9uQWNjZXNzIjp7InNjb3BlIjoiZm9sZGVyIiwidXJsIjoiZmlsZTpcL1wvXC9Vc2Vyc1wvYW5kcmVpXC9SZWNvdmVyeSIsImJvb2ttYXJrIjoiQVFJRCJ9LCJvcmlnaW5hbFJlc291cmNlSWRlbnRpdHkiOiJ2b2x1bWU6ZmlsZS03IiwiY3JlYXRlZEF0Ijo3MjE2OTI5MjN9","checksum":"9dccba182ecc79623f902f07aef548cce3be523d66a041654caf1d980195c7a8","version":1}
        """#.utf8)
        let id = NoteID(UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
        let store = RecoveryStore(root: root, fault: { _ in })
        try bytes.write(to: store.url(id))

        let reopened = store.load()
        XCTAssertTrue(reopened.diagnostics.isEmpty)
        let record = try XCTUnwrap(reopened.records.first)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(record.noteID, id)
        XCTAssertEqual(record.collectionToken.rawValue, UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        XCTAssertEqual(record.editRevision, EditRevision(rawValue: 9))
        XCTAssertEqual(record.text, "Legacy pending text\nwith Unicode: café 🌿")
        XCTAssertEqual(record.originalResourceIdentity, "volume:file-7")
        XCTAssertEqual(record.promotionURL?.lastPathComponent, "legacy-recovered.txt")
        XCTAssertEqual(record.promotionAccess?.bookmark, Data([1, 2, 3]))
        XCTAssertEqual(record.promotionParentResource, "volume:destination-folder")
        XCTAssertNil(record.promotionResource)
        XCTAssertNil(record.promotedNoteID)
        XCTAssertEqual(RecoveryPolicy.replay(record, folderAvailable: false,
            activeFolderIdentity: nil, trackedParent: nil, tracked: false), .retain)
        XCTAssertEqual(try Data(contentsOf: store.url(id)), bytes)

        // A current writer can checkpoint and reopen the old record without losing its retry evidence.
        try store.persist(record)
        XCTAssertEqual(store.load().records, [record])
        XCTAssertTrue(store.load().diagnostics.isEmpty)
    }

    func testVersionOneCatalogFixtureLoadsAndPreservesNoteIdentity() throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("collection.json")
        let noteID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let fixtureJSON = #"""
        {
          "version": 1,
          "defaultFolder": null,
          "notes": [
            {"rawValue":"11111111-2222-3333-4444-555555555555"},
            {"id":{"rawValue":"11111111-2222-3333-4444-555555555555"},"resource":"file-resource-1","path":"/notes/Original.txt","availability":{"available":{}},"revision":{"rawValue":4}}
          ],
          "operations": [],
          "recoveryLinks": [],
          "defaultDecision":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "defaultBatches": []
        }
        """#
        try Data(fixtureJSON.utf8).write(to: url)

        let catalog = try CatalogPersistence.load(at: url)
        let id = NoteID(noteID)
        let note = try XCTUnwrap(catalog.notes[id])
        XCTAssertEqual(note.id, id)
        XCTAssertEqual(note.resource, "file-resource-1")
        XCTAssertEqual(note.path, "/notes/Original.txt")
        XCTAssertNil(note.parentResource)
        XCTAssertNil(note.access)
        XCTAssertNil(note.fileAccess)
        XCTAssertEqual(note.availability, .available)
        XCTAssertEqual(note.revision.rawValue, 4)

        try CatalogPersistence.save(catalog, at: url)
        let reloaded = try CatalogPersistence.load(at: url)
        XCTAssertEqual(reloaded, catalog)
        XCTAssertEqual(reloaded.notes[id]?.id, id)
        XCTAssertEqual(reloaded.notes[id]?.resource, "file-resource-1")
    }

    func testCatalogIgnoresUnknownFieldsAndMissingFileLoadsEmpty() throws {
        let fixture = try TestFixture()
        let missingURL = fixture.root.appendingPathComponent("missing-collection.json")
        let missingCatalog = try CatalogPersistence.load(at: missingURL)
        XCTAssertEqual(missingCatalog.version, 1)
        XCTAssertNil(missingCatalog.defaultFolder)
        XCTAssertTrue(missingCatalog.notes.isEmpty)
        XCTAssertTrue(missingCatalog.operations.isEmpty)
        XCTAssertTrue(missingCatalog.recoveryLinks.isEmpty)
        XCTAssertTrue(missingCatalog.defaultBatches.isEmpty)

        let url = fixture.root.appendingPathComponent("collection.json")
        let fixtureJSON = #"""
        {"version":1,"defaultFolder":null,"notes":[],"operations":[],"recoveryLinks":[],
         "defaultDecision":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","defaultBatches":[],
         "futureField":{"ignored":true}}
        """#
        try Data(fixtureJSON.utf8).write(to: url)
        XCTAssertEqual(try CatalogPersistence.load(at: url).version, 1)
    }

    func testCatalogSaveAfterStartupCorruptionPreservesCorruptFile() throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("collection.json")
        let id = NoteID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let record = NoteLocationRecord(id: id, resource: "resource", path: "/notes/Note.txt")
        let catalog = CollectionCatalog(notes: [id: record])
        try CatalogPersistence.save(catalog, at: url)
        XCTAssertEqual(try CatalogPersistence.load(at: url), catalog)

        let corruptBytes = Data(#"{"version":999,"notes":[]}"#.utf8)
        try corruptBytes.write(to: url)
        XCTAssertThrowsError(try CatalogPersistence.save(catalog, at: url))
        XCTAssertEqual(try Data(contentsOf: url), corruptBytes)
    }

    func testCollectionRestartPreservesIdentityAndMetadataAcrossThreeParents() async throws {
        let fixture = try TestFixture()
        let metadata = MetadataStore(root: fixture.root)
        var appearance = CollectionMetadata()
        var expected: [URL: NoteID] = [:]
        for name in ["First", "Second", "Third"] {
            let parent = fixture.root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let file = parent.appendingPathComponent("arbitrary.txt")
            try Data("same contents".utf8).write(to: file)
            let store = try NoteStore(support: fixture.root)
            let notes = try await store.discover(in: parent, collectionToken: CollectionToken())
            let note = try XCTUnwrap(notes.first)
            expected[parent] = note.id
            appearance.notes[note.id] = NoteWindowMetadata(isOpen: true, frame: CGRect(x: 10, y: 20, width: 400, height: 300),
                focusOrder: UInt64(expected.count), lastKnownPath: file.path, fontSize: 23, backgroundTone: .purple)
        }
        try await metadata.saveCollection(appearance)
        let restartedMetadata = await MetadataStore(root: fixture.root).loadCollection()
        XCTAssertNil(restartedMetadata.diagnostic)
        XCTAssertEqual(restartedMetadata.value, appearance)
        XCTAssertEqual(Set(expected.values).count, 3, "Equal contents and filenames never define identity")
        for (parent, id) in expected {
            let restarted = try NoteStore(support: fixture.root)
            let notes = try await restarted.discover(in: parent, collectionToken: CollectionToken())
            XCTAssertEqual(notes.first?.id, id)
        }
        let catalog = try CatalogPersistence.load(at: fixture.root.appendingPathComponent("collection.json"))
        XCTAssertEqual(Set(catalog.notes.keys), Set(expected.values))
    }

    func testGlobalIdentityFollowsResourceAcrossParentsAndKeepsLocationState() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root)
        let source = await store.defaultFolder()
        let destination = fixture.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("any name.txt")
        try Data("unchanged".utf8).write(to: original)
        let notes = try await store.discover(in: source, collectionToken: CollectionToken())
        let id = try XCTUnwrap(notes.first?.id)
        let moved = destination.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        let restarted = try NoteStore(support: fixture.root)
        let found = try await restarted.discover(in: destination, collectionToken: CollectionToken())
        XCTAssertEqual(found.first?.id, id)
        let catalog = try CatalogPersistence.load(at: fixture.root.appendingPathComponent("collection.json"))
        XCTAssertEqual(catalog.notes[id]?.path, moved.path)
        XCTAssertEqual(catalog.notes[id]?.revision.rawValue, 1)
    }

    func testMalformedCatalogBlocksStartupAndReplacementWithoutChangingFiles() async throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("personal.txt")
        try Data("preserve me".utf8).write(to: file)
        let url = fixture.root.appendingPathComponent("collection.json")
        for bytes in [Data("broken".utf8), Data(#"{"version":999,"notes":[],"operations":[]}"#.utf8)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try NoteStore(support: fixture.root))
            XCTAssertThrowsError(try CatalogPersistence.save(CollectionCatalog(), at: url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserve me")
        }
        let metadataURL = fixture.root.appendingPathComponent("collection-metadata.json")
        let bytes = Data("broken metadata".utf8)
        try bytes.write(to: metadataURL)
        let metadata = MetadataStore(root: fixture.root)
        let loaded = await metadata.loadCollection()
        XCTAssertNotNil(loaded.diagnostic)
        do { try await metadata.saveCollection(CollectionMetadata()); XCTFail("Must preserve corrupt metadata") } catch { }
        XCTAssertEqual(try Data(contentsOf: metadataURL), bytes)
    }

    func testInterruptedOperationAndAccessDescriptorsRoundTrip() throws {
        let fixture = try TestFixture()
        let url = fixture.root.appendingPathComponent("collection.json")
        let id = NoteID()
        let access = NoteAccessDescriptor(url: fixture.root, bookmark: Data([1, 2, 3]), scope: .folder)
        let location = NoteLocationRecord(id: id, resource: "verified-resource", path: fixture.root.appendingPathComponent("note-0001.txt").path,
            access: access, availability: .unavailable(reason: "Disconnected"), revision: .init(rawValue: 12))
        for stage in LocationOperation.Stage.allCases {
            let operation = LocationOperation(id: UUID(), noteID: id, source: location, destination: access,
                expectedEditRevision: .init(rawValue: 7), stage: stage)
            let catalog = CollectionCatalog(defaultFolder: access, notes: [id: location], operations: [operation.id: operation])
            try CatalogPersistence.save(catalog, at: url)
            XCTAssertEqual(try CatalogPersistence.load(at: url), catalog)
        }
        var invalid = CollectionCatalog(notes: [NoteID(): location])
        XCTAssertThrowsError(try CatalogPersistence.save(invalid, at: url))
        invalid = CollectionCatalog(notes: [id: location, NoteID(): location])
        XCTAssertThrowsError(try CatalogPersistence.save(invalid, at: url))
    }

    func testIncompleteLegacyLocationOperationIsPreservedAndDiagnosedOnReconcile() async throws {
        let fixture = try TestFixture()
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceURL = folder.appendingPathComponent("Original.txt")
        let originalBytes = Data("keep original".utf8)
        try originalBytes.write(to: sourceURL)

        let access = NoteAccessDescriptor(url: folder, bookmark: nil, scope: .appContainer)
        let noteID = NoteID()
        let source = NoteLocationRecord(id: noteID, resource: "legacy-source-resource", path: sourceURL.path,
            parentResource: "legacy-parent-resource", access: access)
        let operation = LocationOperation(id: UUID(), noteID: noteID, source: source, destination: access,
            expectedEditRevision: .init(rawValue: 1), stage: .prepared,
            expectedFileRevision: FileRevision(fingerprint: "legacy-fingerprint", modifiedAt: .distantPast),
            destinationParentResource: "legacy-destination-parent", destinationName: "Moved.txt")
        let catalogURL = fixture.root.appendingPathComponent("collection.json")
        let encoded = try JSONEncoder().encode(CollectionCatalog(defaultFolder: access,
            notes: [noteID: source], operations: [operation.id: operation]))
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        if var operations = legacyJSON["operations"] as? [String: [String: Any]] {
            var legacyOperation = try XCTUnwrap(operations[operation.id.uuidString])
            legacyOperation.removeValue(forKey: "expectedFileRevision")
            legacyOperation.removeValue(forKey: "destinationParentResource")
            legacyOperation.removeValue(forKey: "destinationName")
            operations[operation.id.uuidString] = legacyOperation
            legacyJSON["operations"] = operations
        } else {
            // Codable uses alternating key/value array representation for UUID-keyed dictionaries.
            var entries = try XCTUnwrap(legacyJSON["operations"] as? [Any])
            guard let index = stride(from: 0, to: entries.count, by: 2).first(where: {
                (entries[$0] as? String) == operation.id.uuidString
            }), var legacyOperation = entries[index + 1] as? [String: Any] else {
                return XCTFail("Could not locate the UUID-keyed legacy operation")
            }
            legacyOperation.removeValue(forKey: "expectedFileRevision")
            legacyOperation.removeValue(forKey: "destinationParentResource")
            legacyOperation.removeValue(forKey: "destinationName")
            entries[index + 1] = legacyOperation
            legacyJSON["operations"] = entries
        }
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyJSON, options: [.sortedKeys])
        try legacyBytes.write(to: catalogURL)

        let decoded = try CatalogPersistence.load(at: catalogURL)
        XCTAssertEqual(decoded.operations[operation.id]?.expectedFileRevision, nil)
        XCTAssertEqual(decoded.operations[operation.id]?.destinationParentResource, nil)
        XCTAssertEqual(decoded.operations[operation.id]?.destinationName, nil)

        let restarted = try NoteStore(support: fixture.root, clock: fixture.clock)
        let selection = try await restarted.openSelectedFolder()
        XCTAssertTrue(selection.recoveryDiagnostics.contains { $0.contains("lacks verified identity or revision evidence") })
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Moved.txt").path))
        let preserved = try CatalogPersistence.load(at: catalogURL)
        XCTAssertEqual(preserved.operations[operation.id], decoded.operations[operation.id])
    }

    func testLoadPrunesJournalsOfUnregisteredNotesAndKeepsRetainedRecovery() async throws {
        let fixture = try TestFixture()
        let first = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await first.defaultFolder()
        try Data("kept".utf8).write(to: folder.appendingPathComponent("Note.txt"))
        let selection = try await first.openSelectedFolder()
        let token = selection.collectionToken

        let recoveryRoot = fixture.root.appendingPathComponent("Recovery")
        let journals = RecoveryStore(root: recoveryRoot, fault: { _ in })
        func record(_ id: NoteID, removed: Bool) -> RecoveryRecord {
            var record = RecoveryRecord(id: UUID(), noteID: id, collectionToken: token,
                originalURL: folder.appendingPathComponent("Gone.txt"), baseRevision: nil,
                editRevision: .init(rawValue: 1), text: "draft", createdAt: .distantPast, reason: .saveFailure)
            record.trackingRemoved = removed
            return record
        }
        let stray = NoteID()
        let retainedID = NoteID()
        try journals.write(record(stray, removed: false))
        let retained = record(retainedID, removed: true)
        try journals.retain(retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journals.url(stray).path))

        let restarted = try NoteStore(support: fixture.root, clock: fixture.clock)
        _ = try await restarted.openSelectedFolder()

        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.url(stray).path))
        XCTAssertEqual(journals.load().records.map(\.noteID), [retainedID])
    }

    func testRecoveryReplayPolicyRetainsRemovedUnavailableAndWrongFolderRecords() {
        let noteID = NoteID()
        let token = CollectionToken()
        let record = RecoveryRecord(id: UUID(), noteID: noteID, collectionToken: token,
            originalURL: URL(fileURLWithPath: "/notes/original.txt"), folderIdentity: "folder-a",
            baseRevision: nil, editRevision: .init(rawValue: 1), text: "draft", createdAt: .distantPast,
            reason: .conflict)

        XCTAssertEqual(RecoveryPolicy.replay(record, folderAvailable: true, activeFolderIdentity: "folder-a",
            trackedParent: "folder-a", tracked: true), .promote)
        XCTAssertEqual(RecoveryPolicy.replay(record, folderAvailable: true, activeFolderIdentity: "folder-b",
            trackedParent: "folder-b", tracked: true), .retain)
        XCTAssertEqual(RecoveryPolicy.replay(record, folderAvailable: false, activeFolderIdentity: "folder-a",
            trackedParent: "folder-a", tracked: true), .retain)
        var removed = record
        removed.trackingRemoved = true
        XCTAssertEqual(RecoveryPolicy.replay(removed, folderAvailable: true, activeFolderIdentity: "folder-a",
            trackedParent: "folder-a", tracked: true), .retain)
    }

    func testSameEditJournalRebindsVerifiedLocationWithoutChangingPromotion() throws {
        let edit = EditSnapshot(id: NoteID(), collectionToken: CollectionToken(), revision: .init(rawValue: 1),
            baseRevision: nil, text: "retained")
        var prior = RecoveryPolicy.journal(for: edit, url: URL(fileURLWithPath: "/a/note.txt"), prior: nil,
            folderIdentity: "parent-a", resourceIdentity: "resource-a", now: .distantPast)
        prior.promotionURL = URL(fileURLWithPath: "/recovery/reserved.txt")
        prior.promotedNoteID = NoteID()
        let rebound = RecoveryPolicy.journal(for: edit, url: URL(fileURLWithPath: "/b/note.txt"), prior: prior,
            folderIdentity: "parent-b", resourceIdentity: "resource-b", now: .distantFuture, verifiedRelocation: true)
        XCTAssertEqual(rebound.originalURL.path, "/b/note.txt")
        XCTAssertEqual(rebound.folderIdentity, "parent-b")
        XCTAssertEqual(rebound.originalResourceIdentity, "resource-b")
        XCTAssertEqual(rebound.id, prior.id)
        XCTAssertEqual(rebound.createdAt, prior.createdAt)
        XCTAssertEqual(rebound.text, prior.text)
        XCTAssertEqual(rebound.baseRevision, prior.baseRevision)
        XCTAssertEqual(rebound.editRevision, prior.editRevision)
        XCTAssertEqual(rebound.promotionURL, prior.promotionURL)
        XCTAssertEqual(rebound.promotedNoteID, prior.promotedNoteID)
    }

    func testRecoveryPolicyUsesNewIdentityAfterPromotionAndCompletesOnlyMatchingEdit() throws {
        let noteID = NoteID()
        let token = CollectionToken()
        let firstEdit = EditSnapshot(id: noteID, collectionToken: token, revision: .init(rawValue: 1),
            baseRevision: nil, text: "first draft")
        var prior = RecoveryPolicy.journal(for: firstEdit, url: URL(fileURLWithPath: "/notes/original.txt"),
            prior: nil, folderIdentity: "folder-a", resourceIdentity: "source", now: .distantPast)
        prior.promotionURL = URL(fileURLWithPath: "/support/Recovery/rn-first.txt")
        let sameRevision = RecoveryPolicy.journal(for: firstEdit, url: prior.originalURL, prior: prior,
            folderIdentity: "folder-a", resourceIdentity: "source", now: .distantFuture)
        XCTAssertEqual(sameRevision.id, prior.id)

        let nextEdit = EditSnapshot(id: noteID, collectionToken: token, revision: .init(rawValue: 2),
            baseRevision: nil, text: "second draft")
        let next = RecoveryPolicy.journal(for: nextEdit, url: prior.originalURL, prior: prior,
            folderIdentity: "folder-a", resourceIdentity: "source", now: .distantFuture)
        XCTAssertNotEqual(next.id, prior.id)

        prior.promotedNoteID = NoteID()
        let matchingLink = RecoveryNotice(originalURL: prior.originalURL, recoveryURL: try XCTUnwrap(prior.promotionURL),
            originalMissing: false, recoveryNoteID: try XCTUnwrap(prior.promotedNoteID))
        XCTAssertEqual(RecoveryPolicy.completedPromotion(prior, for: firstEdit, links: [prior.id: matchingLink]), matchingLink)
        XCTAssertNil(RecoveryPolicy.completedPromotion(prior, for: nextEdit, links: [prior.id: matchingLink]))
    }
}

private final class FilenameEntropySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value / 3
    }
}

/// Deferred identity changes live only in memory until a checkpoint writes them.
extension StorageTests {
    private func deferredFixture() async throws -> (TestFixture, NoteStore, NoteSnapshot, NoteSnapshot, URL) {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = fixture.root.appendingPathComponent("Deferred", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Original", "Recovery"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name + ".txt")) }
        let notes = try await store.discover(in: folder, collectionToken: CollectionToken())
        let original = try XCTUnwrap(notes.first { $0.fileURL.lastPathComponent == "Original.txt" })
        let recovery = try XCTUnwrap(notes.first { $0.fileURL.lastPathComponent == "Recovery.txt" })
        try await store.seedRecoveryNoticeForFixture(original: original, recovery: recovery)
        var map = await store.identities
        var identity = try XCTUnwrap(map.identity(original.id))
        identity.path = "/deferred/Original.txt"
        XCTAssertTrue(map.remember(identity))
        await store.deferIdentityWrite(map)
        return (fixture, store, original, recovery, fixture.root.appendingPathComponent("collection.json"))
    }

    func testForgettingRecoveryNoticeWritesDeferredIdentity() async throws {
        let (fixture, store, original, recovery, url) = try await deferredFixture()
        defer { withExtendedLifetime(fixture) {} }
        try await store.forgetRecoveryNotices([recovery.fileURL])
        let disk = try CatalogPersistence.load(at: url)
        XCTAssertEqual(disk.notes[original.id]?.path, "/deferred/Original.txt")
        XCTAssertTrue(disk.recoveryLinks.isEmpty)
    }

    func testRemovalWithDeferredIdentityForgetsRecoveryLinksAndKeepsOtherChange() async throws {
        let (fixture, store, original, recovery, url) = try await deferredFixture()
        defer { withExtendedLifetime(fixture) {} }
        let catalog = await store.identities.catalog
        try await store.writeIdentities(IdentityMap(catalog: catalog.forgetting([recovery.id])))
        let disk = try CatalogPersistence.load(at: url)
        XCTAssertNil(disk.notes[recovery.id])
        XCTAssertTrue(disk.recoveryLinks.isEmpty)
        XCTAssertEqual(disk.notes[original.id]?.path, "/deferred/Original.txt")
        let dirty = await store.identitiesDirty
        XCTAssertFalse(dirty)
    }

    func testCorruptCatalogCheckpointKeepsFileAndDeferredIdentity() async throws {
        let (fixture, store, original, recovery, url) = try await deferredFixture()
        defer { withExtendedLifetime(fixture) {} }
        let corrupt = Data(#"{"version":999,"notes":[]}"#.utf8)
        try corrupt.write(to: url)
        do {
            try await store.forgetRecoveryNotices([recovery.fileURL])
            XCTFail("A corrupt catalog must stop the checkpoint")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let path = await store.identities.identity(original.id)?.path
        let dirty = await store.identitiesDirty
        let notices = await store.recoveryNotices()
        XCTAssertEqual(path, "/deferred/Original.txt")
        XCTAssertTrue(dirty)
        XCTAssertEqual(notices.count, 1)
    }
}
