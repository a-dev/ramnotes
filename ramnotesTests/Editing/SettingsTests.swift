import ramnotesDomain
import AppKit
import Carbon
import XCTest
@testable import ramnotes

@MainActor
final class SettingsTests: XCTestCase {
    func testDisplayedPathsPreferCloudThenHomeAndRespectDirectoryBoundaries() {
        let home = URL(fileURLWithPath: "/Users/example")
        let cases = [
            ("/Users/example/notes/a.txt", "~/notes/a.txt"),
            ("/Users/example/Library/Mobile Documents/com~apple~CloudDocs/notes/a.txt", "iCloud/notes/a.txt"),
            ("/Users/example/Library/Mobile Documents/com~apple~CloudDocs", "iCloud/"),
            ("/Users/example", "~/"),
            ("/Users/example-other/a.txt", "/Users/example-other/a.txt"),
            ("/Users/example/Library/Mobile Documents/com~apple~CloudDocs-other/a.txt",
             "~/Library/Mobile Documents/com~apple~CloudDocs-other/a.txt"),
            ("/Volumes/Notes/a.txt", "/Volumes/Notes/a.txt")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(NoteLocationPresentation.path(URL(fileURLWithPath: input), home: home), expected)
        }
    }

    func testMissingDefaultFolderWarningClearsAfterRecovery() {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        controller.showMissingDefaultFolder(true)
        XCTAssertFalse(controller.missingFolderStatus.isHidden)
        XCTAssertEqual(controller.missingFolderStatus.textColor, .systemRed)
        XCTAssertEqual(controller.missingFolderStatus.stringValue,
                       "Default folder is missing. Choose a default folder below.")
        controller.showMissingDefaultFolder(false)
        XCTAssertTrue(controller.missingFolderStatus.isHidden)
    }

