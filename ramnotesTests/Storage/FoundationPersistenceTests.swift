import XCTest
import ramnotesDomain
import Carbon
@testable import ramnotes

final class FoundationPersistenceTests: XCTestCase {
    func testSettingsDefaultsMatchFoundationContract() {
        let settings = AppSettings()
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.alwaysOnTop)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.fontFamily, "System")
        XCTAssertEqual(settings.fontWeight, "Regular")
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertEqual(settings.lineHeight, 27)
        XCTAssertFalse(settings.menuBarGestureEnabled)
        XCTAssertTrue(settings.bringNotesForwardWhenInactive)
        XCTAssertNil(settings.nextNoteShortcut)
        XCTAssertNil(settings.previousNoteShortcut)
        XCTAssertNil(settings.noteListShortcut)
        XCTAssertNil(settings.moveToTrashShortcut)
        XCTAssertEqual(settings.shortcut, ShortcutChord(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(controlKey)).storedValue)
    }

    func testCurrentWindowMetadataKeepsOpenState() throws {
        for opened in [true, false] {
            let data = Data("{\"isOpen\":\(opened),\"focusOrder\":7}".utf8)
            let saved = try JSONDecoder().decode(NoteWindowMetadata.self, from: data)
            XCTAssertEqual(saved.isOpen, opened)
            XCTAssertEqual(saved.focusOrder, 7)
            XCTAssertEqual(try JSONDecoder().decode(NoteWindowMetadata.self, from: JSONEncoder().encode(saved)), saved)
        }
    }

    func testEditorPresentationMetadataCompatibilityAndRoundTrip() throws {
        let old = try JSONDecoder().decode(NoteWindowMetadata.self,
            from: Data(#"{"isOpen":true,"focusOrder":7}"#.utf8))
        XCTAssertNil(old.editorPosition)
        XCTAssertNil(old.acceptedFileModifiedAt)
        XCTAssertNil(old.externalChangeNoticeAt)
        var value = old
        let timestamp = Date(timeIntervalSince1970: 12345)
        value.editorPosition = EditorPosition(selections: [.init(location: 3, length: 4)],
            scrollX: 0, scrollY: 250, hasActiveCaret: false, fileModifiedAt: timestamp)
        value.acceptedFileModifiedAt = timestamp
        value.externalChangeNoticeAt = timestamp
        let decoded = try JSONDecoder().decode(NoteWindowMetadata.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.editorPosition?.hasActiveCaret, false)
    }

    func testEditorPositionSanitizesInvalidDecodedCoordinatesAndRanges() throws {
        let data = Data(#"{"selections":[{"location":-1,"length":2},{"location":9223372036854775807,"length":1},{"location":2,"length":-1},{"location":3,"length":4}],"scrollX":-4,"scrollY":12,"hasActiveCaret":false}"#.utf8)
        let value = try JSONDecoder().decode(EditorPosition.self, from: data)
        XCTAssertEqual(value.selections, [.init(location: 3, length: 4)])
        XCTAssertEqual(value.scrollX, 0)
        let nonfinite = EditorPosition(selections: [], scrollX: .infinity, scrollY: .nan,
            hasActiveCaret: false, fileModifiedAt: nil)
        XCTAssertEqual(nonfinite.scrollX, 0)
        XCTAssertEqual(nonfinite.scrollY, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(nonfinite))
    }

    func testMetadataRoundTripAndCollectionIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-tests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(root: root)
        var settings = AppSettings()
        settings.fontSize = 24
        try await store.saveSettings(settings)
        let loaded = await store.loadSettings()
        XCTAssertEqual(loaded.value, settings)
        XCTAssertNil(loaded.diagnostic)

        let noteID = NoteID()
        let folder = CollectionMetadata(notes: [noteID: NoteWindowMetadata(isOpen: true)])
        try await store.saveCollection(folder)
        let first = await store.loadCollection()
        let second = await store.loadCollection()
        XCTAssertEqual(first.value, folder)
        XCTAssertEqual(second.value.notes[noteID], folder.notes[noteID])
    }

    func testUnknownMetadataVersionIsPreserved() async throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("settings.json")
        let future = Data("{\"version\":99,\"value\":{}}".utf8)
        try future.write(to: file)
        let store = MetadataStore(root: fixture.root)
        let loaded = await store.loadSettings()
        XCTAssertNotNil(loaded.diagnostic)
        do {
            try await store.saveSettings(AppSettings())
            XCTFail("Expected a protective error")
        } catch {
            XCTAssertEqual(try Data(contentsOf: file), future)
        }
    }

    private var legacySettingsFixtures: [String] {
        [
            #"{"appearance":"dark","alwaysOnTop":true,"launchAtLogin":true,"fontFamily":"System","fontWeight":"Bold","fontSize":18,"lineHeight":20,"menuBarGestureEnabled":true}"#,
            #"{"appearance":"light","alwaysOnTop":true,"launchAtLogin":false,"fontFamily":"System","fontWeight":"Regular","fontSize":18,"lineHeight":20,"menuBarGestureEnabled":false,"shortcut":"command+option+n"}"#,
            #"{"appearance":"system","alwaysOnTop":false,"launchAtLogin":false,"fontFamily":"System","fontWeight":"Regular","fontSize":20,"lineHeight":20,"menuBarGestureEnabled":false,"shortcut":"command+option+n"}"#,
            #"{"appearance":"dark","alwaysOnTop":true,"launchAtLogin":false,"fontFamily":"System","fontWeight":"Medium","fontSize":20,"lineHeight":28,"menuBarGestureEnabled":true,"shortcut":"command+option+control+n"}"#,
            #"{"appearance":"light","alwaysOnTop":false,"launchAtLogin":true,"fontFamily":"Monaco","fontWeight":"Regular","fontSize":14,"lineHeight":22,"menuBarGestureEnabled":false,"shortcut":"command+option+control+n"}"#,
            #"{"appearance":"dark","alwaysOnTop":true,"launchAtLogin":true,"fontFamily":"Monaco","fontWeight":"Regular","fontSize":16,"lineHeight":24,"menuBarGestureEnabled":true,"shortcut":"command+option+control+n","nextNoteShortcut":"30:256","previousNoteShortcut":"33:256"}"#
        ]
    }

    func testLegacySettingsUpgradePreservesEveryPresentPreference() async throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("settings.json")
        let store = MetadataStore(root: fixture.root)
        for json in legacySettingsFixtures {
            let original = Data("{\"version\":1,\"value\":\(json)}".utf8)
            try original.write(to: file)
            let loaded = await store.loadSettings()
            XCTAssertNil(loaded.diagnostic)
            XCTAssertEqual(try Data(contentsOf: file), original, "Loading must not persist migration")
            try await store.saveSettings(loaded.value)
            let reloaded = await store.loadSettings()
            XCTAssertNil(reloaded.diagnostic)
            XCTAssertEqual(reloaded.value, loaded.value)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSObject])
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let after = try XCTUnwrap(envelope["value"] as? [String: NSObject])
            for (key, value) in before { XCTAssertEqual(after[key], value, key) }
            XCTAssertEqual(after["nextNoteShortcut"], before["nextNoteShortcut"] ?? NSNull())
        }
    }

    func testMissingSettingsFieldsUseDefaultsAndOptionalNullsRemainNil() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let defaults = AppSettings()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(defaults)) as? [String: Any])
        for key in object.keys {
            var missing = object
            missing.removeValue(forKey: key)
            XCTAssertEqual(try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: missing)), defaults, key)
        }
        XCTAssertEqual(try decoder.decode(AppSettings.self, from: Data("{}".utf8)), defaults)
        let nulls = try decoder.decode(AppSettings.self, from: Data(#"{"shortcut":null,"nextNoteShortcut":null,"previousNoteShortcut":null}"#.utf8))
        XCTAssertNil(nulls.shortcut)
        XCTAssertNil(nulls.nextNoteShortcut)
        XCTAssertNil(nulls.previousNoteShortcut)
        XCTAssertEqual(try decoder.decode(AppSettings.self, from: encoder.encode(nulls)), nulls)
    }

    func testBringForwardPreferenceSurvivesReloadAndRejectsNonBooleans() async throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("settings.json")
        let store = MetadataStore(root: fixture.root)
        var settings = AppSettings()
        settings.bringNotesForwardWhenInactive = false
        try await store.saveSettings(settings)
        let reloaded = await store.loadSettings()
        XCTAssertNil(reloaded.diagnostic)
        XCTAssertFalse(reloaded.value.bringNotesForwardWhenInactive)

        let legacy = Data(#"{"version":1,"value":{"menuBarGestureEnabled":true}}"#.utf8)
        try legacy.write(to: file)
        let upgraded = await store.loadSettings()
        XCTAssertTrue(upgraded.value.bringNotesForwardWhenInactive)

        let invalid = Data(#"{"version":1,"value":{"bringNotesForwardWhenInactive":"yes"}}"#.utf8)
        try invalid.write(to: file)
        let rejected = await store.loadSettings()
        XCTAssertNotNil(rejected.diagnostic)
    }

    func testInvalidSettingsAreDiagnosedAndCannotBeOverwritten() async throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("settings.json")
        let store = MetadataStore(root: fixture.root)
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        var invalid: [[String: Any]] = []
        for key in defaults.keys {
            var wrongType = defaults
            wrongType[key] = ["invalid"]
            invalid.append(wrongType)
            if !["shortcut", "nextNoteShortcut", "previousNoteShortcut", "noteListShortcut", "moveToTrashShortcut",
                  "increaseFontShortcut", "decreaseFontShortcut", "resetFontShortcut"].contains(key) {
                var null = defaults
                null[key] = NSNull()
                invalid.append(null)
            }
        }
        invalid += [["appearance": "future-theme"], ["nextNoteShortcut": 42], ["previousNoteShortcut": false]]
        let invalidBytes = try invalid.map { value in
            try JSONSerialization.data(withJSONObject: ["version": 1, "value": value])
        } + [Data("broken".utf8)]
        for original in invalidBytes {
            try original.write(to: file)
            let loaded = await store.loadSettings()
            XCTAssertNotNil(loaded.diagnostic)
            XCTAssertEqual(loaded.value, AppSettings())
            do {
                try await store.saveSettings(loaded.value)
                XCTFail("Invalid settings must be protected")
            } catch { XCTAssertEqual(try Data(contentsOf: file), original) }
        }
    }

    func testFailedMigrationWritePreservesLegacyFileAndAllowsRetry() async throws {
        let fixture = try TestFixture()
        let file = fixture.root.appendingPathComponent("settings.json")
        let original = Data("{\"version\":1,\"value\":\(legacySettingsFixtures[0])}".utf8)
        try original.write(to: file)
        let store = MetadataStore(root: fixture.root)
        let loaded = await store.loadSettings()
        var invalid = loaded.value
        invalid.fontSize = .infinity
        do {
            try await store.saveSettings(invalid)
            XCTFail("Expected encoding failure")
        } catch { XCTAssertEqual(try Data(contentsOf: file), original) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path) }
        do {
            try await store.saveSettings(loaded.value)
            XCTFail("Expected atomic write failure in a read-only directory")
        } catch { XCTAssertEqual(try Data(contentsOf: file), original) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        try await store.saveSettings(loaded.value)
        let reloaded = await store.loadSettings()
        XCTAssertEqual(reloaded.value, loaded.value)
        XCTAssertNil(reloaded.diagnostic)
    }
}
