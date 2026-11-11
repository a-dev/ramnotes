import XCTest
import AppKit

@MainActor
final class WorkflowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testContextTrashCancellationKeepsNote() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        defer { app.terminate() }
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("A14 context cancellation")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        note.buttons["Note list"].click()
        let row = list.tables["Notes"].tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        list.menuItems["Move to Trash…"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "A14 context cancellation")
        note.buttons["Note list"].click()
        XCTAssertEqual(list.tables["Notes"].tableRows.count, 1)
    }

    func testEmptyListAddExistingIsKeyboardAccessibleAndCancellationKeepsListEmpty() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        defer { app.terminate() }
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let addExisting = list.buttons["Add Existing Files"]
        XCTAssertTrue(addExisting.waitForExistence(timeout: 5))
        XCTAssertTrue(list.staticTexts["Drop .txt files here, or add existing files."].exists)
        XCTAssertEqual(list.tables["Notes"].tableRows.count, 0)

        // Search receives initial focus. Tab through the list controls to the empty-state action.
        list.searchFields["Search notes"].click()
        // Query the focused element directly. Its debug description can report stale focus.
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        for _ in 0..<8 {
            app.typeKey(.tab, modifierFlags: [])
            if focused.waitForExistence(timeout: 1), focused.label == "Add Existing Files" { break }
        }
        XCTAssertEqual(focused.label, "Add Existing Files")
        app.typeKey(" ", modifierFlags: [])

        let picker = app.dialogs["Add Existing Files"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertEqual(list.tables["Notes"].tableRows.count, 0)
        XCTAssertTrue(addExisting.exists)
    }

    func testMoveToPickerCancellationLeavesOriginalNoteUnchanged() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        defer { app.terminate() }
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("A15 Move To cancellation")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        note.buttons["Note list"].click()

        let row = list.tables["Notes"].tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        list.menuItems["Move To…"].click()
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.staticTexts["Choose a name and location for this note. The original file will be moved, and the note will stay open."].exists)
        XCTAssertTrue(picker.buttons["Move"].exists)
        picker.buttons["Cancel"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "A15 Move To cancellation")
        XCTAssertEqual(list.tables["Notes"].tableRows.count, 1)
        XCTAssertFalse(list.buttons["Add Existing Files"].exists)
        XCTAssertTrue(row.staticTexts["A15 Move To cancellation"].exists)
    }

    func testMoveToExternalFileKeepsEditorAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-move-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("Move keeps this editor")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        note.buttons["Note list"].click()
        list.tables["Notes"].tableRows.firstMatch.rightClick()
        list.menuItems["Move To…"].click()
        let picker = app.sheets["save-panel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let name = picker.textFields["saveAsNameTextField"]
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Moved note.txt")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { clipboard.clearContents(); clipboard.writeObjects(savedClipboard) }
        clipboard.clearContents()
        clipboard.setString(directory.path, forType: .string)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeKey("v", modifierFlags: .command)
        path.typeKey(.return, modifierFlags: [])
        if !path.waitForNonExistence(timeout: 3) { path.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
        picker.buttons["Move"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        let target = directory.appendingPathComponent("Moved note.txt")
        let written = NSPredicate { _, _ in
            (try? String(contentsOf: target, encoding: .utf8)) == "Move keeps this editor"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 10), .completed)
        XCTAssertEqual(editor.value as? String, "Move keeps this editor")
        XCTAssertEqual(list.tables["Notes"].tableRows.count, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Move keeps this editor")
        app.windows.containing(.textView, identifier: "Note text").firstMatch.buttons["Note list"].click()
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.tables["Notes"].tableRows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(list.tables["Notes"].tableRows.count, 1)
        XCTAssertTrue(list.tables["Notes"].tableRows.firstMatch.staticTexts["Move keeps this editor"].exists)
    }

    func testNarrowWindowLightDarkAndFocusAfterCancelledTrash() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("AR11 narrow window")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        let corner = note.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -400, dy: 0)))
        XCTAssertEqual(note.frame.width, 375, accuracy: 2)
        for theme in ["Light", "Dark"] {
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tables["Settings categories"].staticTexts["Appearance"].click()
            settings.popUpButtons["Color theme"].click()
            app.menuItems[theme].click()
            settings.buttons[XCUIIdentifierCloseWindow].click()
            for action in ["New Note", "Note list", "Move to Trash", "Background tint", "Increase Font Size", "Decrease Font Size"] {
                XCTAssertTrue(note.buttons[action].isHittable, action)
            }
            note.buttons["Background tint"].click()
            app.typeKey(.escape, modifierFlags: [])
            editor.click()
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "375-point note " + theme
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        editor.click()
        editor.typeKey(.end, modifierFlags: .command)
        note.buttons["Move to Trash"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        app.typeText(" focus returned")
        XCTAssertEqual(editor.value as? String, "AR11 narrow window focus returned")
        app.typeKey("q", modifierFlags: .command)
    }

    func testNoteListWidensSearchAndKeepsSelectedRow() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        defer { app.typeKey("q", modifierFlags: .command) }

        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("A08 disposable resize fixture with a preview that can expand")
        let noteWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        noteWindow.buttons["Note list"].click()

        let search = list.searchFields["Search notes"]
        search.click()
        search.typeText("A08 disposable resize fixture")
        app.typeKey(.downArrow, modifierFlags: [])
        let row = list.tables["Notes"].descendants(matching: .tableRow).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isSelected)
        let originalWidth = list.frame.width
        let originalSearchWidth = search.frame.width
        let originalRowWidth = row.frame.width

        let bottomRight = list.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        bottomRight.click(forDuration: 0.1, thenDragTo: bottomRight.withOffset(CGVector(dx: 180, dy: 0)))

        XCTAssertGreaterThan(list.frame.width, originalWidth + 100)
        XCTAssertGreaterThan(search.frame.width, originalSearchWidth + 100)
        XCTAssertGreaterThan(row.frame.width, originalRowWidth + 100)
        XCTAssertTrue(row.isSelected)
    }

    func testColorSurfacesAndSelectionAcrossAppearances() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        defer { app.typeKey("q", modifierFlags: .command) }
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let listTitle = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        listTitle.click(forDuration: 0.1, thenDragTo: listTitle.withOffset(CGVector(dx: 430, dy: 0)))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("A06 disposable color fixture https://example.com")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        for theme in ["Light", "Dark"] {
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tables["Settings categories"].staticTexts["Appearance"].click()
            settings.popUpButtons["Color theme"].click()
            app.menuItems[theme].click()
            settings.buttons[XCUIIdentifierCloseWindow].click()
            editor.click()
            for tone in ["No color", "Gray", "Blue", "Green", "Yellow", "Red", "Purple"] {
                note.buttons["Background tint"].click()
                note.menuItems[tone].click()
                XCTAssertEqual(note.buttons["Background tint"].value as? String, tone)
                XCTAssertEqual(editor.value as? String, "A06 disposable color fixture https://example.com")
                let attachment = XCTAttachment(screenshot: note.screenshot())
                attachment.name = "A06 " + theme + " " + tone
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            note.buttons["Note list"].click()
            let search = list.searchFields["Search notes"]
            search.click()
            search.typeText("A06 disposable")
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(list.tables["Notes"].descendants(matching: .tableRow).firstMatch.isSelected)
            for active in [true, false] {
                if !active { editor.click() }
                let attachment = XCTAttachment(screenshot: list.screenshot())
                attachment.name = "A06 " + theme + (active ? " active selection" : " inactive selection")
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(list.tables["Notes"].descendants(matching: .tableRow).firstMatch.isSelected)
            }
            note.buttons["Note list"].click()
            search.click()
            search.typeKey("a", modifierFlags: .command)
            search.typeKey(.delete, modifierFlags: [])
        }
    }

    func testRecoveryActionsFitAtNarrowMinimumWindowSize() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session, "--test-recovery-layout-fixture"] + englishLocaleArguments
        app.launch()
        defer {
            if app.state != .notRunning {
                app.activate()
                app.typeKey("q", modifierFlags: .command)
                let terminated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: app)
                if XCTWaiter.wait(for: [terminated], timeout: 5) != .completed { app.terminate() }
            }
        }
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertEqual(note.frame.width, 375, accuracy: 2)
        XCTAssertLessThanOrEqual(note.frame.height, 280, "The fixture should stay at the supported minimum-height size")
        for title in ["Export"] {
            let action = note.buttons[title]
            XCTAssertTrue(action.waitForExistence(timeout: 5), title)
            XCTAssertTrue(action.isHittable, title)
            XCTAssertTrue(note.frame.contains(action.frame), "\(title) should fit inside the note window")
        }

        XCTAssertFalse(note.menuButtons["More Recovery Actions"].exists, "Recovery actions are buttons, not a menu")
        XCTAssertFalse(note.buttons["Locate File…"].exists, "Locate File applies only to a missing file")
        for title in ["Open Original", "Open Recovery"] {
            let action = note.buttons[title]
            XCTAssertTrue(action.waitForExistence(timeout: 5), title)
            XCTAssertTrue(action.isHittable, title)
            XCTAssertTrue(note.frame.contains(action.frame), "\(title) should fit inside the note window")
        }
        let isolation = XCTAttachment(string: "Debug test-session UUID: \(session)\nApp support folder name: ramnotes-ui-\(session)\nFixture writes are guarded to the app container's temporary Notes folder.")
        isolation.name = "A04 isolated fixture session"
        isolation.lifetime = .keepAlways
        add(isolation)
        let screenshot = XCTAttachment(screenshot: note.screenshot())
        screenshot.name = "Recovery actions at 375 by 260"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCommandClickAfterUndoAndExternalReload() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        chooseFolder(folder, app: app)
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        try UITestFixtureInput.replace("https://example.org/", in: editor)
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("plain text")
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "https://example.org/")
        try commandClickLink(editor, app: app, label: "After native Undo")
        editor.click()
        editor.typeKey("w", modifierFlags: .command)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "txt" })
        list.staticTexts["https://example.org/"].doubleClick()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        try "https://example.com/".write(to: file, atomically: true, encoding: .utf8)
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.value as? String == "https://example.com/"
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 10), .completed)
        try commandClickLink(editor, app: app, label: "After external reload")
    }

    private func commandClickLink(_ editor: XCUIElement, app: XCUIApplication, label: String) throws {
        let url = try XCTUnwrap(URL(string: editor.value as? String ?? ""))
        let browserURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(toOpen: url))
        let browserID = try XCTUnwrap(Bundle(url: browserURL)?.bundleIdentifier)
        let link = editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 12))
        XCUIElement.perform(withKeyModifiers: .command) {
            link.hover()
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = label + " Command-hover"
            attachment.lifetime = .keepAlways
            add(attachment)
            link.click()
        }
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browserID
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 10), .completed)
        app.activate()
    }

    func testHiddenListEditsExternalReloadRenameAndUnavailableRecovery() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        chooseFolder(folder, app: app)
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        list.buttons[XCUIIdentifierCloseWindow].click()
        editor.click()
        editor.typeText("AR11 hidden edit https://example.org/old")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        note.buttons["Note list"].click()
        XCTAssertTrue(list.staticTexts["AR11 hidden edit https://example.org/old"].waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("w", modifierFlags: .command)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
        let original = try XCTUnwrap(files.first)
        let renamed = folder.appendingPathComponent("external-renamed.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        try "AR11 external reload https://example.org/new".write(to: renamed, atomically: true, encoding: .utf8)
        let row = list.staticTexts["AR11 external reload https://example.org/new"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.doubleClick()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "AR11 external reload https://example.org/new")
        editor.click()
        editor.typeKey("w", modifierFlags: .command)
        let unavailable = folder.appendingPathComponent("unavailable.txt")
        try Data([0xff, 0xfe, 0xff]).write(to: unavailable)
        let actions = list.buttons["Actions…"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertTrue(list.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Unsupported text encoding", "Unsupported text encoding")).firstMatch.exists)
        actions.click()
        XCTAssertTrue(app.menuItems["Locate File…"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        try "AR11 repaired available content".write(to: unavailable, atomically: true, encoding: .utf8)
        XCTAssertTrue(list.staticTexts["AR11 repaired available content"].waitForExistence(timeout: 10))
        XCTAssertFalse(actions.exists)
        try FileManager.default.removeItem(at: renamed)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !row.exists }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
    }

    func testListCommandZDoesNotRestoreTrashedFile() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        chooseFolder(folder, app: app)
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("AR11 list undo safety")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        note.buttons["Move to Trash"].click()
        app.sheets.firstMatch.buttons["Move to Trash"].click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !note.exists }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)

        list.tables.firstMatch.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(app.textViews["Note text"].waitForExistence(timeout: 2))
        XCTAssertFalse(list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Undo Delete: ")).firstMatch.exists)
        XCTAssertFalse(list.staticTexts["AR11 list undo safety"].exists)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.pathExtension == "txt" })
    }

    func testTextUndoRedoKeyboardShortcuts() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("original")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("replacement")
        XCTAssertEqual(editor.value as? String, "replacement")
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "original")
        editor.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, "replacement")

        let noteWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        noteWindow.buttons["Note list"].click()
        let search = list.searchFields["Search notes"]
        search.click()
        search.typeText("seed")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("updated")
        XCTAssertEqual(search.value as? String, "updated")
        search.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(search.value as? String, "seed")
        search.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(search.value as? String, "updated")
    }

    func testCreateHideRevealSearchCloseReopenTrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.ramnotes.RAMnotes").count == 1 else {
            XCTFail("Quit other RAMnotes builds normally before testing global shortcuts.")
            return
        }
        XCTAssertFalse(list.staticTexts["Toggle notes: ⌃⌥⌘N"].exists)
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let text = "Integration sapphire " + UUID().uuidString
        try UITestFixtureInput.replace(text, in: editor)
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(list.staticTexts[text].waitForExistence(timeout: 10))
        // The independent Settings window keeps the app active while the group is hidden.
        list.buttons["Settings"].click()
        toggle(app)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !note.exists && !list.exists }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        toggle(app)
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in note.isHittable }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 5), .completed)
        note.buttons["Note list"].click()
        let search = list.searchFields["Search notes"]
        app.typeText("SAPPHIRE integration")
        XCTAssertEqual(search.value as? String, "SAPPHIRE integration")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, text)
        editor.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !note.isHittable }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        XCTAssertFalse(list.buttons["Enable Eye"].exists)
        list.staticTexts[text].doubleClick()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        toggle(app)
        toggle(app)
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in note.isHittable }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 5), .completed)
        note.buttons["Move to Trash"].click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Move to Trash"].click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !note.exists && !list.staticTexts[text].exists }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Undo Delete: ")).firstMatch.exists)
        XCTAssertFalse(list.staticTexts[text].exists)
        XCTAssertFalse(editor.exists)
    }
    func testDeepBodySnippetAndQueryClearing() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let title = "Deep body acceptance"
        let marker = "zirconneedle"
        editor.click()
        editor.typeText(title + "\n" + String(repeating: "ordinary filler words ", count: 30) + marker)
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        note.buttons["Note list"].click()
        let search = list.searchFields["Search notes"]
        app.typeText(marker)
        let snippet = list.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", marker, marker)).firstMatch
        XCTAssertTrue(snippet.waitForExistence(timeout: 10))
        XCTAssertFalse(snippet.label.hasPrefix(title))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("absent-marker")
        XCTAssertTrue(list.staticTexts["No matching notes."].waitForExistence(timeout: 10))
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        let leadingPreview = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(leadingPreview.waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains(marker))
    }

    func testDeepUnicodeSelectionRestoresAcrossCloseAndRestart() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        let text = "Deep selection fixture\n" + (0..<200).map { "Paragraph \($0) 😀" }.joined(separator: "\n") + "\nTAIL"
        try text.write(to: folder.appendingPathComponent("Deep.txt"), atomically: true, encoding: .utf8)
        app.launch()
        chooseFolder(folder, app: app)
        let list = app.windows["Note list"]
        let row = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Deep selection fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.doubleClick()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        for _ in 0..<4 { editor.typeKey(.leftArrow, modifierFlags: .shift) }
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        row.doubleClick()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let reopened = XCTAttachment(screenshot: app.screenshot())
        reopened.name = "Deep Unicode selection after close and reopen"
        reopened.lifetime = .keepAlways
        add(reopened)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let restarted = XCTAttachment(screenshot: app.screenshot())
        restarted.name = "Deep Unicode selection after restart"
        restarted.lifetime = .keepAlways
        add(restarted)
        app.typeText("RESTORED")
        XCTAssertEqual(editor.value as? String, String(text.dropLast(4)) + "RESTORED",
            "Typing must replace the restored nonempty selection in the focused editor")
    }

    func testGroupAndRestartFocusFollowsBlueAfterEditingGreen() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        for color in ["Blue", "Green", "Yellow"] {
            try (color + "\nbody").write(to: folder.appendingPathComponent(color + ".txt"), atomically: true, encoding: .utf8)
        }
        app.launch()
        chooseFolder(folder, app: app)
        let list = app.windows["Note list"]
        for color in ["Blue", "Green", "Yellow"] {
            let row = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", color + " ")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.doubleClick()
            XCTAssertTrue(app.windows[color].textViews["Note text"].waitForExistence(timeout: 10))
            app.windows[color].buttons["Note list"].click()
        }
        let green = app.windows["Green"].textViews["Note text"]
        green.click()
        green.typeKey(.downArrow, modifierFlags: .command)
        green.typeText(" edited")
        let blue = app.windows["Blue"].textViews["Note text"]
        blue.click()
        blue.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 10))
        toggle(app)
        XCTAssertTrue(app.windows["Blue"].waitForNonExistence(timeout: 10))
        toggle(app)
        XCTAssertTrue(blue.waitForExistence(timeout: 10))
        app.typeText(" revealed")
        XCTAssertEqual(blue.value as? String, "Blue\nbody revealed")
        XCTAssertEqual(green.value as? String, "Green\nbody edited")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(blue.waitForExistence(timeout: 10))
        app.typeText(" restarted")
        XCTAssertEqual(blue.value as? String, "Blue\nbody revealed restarted")
        XCTAssertEqual(green.value as? String, "Green\nbody edited")
    }

    func testGroupShortcutReturnsToLastCaretPlacementWithoutSettingsWindow() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        for color in ["Blue", "Green", "Yellow"] {
            try (color + "\nbody").write(to: folder.appendingPathComponent(color + ".txt"), atomically: true, encoding: .utf8)
        }
        app.launch()
        chooseFolder(folder, app: app)
        let list = app.windows["Note list"]
        for color in ["Blue", "Green", "Yellow"] {
            let row = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", color + " ")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.doubleClick()
            XCTAssertTrue(app.windows[color].textViews["Note text"].waitForExistence(timeout: 10))
            app.windows[color].buttons["Note list"].click()
        }
        for color in ["Green", "Blue", "Yellow"] {
            let editor = app.windows[color].textViews["Note text"]
            editor.click()
            editor.typeKey(.downArrow, modifierFlags: .command)
            editor.typeKey(.leftArrow, modifierFlags: [])
            toggle(app)
            XCTAssertTrue(app.windows[color].waitForNonExistence(timeout: 10))
            toggle(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            app.typeText("X")
            XCTAssertEqual(editor.value as? String, color + "\nbodXy")
        }
    }

    func testExternalNoticePersistsAcrossRestartAndRequiresExplicitEditing() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let root = try sessionRoot(session)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes")
        chooseFolder(folder, app: app)
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        try UITestFixtureInput.replace("Original position fixture", in: editor)
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "txt" })
        let replacement = "External position fixture\n" + (0..<200).map { "Line \($0) 😀" }.joined(separator: "\n")
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        let row = list.tables["Notes"].tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.doubleClick()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, replacement)
        let notice = app.staticTexts["externalChangeNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        app.typeText("x")
        XCTAssertEqual(editor.value as? String, replacement, "Automatic window focus must not activate the editor")
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.tables["Notes"].tableRows.firstMatch.doubleClick()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        app.typeText("x")
        XCTAssertEqual(editor.value as? String, replacement)
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        let oldDescription = notice.value as? String
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: file.path)
        let touched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            notice.exists && notice.value as? String != oldDescription
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [touched], timeout: 10), .completed)
        app.typeText("x")
        XCTAssertEqual(editor.value as? String, replacement, "A visible same-text backward timestamp change must remove the active caret")
        XCTAssertTrue((notice.value as? String)?.contains("Changed outside RAMnotes") == true)
        try "Visible external replacement".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: file.path)
        let visibleReload = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Visible external replacement"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleReload], timeout: 10), .completed)
        app.typeText("x")
        XCTAssertEqual(editor.value as? String, "Visible external replacement")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        let corner = note.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -400, dy: 0)))
        XCTAssertEqual(note.frame.width, 375, accuracy: 2)
        XCTAssertTrue(notice.isHittable)
        let narrow = XCTAttachment(screenshot: app.screenshot())
        narrow.name = "External notice at 375 points with an older timestamp"
        narrow.lifetime = .keepAlways
        add(narrow)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 10))
        toggle(app)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
        try "Hidden external replacement".write(to: file, atomically: true, encoding: .utf8)
        toggle(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let hiddenReload = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Hidden external replacement"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenReload], timeout: 10), .completed)
        XCTAssertTrue(notice.exists)
        app.typeText("x")
        XCTAssertEqual(editor.value as? String, "Hidden external replacement")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(notice.exists, "Selection must retain the notice")
        editor.typeText("Saved subsequent local edit")
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Saved subsequent local edit")
    }

    private func sessionRoot(_ session: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-desktop-" + session)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        return root
    }

    private func chooseFolder(_ folder: URL, app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tables["Settings categories"].staticTexts["General"].click()
        settings.buttons["Choose Default Folder…"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToFolder = app.sheets.firstMatch
        XCTAssertTrue(goToFolder.waitForExistence(timeout: 5))
        // Go to Folder autocomplete can change the text between typed characters.
        // Paste the whole path at once, and restore the user's clipboard.
        let clipboard = NSPasteboard.general
        let savedItems = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            clipboard.clearContents()
            clipboard.writeObjects(savedItems)
        }
        clipboard.clearContents()
        clipboard.setString(folder.path, forType: .string)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        if !goToFolder.waitForNonExistence(timeout: 3) {
            // The first Return can accept an autocomplete suggestion while the
            // Go to Folder sheet is still open. Commit that path before choosing.
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(goToFolder.waitForNonExistence(timeout: 5))
        }
        let confirm = app.dialogs.buttons["Change Folder"]
        // Return can accept the native picker as well as the Go to Folder sheet.
        if !confirm.exists {
            let choose = app.dialogs.buttons["Choose Notes Folder"]
            XCTAssertTrue(choose.waitForExistence(timeout: 5))
            choose.click()
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let suffix = folder.deletingLastPathComponent().lastPathComponent + "/" + folder.lastPathComponent
        let selected = settings.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", suffix, suffix)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 20))
        settings.buttons[XCUIIdentifierCloseWindow].click()
    }

    private func toggle(_ app: XCUIApplication) {
        // Accessory apps do not own a visible menu bar. Exercise the registered
        // default shortcut while the independent Settings window stays active.
        app.typeKey("\\", modifierFlags: .control)
    }
}

/// Use exact fixture text here. Separate tests cover typing and input methods.
@MainActor
enum UITestFixtureInput {
    static func replace(_ text: String, in control: XCUIElement) throws {
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { clipboard.clearContents(); clipboard.writeObjects(saved) }
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        control.click()
        control.typeKey("a", modifierFlags: .command)
        control.typeKey("v", modifierFlags: .command)
        let exactValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: control)
        guard XCTWaiter.wait(for: [exactValue], timeout: 5) == .completed else {
            throw NSError(domain: "UITestFixtureInput", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture input mismatch: expected \(text.debugDescription), got \(String(describing: control.value))"])
        }
    }
}