    func testSettingsRestoresFreshStoredFrameWithoutProcessCache() async throws {
        let name = "RAMnotes.Settings.test." + UUID().uuidString
        let key = "NSWindow Frame " + name
        UserDefaults.standard.set("396 183 848 588 0 0 1470 922 ", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let controller = SettingsController(settings: AppSettings(), frameAutosaveName: name)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        try await waitUntil { abs(window.frame.width - 848) <= 2 }
        XCTAssertEqual(window.frame.width, 848, accuracy: 2)
    }

    func testReducedMotionKeepsFolderActivityVisibleWithoutSpinner() {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        controller.showFolderActivity(busy: true)
        controller.applyDisplayPreferences(reduceMotion: true)
        XCTAssertTrue(controller.folderProgress.isHidden)
        XCTAssertFalse(controller.folderActivityLabel.isHidden)
        XCTAssertEqual(controller.folderActivityLabel.stringValue, "Changing default notes folder…")
        controller.applyDisplayPreferences(reduceMotion: false)
        XCTAssertFalse(controller.folderProgress.isHidden)
        XCTAssertTrue(controller.folderActivityLabel.isHidden)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(controller.folderProgress.isHidden, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        controller.showFolderActivity(busy: false)
        XCTAssertTrue(controller.folderProgress.isHidden)
        XCTAssertTrue(controller.folderActivityLabel.isHidden)
    }

    func testNavigationShortcutChangesPersistAndRejectConflicts() {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        var saved: AppSettings?
        controller.changed = { saved = $0 }
        let custom = ShortcutChord(keyCode: 124, modifiers: UInt32(cmdKey | optionKey))
        controller.nextNoteRecorder.recorded?(custom)
        XCTAssertEqual(saved?.nextNoteChord, custom)
        XCTAssertEqual(controller.nextNoteRecorder.chord, custom)

        saved = nil
        controller.previousNoteRecorder.recorded?(custom)
        controller.previousNoteRecorder.recorded?(controller.recorder.chord)
        controller.previousNoteRecorder.recorded?(ShortcutChord(keyCode: 37, modifiers: UInt32(cmdKey)))
        XCTAssertNil(saved)
        XCTAssertEqual(controller.previousNoteRecorder.chord, .previousNote)
    }

    func testBringForwardCheckboxSavesAndReopensWithSavedState() throws {
        let controller = SettingsController(settings: AppSettings())
        var saved: AppSettings?
        controller.changed = { saved = $0 }
        XCTAssertEqual(controller.bringForwardCheckbox.state, .on)
        controller.bringForwardCheckbox.performClick(nil)
        XCTAssertEqual(saved?.bringNotesForwardWhenInactive, false)
        controller.close()

        let reopened = try SettingsController(settings: XCTUnwrap(saved))
        defer { reopened.close() }
        XCTAssertEqual(reopened.bringForwardCheckbox.state, .off)
    }

    func testGlobalShortcutRequestFollowsDecisionTable() {
        let inactive = ToggleRequest(bringForwardWhenInactive: true, appActive: false)
        XCTAssertFalse(inactive.hides(groupVisible: true), "inactive app with visible windows comes forward")
        XCTAssertFalse(inactive.hides(groupVisible: false))
        let active = ToggleRequest(bringForwardWhenInactive: true, appActive: true)
        XCTAssertTrue(active.hides(groupVisible: true), "active app, e.g. Settings focused, hides a visible group")
        XCTAssertFalse(active.hides(groupVisible: false))
        for appActive in [true, false] {
            let off = ToggleRequest(bringForwardWhenInactive: false, appActive: appActive)
            XCTAssertTrue(off.hides(groupVisible: true), "preference off hides a covered note")
            XCTAssertFalse(off.hides(groupVisible: false), "empty group reveals")
        }
        XCTAssertTrue(ToggleRequest.toggle.hides(groupVisible: true), "gesture and menu callers keep toggling")
    }

    func testNoteCommandShortcutsPersistAndRejectConflicts() throws {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        var saved: AppSettings?
        controller.changed = { saved = $0 }
        let custom = ShortcutChord(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
        controller.appShortcutRecorders[.noteList]?.recorded?(custom)
        XCTAssertEqual(saved?.chord(for: .noteList), custom)

        saved = nil
        controller.appShortcutRecorders[.moveToTrash]?.recorded?(custom)
        controller.appShortcutRecorders[.previousNote]?.recorded?(.nextNote)
        XCTAssertNil(saved)
        XCTAssertEqual(controller.appShortcutRecorders[.moveToTrash]?.chord, .moveToTrash)
        XCTAssertEqual(controller.appShortcutRecorders[.previousNote]?.chord, .previousNote)

        var settings = AppSettings()
        settings.setChord(custom, for: .noteList)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.chord(for: .noteList), custom)
        XCTAssertEqual(decoded.chord(for: .moveToTrash), .moveToTrash)
    }

    func testBackgroundToneDecodingAndRoundTrips() throws {
        let legacy = Data(#"{"isOpen":true,"fontSize":18,"focusOrder":7}"#.utf8)
        let decoder = JSONDecoder()
        let old = try decoder.decode(NoteWindowMetadata.self, from: legacy)
        XCTAssertNil(old.backgroundTone)
        for tone in [nil] + NoteBackgroundTone.allCases.map({ Optional($0) }) {
            var value = old
            value.backgroundTone = tone
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try decoder.decode(NoteWindowMetadata.self, from: data), value)
            if tone == nil { XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("backgroundTone")) }
        }
        let future = Data(#"{"isOpen":true,"fontSize":18,"focusOrder":7,"backgroundTone":"orange"}"#.utf8)
        XCTAssertEqual(try decoder.decode(NoteWindowMetadata.self, from: future), old)
    }

    func testUnknownTonePreservesFolderAndOtherNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(root: root)
        let first = NoteID()
        let second = NoteID()
        var folder = CollectionMetadata()
        folder.notes[first] = NoteWindowMetadata(isOpen: true, fontSize: 19, backgroundTone: .blue)
        folder.notes[second] = NoteWindowMetadata(isOpen: false, backgroundTone: .red)
        try await store.saveCollection(folder)
        let file = root.appendingPathComponent("collection-metadata.json")
        let json = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "blue", with: "future-tone")
        try Data(json.utf8).write(to: file)
        let loaded = await store.loadCollection()
        XCTAssertNil(loaded.diagnostic)
        XCTAssertNil(loaded.value.notes[first]?.backgroundTone)
        XCTAssertEqual(loaded.value.notes[first]?.fontSize, 19)
        XCTAssertEqual(loaded.value.notes[second], folder.notes[second])
        try await store.saveCollection(loaded.value)
    }

    func testTypographyNormalizationClampsNonfiniteAndOutOfRangeNumbers() {
        var settings = AppSettings()
        settings.fontSize = .nan
        settings.lineHeight = .infinity

        let nonfinite = EditorTypography.normalized(settings)
        XCTAssertEqual(nonfinite.fontSize, 20)
        XCTAssertEqual(nonfinite.lineHeight, 20)

        settings.fontSize = -100
        settings.lineHeight = -1
        let belowRange = EditorTypography.normalized(settings)
        XCTAssertEqual(belowRange.fontSize, 8)
        XCTAssertEqual(belowRange.lineHeight, 8)

        settings.fontSize = 240
        settings.lineHeight = 400
        let aboveRange = EditorTypography.normalized(settings)
        XCTAssertEqual(aboveRange.fontSize, 192)
        XCTAssertEqual(aboveRange.lineHeight, 384)
    }

    func testMissingFamilyFallsBackToSystemAndSupportedFaceIsRetained() throws {
        var missing = AppSettings()
        missing.fontFamily = "ramnotes missing font family"
        missing.fontWeight = "Bold"

        let fallback = EditorTypography.normalized(missing)
        XCTAssertEqual(fallback.fontFamily, "System")
        XCTAssertEqual(fallback.fontWeight, "Bold")

        let family = try XCTUnwrap(
            NSFontManager.shared.availableFontFamilies.first {
                $0 != "System" && !EditorTypography.weights(for: $0).isEmpty
            },
            "At least one supported non-system font family should be available"
        )
        let face = try XCTUnwrap(EditorTypography.weights(for: family).first)
        var supported = AppSettings()
        supported.fontFamily = family
        supported.fontWeight = face

        let retained = EditorTypography.normalized(supported)
        XCTAssertEqual(retained.fontFamily, family)
        XCTAssertEqual(retained.fontWeight, face)
    }

    func testNormalizationPreservesSelectedColorTheme() {
        for appearance in [AppearancePreference.system, .light, .dark] {
            var settings = AppSettings()
            settings.appearance = appearance
            XCTAssertEqual(EditorTypography.normalized(settings).appearance, appearance)
        }
    }

    func testSystemFontsHonorSelectedWeightAndPointSize() {
        let weights: [(String, NSFont.Weight)] = [
            ("Regular", .regular),
            ("Medium", .medium),
            ("Semibold", .semibold),
            ("Bold", .bold)
        ]

        for (name, weight) in weights {
            var settings = AppSettings()
            settings.fontFamily = "System"
            settings.fontWeight = name
            settings.fontSize = 18.5

            let actual = EditorTypography.font(for: settings)
            let expected = NSFont.systemFont(ofSize: 18.5, weight: weight)
            XCTAssertEqual(actual.pointSize, 18.5)
            XCTAssertTrue(actual.fontDescriptor.isEqual(expected.fontDescriptor), "Unexpected system font for \(name)")
        }
    }

    func testLoadedPresentationPreferencesPreserveEditorStateAndDiskText() async throws {
        let fixture = try TestFixture()
        let store = try NoteStore(support: fixture.root, clock: fixture.clock)
        let folder = await store.defaultFolder()
        let url = folder.appendingPathComponent("Presentation.txt")
        let originalBytes = Data("saved text".utf8)
        try originalBytes.write(to: url)
        let collectionToken = CollectionToken()
        let notes = try await store.discover(in: folder, collectionToken: collectionToken)
        let note = try XCTUnwrap(notes.first)

        var preferences = AppSettings()
        preferences.fontFamily = "System"
        preferences.fontWeight = "Bold"
        preferences.fontSize = 23
        preferences.lineHeight = 31
        let metadata = MetadataStore(root: fixture.root.appendingPathComponent("Metadata", isDirectory: true))
        try await metadata.saveSettings(preferences)
        let loaded = await metadata.loadSettings()
        XCTAssertNil(loaded.diagnostic)
        XCTAssertEqual(loaded.value, preferences)

        let editor = NoteEditorController(note: note, store: store)
        editor.textView.string = "local draft with selection"
        editor.textView.setSelectedRange(NSRange(location: 6, length: 5))
        editor.capture()
        let textBeforeApply = editor.textView.string
        let selectionBeforeApply = editor.textView.selectedRange()
        let revisionBeforeApply = editor.state.currentRevision

        editor.apply(loaded.value)

        XCTAssertEqual(editor.textView.string, textBeforeApply)
        XCTAssertEqual(editor.textView.selectedRange(), selectionBeforeApply)
        XCTAssertEqual(editor.state.currentRevision, revisionBeforeApply)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)

        let futureEditor = NoteEditorController(note: note, store: store, settings: loaded.value)
        XCTAssertEqual(futureEditor.textView.font?.pointSize, 23)
        XCTAssertTrue(futureEditor.textView.font?.fontDescriptor.isEqual(NSFont.systemFont(ofSize: 23, weight: .bold).fontDescriptor) == true)
        XCTAssertEqual(futureEditor.textView.defaultParagraphStyle?.minimumLineHeight, 31)
    }
    func testTabReachesControlsOfEveryPageAfterSwitchingCategories() throws {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        func views<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, t) } }
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(views(content, NSTableView.self).first)
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window.makeFirstResponder(table)
            var reached: [NSView] = []
            for _ in 0..<8 {
                window.selectNextKeyView(nil)
                if let view = window.firstResponder as? NSView { reached.append(view) }
            }
            let quit = reached.first { ($0 as? NSButton)?.title == "Quit RAMnotes" }
            XCTAssertTrue(reached.contains { $0 !== table && $0 !== quit && !(($0 as? NSTextView)?.isFieldEditor == true && $0.superview == nil) },
                          "Category \(row): Tab must reach the page's controls, not only the list and Quit")
        }
    }

    func testIdleShortcutRecorderPassesKeysOnSoTabCanMoveFocus() throws {
        final class Spy: NSResponder { var keys: [UInt16] = []; override func keyDown(with event: NSEvent) { keys.append(event.keyCode) } }
        let recorder = ShortcutRecorder()
        let spy = Spy()
        recorder.nextResponder = spy
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        recorder.keyDown(with: tab)
        XCTAssertEqual(spy.keys, [48], "An idle recorder swallowed Tab, which trapped keyboard focus in Settings")
    }

    func testFocusingAHiddenControlScrollsItIntoView() throws {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: window.frame.width, height: 540))
        func views<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, t) } }
        let table = try XCTUnwrap(views(try XCTUnwrap(window.contentView), NSTableView.self).first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window.contentView?.layoutSubtreeIfNeeded()
        // No page overflows at the minimum height, so scroll Windows to its end and focus its first control.
        let last = try XCTUnwrap(views(try XCTUnwrap(window.contentView), NSButton.self).first { $0.title == "Keep note windows on top" })
        let scroll = try XCTUnwrap(last.enclosingScrollView)
        let clip = scroll.contentView
        try XCTUnwrap(scroll.documentView).frame.size.height += 400
        clip.scroll(to: NSPoint(x: 0, y: try XCTUnwrap(scroll.documentView).frame.height - clip.bounds.height))
        XCTAssertFalse(clip.documentVisibleRect.contains(last.convert(last.bounds, to: clip.documentView)), "The control starts outside the visible area")
        window.makeFirstResponder(last)
        XCTAssertTrue(clip.documentVisibleRect.contains(last.convert(last.bounds, to: clip.documentView)), "Keyboard focus scrolls the page")
    }

    func testRejectedShortcutIsAnnouncedToVoiceOver() throws {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let recorder = controller.nextNoteRecorder
        var spoken: [String] = []
        recorder.announce = { spoken.append($0) }
        func views<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, t) } }
        let table = try XCTUnwrap(views(try XCTUnwrap(window.contentView), NSTableView.self).first)
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        recorder.performClick(nil)
        let k = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        recorder.keyDown(with: k)
        XCTAssertEqual(spoken, ["Include Command, Option, or Control."], "VoiceOver skips the symbols ⌘ ⌥ ⌃, so the announcement names the keys")
        recorder.cancel()
    }

    func testSettingsOpensWithTheCategoryListFocused() throws {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        controller.focusCategories()
        XCTAssertTrue(window.firstResponder is NSTableView, "First open must focus General in the category list, not Quit")
        XCTAssertEqual((window.firstResponder as? NSTableView)?.selectedRow, 0)
    }

    func testSettingsExposesNoInertSplitterAndPageControlsAreReachable() throws {
        let controller = SettingsController(settings: AppSettings())
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        var roles: [NSAccessibility.Role] = []
        var scrollContents: [[Any]] = []
        func walk(_ element: Any) {
            let object = element as AnyObject
            if let role = object.accessibilityRole?() ?? nil { roles.append(role) }
            if let scroll = element as? NSScrollView { scrollContents.append(scroll.accessibilityContents() ?? []) }
            for child in (object.accessibilityChildren?() ?? nil) ?? [] { walk(child) }
        }
        walk(window)
        XCTAssertFalse(roles.contains(.splitGroup))
        XCTAssertFalse(roles.contains(.splitter))
        let pageContents = scrollContents.flatMap { $0 }.map { $0 as AnyObject }
        XCTAssertTrue(pageContents.contains { ($0.accessibilityRole?() ?? nil) == .group },
                      "VoiceOver must be able to enter the page scroll area and reach its sections")
    }
}

@MainActor
final class NoteLocationControllerTests: XCTestCase {
    func testUnavailableRecoveryActionsDismissBeforeCallingOwner() throws {
        for title in ["Locate File…", "Remove from List"] {
            var dismissed = false
            var actions: [String] = []
            let record: (String) -> Void = { action in
                XCTAssertTrue(dismissed)
                actions.append(action)
            }
            let controller = NoteLocationController(
                file: URL(fileURLWithPath: "/tmp/missing.txt"),
                defaultFolder: URL(fileURLWithPath: "/tmp"), available: false, removable: true,
                accessFailure: NoteAccessFailure(reason: .missingFile, domain: "test", code: 1, message: "Missing"),
                submit: { _ in XCTFail("Unavailable notes cannot be moved") },
                locate: { record("Locate File…") },
                remove: { record("Remove from List") }, dismissed: { dismissed = true })
            controller.showWindow(nil)
            func buttons(in view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
            }
            let allButtons = buttons(in: try XCTUnwrap(controller.window?.contentView))
            XCTAssertFalse(controller.basename.isEnabled)
            XCTAssertTrue(allButtons.first { $0.title == "Save" }?.isHidden == true)
            let button = try XCTUnwrap(allButtons.first { $0.title == title })
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil)
            XCTAssertEqual(actions, [title])
        }
    }
    func testAccessRepairLabelAndMissingFileRemovalExplanation() throws {
        func buttons(_ controller: NoteLocationController) throws -> [NSButton] {
            func collect(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            return collect(try XCTUnwrap(controller.window?.contentView))
        }
        let file = URL(fileURLWithPath: "/tmp/missing.txt")
        let stale = NoteAccessFailure(reason: .staleBookmark, domain: "test", code: 1, message: "Stale access")
        let fileAccess = NoteLocationController(file: file, defaultFolder: URL(fileURLWithPath: "/tmp"), available: false,
            accessFailure: stale, submit: { _ in }, dismissed: {})
        defer { fileAccess.close() }
        fileAccess.showWindow(nil)
        let fileButtons = try buttons(fileAccess)
        XCTAssertTrue(fileButtons.contains { $0.title == "Restore File Access…" })
        XCTAssertFalse(fileButtons.contains { $0.title == "Allow Folder Access…" })

        let volume = NoteAccessFailure(reason: .unavailableVolume, domain: "test", code: 2, message: "Volume unavailable")
        let unavailable = NoteLocationController(file: file, defaultFolder: URL(fileURLWithPath: "/tmp"), available: false,
            accessFailure: volume, submit: { _ in }, dismissed: {})
        defer { unavailable.close() }
        unavailable.showWindow(nil)
        let volumeButtons = try buttons(unavailable)
        XCTAssertFalse(volumeButtons.contains { $0.title == "Restore File Access…" })
        XCTAssertTrue(unavailable.message.stringValue.contains("Volume unavailable"))

        let missing = NoteLocationController(file: file, defaultFolder: URL(fileURLWithPath: "/tmp"), available: false,
            removable: true, accessFailure: NoteAccessFailure(reason: .missingFile, domain: "test", code: 3, message: "Missing"),
            submit: { _ in }, dismissed: {})
        defer { missing.close() }
        missing.showWindow(nil)
        XCTAssertEqual(missing.message.stringValue, "RAMnotes cannot find this file. Removing this entry does not delete any files.")
        XCTAssertTrue(try buttons(missing).contains { $0.title == "Locate File…" })
    }

    func testDefaultChangeConfirmationStartsCheckedWithExactExplanation() {
        let alert = DefaultFolderConfirmation.make(destination: URL(fileURLWithPath: "/tmp/destination"))
        XCTAssertEqual(alert.suppressionButton?.state, .on)
        XCTAssertEqual(alert.suppressionButton?.title, "Move existing notes to the new location")
        XCTAssertTrue(alert.informativeText.contains("Notes with custom paths won’t be moved."))
        XCTAssertEqual(alert.buttons.map(\.title), ["Change Folder", "Cancel"])
    }
    func testCancelDiscardsDraftAndReturnsFocusWithoutSubmission() {
        var submitted = false
        var returned = false
        let controller = NoteLocationController(file: URL(fileURLWithPath: "/tmp/a.txt"), defaultFolder: URL(fileURLWithPath: "/tmp"), submit: { _ in submitted = true }, dismissed: { returned = true })
        controller.showWindow(nil)
        controller.basename.stringValue = "draft"
        controller.close()
        XCTAssertFalse(submitted)
        XCTAssertTrue(returned)
    }
    func testFailureKeepsDraftAndRepeatedSubmissionsAreBlocked() async throws {
        var calls = 0
        var target: URL?
        var returned = false
        let controller = NoteLocationController(file: URL(fileURLWithPath: "/tmp/a.txt"), defaultFolder: URL(fileURLWithPath: "/tmp"), submit: { url in
            calls += 1; target = url
            try await Task.sleep(for: .milliseconds(40))
            throw NoteOperationError.destinationOccupied
        }, dismissed: { returned = true })
        defer { controller.close() }
        controller.basename.stringValue = "occupied"
        controller.save()
        controller.save()
        try await waitUntil { calls == 1 && controller.basename.isEnabled && !controller.message.stringValue.isEmpty }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(target?.lastPathComponent, "occupied.txt")
        XCTAssertFalse(controller.message.stringValue.isEmpty)
        XCTAssertFalse(returned)
        XCTAssertTrue(controller.basename.isEnabled)
    }
    func testCustomLocationShowsPathFinderAndSaveCopyWithoutMoveControls() throws {
        let file = URL(fileURLWithPath: "/tmp/custom/Original.txt")
        var finder = false
        var copy = false
        let controller = NoteLocationController(file: file, defaultFolder: URL(fileURLWithPath: "/tmp/default"),
            showInFinder: { finder = true }, saveCopy: { copy = true }, submit: { _ in XCTFail("Custom location must not be moved") }, dismissed: {})
        controller.showWindow(nil)
        defer { controller.close() }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let allButtons = buttons(in: try XCTUnwrap(controller.window?.contentView))
        XCTAssertTrue(allButtons.contains { $0.title == "Show in Finder" })
        XCTAssertTrue(allButtons.contains { $0.title == "Save a Copy…" })
        XCTAssertFalse(allButtons.contains { ["Choose custom folder…", "Move to default", "Save"].contains($0.title) && !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(controller.folderLabel.stringValue, "/tmp/custom/Original.txt")
        try XCTUnwrap(allButtons.first { $0.title == "Show in Finder" }).performClick(nil)
        try XCTUnwrap(allButtons.first { $0.title == "Save a Copy…" }).performClick(nil)
        XCTAssertTrue(finder)
        XCTAssertTrue(copy)
    }
    func testDefaultLocationCanRenameOnlyWithinDefaultFolder() async throws {
        var target: URL?
        let controller = NoteLocationController(file: URL(fileURLWithPath: "/tmp/default/Original.txt"), defaultFolder: URL(fileURLWithPath: "/tmp/default"), submit: { target = $0 }, dismissed: {})
        controller.basename.stringValue = "Renamed"
        controller.save()
        try await waitUntil { target != nil }
        XCTAssertEqual(target?.path, "/tmp/default/Renamed.txt")
    }
    func testFixedExtensionAndCanonicalDefaultPresentation() {
        var submitted = false
        let controller = NoteLocationController(file: URL(fileURLWithPath: "/tmp/a.txt"), defaultFolder: URL(fileURLWithPath: "/tmp"), submit: { _ in submitted = true }, dismissed: {})
        defer { controller.close() }
        controller.basename.stringValue = "invalid/name"
        controller.save()
        XCTAssertFalse(submitted)
        XCTAssertTrue(controller.message.stringValue.contains("without separators"))
        XCTAssertEqual(NoteLocationController.filename(draft: "pasted.txt", original: URL(fileURLWithPath: "/tmp/a.txt")), "pasted.txt")
        XCTAssertEqual(NoteLocationController.filename(draft: "a.txt", original: URL(fileURLWithPath: "/tmp/a.txt.txt")), "a.txt.txt")
        XCTAssertEqual(NoteLocationPresentation.label(URL(fileURLWithPath: "/tmp/child/../a.txt"), defaultFolder: URL(fileURLWithPath: "/tmp/")), "default")
        XCTAssertEqual(NoteLocationPresentation.label(URL(fileURLWithPath: "/tmp/custom/a.txt"), defaultFolder: URL(fileURLWithPath: "/tmp")), "/tmp/custom/a.txt")
    }
}

@MainActor
final class DisplayNameTests: XCTestCase {
    func testTintAndShortcutNamesAreDisplayOnlyAndRawValuesStayStored() throws {
        XCTAssertEqual(NoteBackgroundTone.allCases.map(\.rawValue), ["gray", "blue", "green", "yellow", "red", "purple"])
        for tone in NoteBackgroundTone.allCases { XCTAssertFalse(tone.localizedName.isEmpty, tone.rawValue) }
        XCTAssertFalse(NoteBackgroundTone.noColorName.isEmpty)
        XCTAssertEqual(NoteBackgroundTone.localizedName(nil), NoteBackgroundTone.noColorName)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(NoteBackgroundTone.green), as: UTF8.self), "\"green\"")
        for shortcut in AppShortcut.allCases { XCTAssertFalse(shortcut.title.isEmpty) }
    }

    // MARK: Per-locale lookups against the app bundle's compiled catalog

    private static let allLocales = ["es", "pt", "de", "fr", "ar", "ja", "zh-Hans"]

    private func bundle(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: NoteWindowController.self).path(forResource: language, ofType: "lproj"), language)
        return try XCTUnwrap(Bundle(path: path), language)
    }

    private func lookup(_ key: String, _ language: String) throws -> String {
        try bundle(for: language).localizedString(forKey: key, value: "\u{1}missing", table: nil)
    }

    func testTintAndSortNamesAreTranslatedInEveryLocale() throws {
        let tints = ["Gray", "Blue", "Green", "Yellow", "Red", "Purple", "No color"]
        let sorts = ["Recently updated", "Oldest updated first", "Recently created", "Oldest created first", "A–Z", "Z–A"]
        for language in Self.allLocales {
            for key in tints + sorts {
                let value = try lookup(key, language)
                XCTAssertNotEqual(value, "\u{1}missing", "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
            }
            // Tint names must stay distinct inside one menu.
            XCTAssertEqual(Set(try tints.map { try lookup($0, language) }).count, tints.count, language)
            XCTAssertEqual(Set(try sorts.map { try lookup($0, language) }).count, sorts.count, language)
        }
        XCTAssertEqual(try lookup("Gray", "de"), "Grau")
        XCTAssertEqual(try lookup("Recently updated", "fr").isEmpty, false)
    }

    func testPathIsolationKeepsLatinPathsIntactInsideArabicSentences() throws {
        let isolated = PathIsolation.isolate("~/Documents/ملاحظات/a.txt")
        XCTAssertTrue(isolated.hasPrefix("\u{2068}") && isolated.hasSuffix("\u{2069}"))
        XCTAssertEqual(isolated.unicodeScalars.filter { $0 == "\u{2068}" || $0 == "\u{2069}" }.count, 2)
        // The wrapped text is the original plus exactly two marks.
        XCTAssertEqual(String(isolated.unicodeScalars.dropFirst().dropLast()), "~/Documents/ملاحظات/a.txt")
    }

    func testArabicPluralCategoriesForNoteCounts() throws {
        let arabic = try bundle(for: "ar")
        let format = arabic.localizedString(forKey: "%lld notes", value: nil, table: nil)
        let locale = Locale(identifier: "ar")
        func text(_ count: Int) -> String { String(format: format, locale: locale, count) }
        // CLDR Arabic: 0 zero, 1 one, 2 two, 3..10 few, 11..99 many, 100 other.
        XCTAssertEqual(text(0), "0 ملاحظة".replacingDigits(locale: locale, for: 0))
        XCTAssertTrue(text(1).contains("ملاحظة") && !text(1).contains("ملاحظات") && !text(1).contains("ملاحظتان"), text(1))
        XCTAssertTrue(text(2).contains("ملاحظتان"), text(2))
        XCTAssertTrue(text(3).contains("ملاحظات"), text(3))
        XCTAssertTrue(text(11).hasSuffix("ملاحظة"), text(11))
        XCTAssertTrue(text(100).hasSuffix("ملاحظة"), text(100))
        XCTAssertEqual(Set([0, 1, 2, 3, 11, 100].map(text)).count, 6)
    }

    func testBundleInfoStringsAreRealValuesNotCatalogKeys() {
        // An InfoPlist catalog entry without a value compiles to "key = key" and shows the key in the UI.
        let bundle = Bundle(for: NoteWindowController.self)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String, "© 2026 a-dev")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "RAMnotes")
    }

    func testPathIsolationWrapsTextInFirstStrongIsolates() {
        XCTAssertEqual(PathIsolation.isolate("~/Documents/a.txt"), "\u{2068}~/Documents/a.txt\u{2069}")
    }

    func testOperationErrorsFormatTypedCasesInPresentation() {
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertEqual(NoteOperationError.unfinishedMove(destination: url).localizedDescription,
                       "Finish the interrupted move to \u{2068}/tmp/a.txt\u{2069} before choosing another location.")
        XCTAssertEqual(NoteOperationError.moveInterrupted(underlying: nil).localizedDescription,
                       "The move was interrupted. Choose Move To… again to retry.")
        XCTAssertEqual(NoteOperationError.inputOutput("Save verification failed").localizedDescription, "Save verification failed")
    }

    func testNoteListStatusUsesOneFormatPerCase() {
        XCTAssertEqual(NoteListController.statusText(indexing: false, added: nil, resultCount: 4, unavailable: 0, hasNotes: true), "4 notes")
        XCTAssertEqual(NoteListController.statusText(indexing: false, added: nil, resultCount: 3, unavailable: 2, hasNotes: true), "3 results · 2 unavailable files")
        XCTAssertEqual(NoteListController.statusText(indexing: false, added: (2, 1), resultCount: 3, unavailable: 0, hasNotes: true), "Added 2 files. 1 hidden by the current search.")
        XCTAssertEqual(NoteListController.statusText(indexing: false, added: nil, resultCount: 0, unavailable: 0, hasNotes: true), "No matching notes.")
        XCTAssertEqual(NoteListController.statusText(indexing: false, added: nil, resultCount: 0, unavailable: 0, hasNotes: false), "")
    }

    func testTypographyNumbersParseDigitsEachLocaleDisplays() {
        for identifier in ["en_US", "de_DE", "fr_FR", "ar", "ar_EG", "ja_JP", "zh_Hans_CN"] {
            let locale = Locale(identifier: identifier)
            let displayed = 144.0.formatted(.number.precision(.fractionLength(0)).grouping(.never).locale(locale))
            XCTAssertEqual(TypographyNumber.parse(displayed, locale: locale), 144, identifier)
            XCTAssertEqual(TypographyNumber.parse("144", locale: locale), 144, identifier)
        }
        XCTAssertEqual(TypographyNumber.parse("١٤٤", locale: Locale(identifier: "ar")), 144)
        XCTAssertNil(TypographyNumber.parse("abc", locale: Locale(identifier: "ar")))
    }
}

private extension String {
    /// Formats the expected Arabic text with the locale's own digits for `count`.
    func replacingDigits(locale: Locale, for count: Int) -> String {
        let number = count.formatted(.number.locale(locale))
        return replacingOccurrences(of: String(count), with: number)
    }
}
