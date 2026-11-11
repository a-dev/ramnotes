import XCTest
import AppKit
import Darwin

@MainActor
final class SettingsIntegrationTests: XCTestCase {
    func testUtilityWindowFramesPersistIndependentlyAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        defer { app.terminate() }
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))

        func moveAndResize(_ window: XCUIElement, move: CGVector, width: CGFloat) {
            let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
            title.click(forDuration: 0.1, thenDragTo: title.withOffset(move))
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: width, dy: 0)))
        }
        let initialList = list.frame
        moveAndResize(list, move: CGVector(dx: -70, dy: 20), width: 100)
        let savedList = list.frame
        XCTAssertGreaterThan(savedList.width, initialList.width + 50)
        list.buttons["Settings"].click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let initialSettings = settings.frame
        moveAndResize(settings, move: CGVector(dx: 0, dy: 0), width: 100)
        let savedSettings = settings.frame
        let frames = XCTAttachment(string: "List: \(initialList) -> \(savedList)\nSettings: \(initialSettings) -> \(savedSettings)")
        frames.lifetime = .keepAlways
        add(frames)
        XCTAssertGreaterThan(savedSettings.width, initialSettings.width + 30)
        XCTAssertNotEqual(savedList.origin, savedSettings.origin)
        app.typeKey("q", modifierFlags: .command)
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
        app.launch()
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["Settings"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for (actual, expected) in [(list.frame, savedList), (settings.frame, savedSettings)] {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 2)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 2)
            XCTAssertEqual(actual.width, expected.width, accuracy: 2)
            XCTAssertEqual(actual.height, expected.height, accuracy: 2)
        }
    }

    func testTypographyValidationAndPreferencesPersistAcrossControlledRestart() {
        let app = XCUIApplication()
        let launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launchArguments = launchArguments
        app.launch()

        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["Settings"].click()

        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.staticTexts["Appearance"].click()
        let fontSize = settings.textFields["Font size"]
        let lineHeight = settings.textFields["Line spacing"]
        let alwaysOnTop = settings.checkBoxes["Keep note windows on top"]
        XCTAssertTrue(fontSize.waitForExistence(timeout: 5))
        XCTAssertTrue(lineHeight.exists)

        fontSize.click()
        fontSize.typeKey("a", modifierFlags: .command)
        fontSize.typeText("nan")
        fontSize.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let validationError = settings.staticTexts["Typography validation"]
        let invalid = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard validationError.exists else { return false }
            return ((validationError.value as? String) ?? validationError.label).contains("Font size must be 8–192 points")
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [invalid], timeout: 5), .completed)
        XCTAssertTrue(app.state != .notRunning, "Invalid typography input should leave the app running")

        // Restore a valid size, then raise line height before increasing font size.
        fontSize.click()
        fontSize.typeKey("a", modifierFlags: .command)
        fontSize.typeText("20")
        fontSize.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        lineHeight.click()
        lineHeight.typeKey("a", modifierFlags: .command)
        lineHeight.typeText("32")
        lineHeight.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        fontSize.click()
        fontSize.typeKey("a", modifierFlags: .command)
        fontSize.typeText("24")
        fontSize.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        settings.staticTexts["Windows"].click()
        alwaysOnTop.click()

        XCTAssertEqual(checkboxValue(alwaysOnTop), 1)

        settings.buttons["Toggle notes shortcut"].click()
        app.typeKey("j", modifierFlags: [.command, .option, .control])
        assertShortcut(settings.buttons["Toggle notes shortcut"], app: app)

        app.typeKey("q", modifierFlags: .command)
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.state == .notRunning },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)

        app.launchArguments = launchArguments
        app.launch()
        let relaunchedList = app.windows["Note list"]
        XCTAssertTrue(relaunchedList.waitForExistence(timeout: 10))
        let settingsReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in relaunchedList.buttons["Settings"].isHittable }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [settingsReady], timeout: 5), .completed)
        relaunchedList.buttons["Settings"].click()

        let relaunchedSettings = app.windows["Settings"]
        XCTAssertTrue(relaunchedSettings.waitForExistence(timeout: 10))
        relaunchedSettings.staticTexts["Appearance"].click()
        let persistedFontSize = relaunchedSettings.textFields["Font size"]
        let persistedLineHeight = relaunchedSettings.textFields["Line spacing"]
        let persistedAlwaysOnTop = relaunchedSettings.checkBoxes["Keep note windows on top"]
        XCTAssertEqual(Double(persistedFontSize.value as? String ?? ""), 24)
        XCTAssertEqual(Double(persistedLineHeight.value as? String ?? ""), 32)
        relaunchedSettings.staticTexts["Windows"].click()
        XCTAssertEqual(checkboxValue(persistedAlwaysOnTop), 1)
        assertShortcut(relaunchedSettings.buttons["Toggle notes shortcut"], app: app)
    }
    func testLocationCancelRenameAndKeyboardFocusInBothAppearances() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("CP06 location preview")
        app.typeKey("w", modifierFlags: .command)
        let location = list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Change note location: ")).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Available notes open the Move To panel")
        XCTAssertFalse(app.textViews["Note text"].exists, "Location action must not open the note")
        XCTAssertFalse(app.windows["Note location"].exists)
        let panelImage = XCTAttachment(screenshot: app.screenshot())
        panelImage.name = "CP06 Move To panel"
        panelImage.lifetime = .keepAlways
        add(panelImage)
        let name = panel.textFields["saveAsNameTextField"]
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Cancelled draft.txt")
        panel.buttons["Cancel"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        location.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertNotEqual(name.value as? String, "Cancelled draft.txt")
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Renamed CP06.txt")
        // The panel may open in a different folder than the note's, so choose a fresh destination.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-cp06-move-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: destination) }
        chooseSavePanelFolder(destination, app: app)
        panel.buttons["Move"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 10))
        let renamed = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", "/Renamed CP06.txt")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 15))
        for theme in ["Light", "Dark"] {
            list.buttons["Settings"].click()
            let settings = app.windows["Settings"]
            settings.tables["Settings categories"].staticTexts["Appearance"].click()
            settings.popUpButtons["Color theme"].click()
            app.menuItems[theme].click()
            settings.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(renamed.isHittable)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "CP06 location card " + theme
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Dismissal returns the keyboard to the selected originating row.
        renamed.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.buttons["Cancel"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
    }

    func testDefaultFolderConfirmationCheckedCancelAndLeaveFilesInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("CP06 retained custom note")
        app.typeKey("w", modifierFlags: .command)
        let location = list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Change note location: ")).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        let originalPath = location.label
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-cp06-default-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: destination) }
        list.buttons["Settings"].click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        func selectDestination() {
            settings.buttons["Choose Default Folder…"].click()
            app.typeKey("g", modifierFlags: [.command, .shift])
            let go = app.sheets.firstMatch
            XCTAssertTrue(go.waitForExistence(timeout: 5))
            let clipboard = NSPasteboard.general
            let saved = (clipboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            clipboard.clearContents(); clipboard.setString(destination.path, forType: .string)
            app.typeKey("a", modifierFlags: .command); app.typeKey("v", modifierFlags: .command)
            app.typeKey(.return, modifierFlags: [])
            if !go.waitForNonExistence(timeout: 3) { app.typeKey(.return, modifierFlags: []) }
            XCTAssertTrue(go.waitForNonExistence(timeout: 5))
            clipboard.clearContents(); clipboard.writeObjects(saved)
            app.dialogs.buttons["Choose Notes Folder"].click()
            XCTAssertTrue(app.dialogs.buttons["Change Folder"].waitForExistence(timeout: 5))
        }
        selectDestination()
        let option = app.dialogs.checkBoxes["Move existing notes to the new location"]
        XCTAssertEqual(checkboxValue(option), 1)
        XCTAssertTrue(app.dialogs.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Notes with custom paths won’t be moved.", "Notes with custom paths won’t be moved.")).firstMatch.exists)
        app.dialogs.buttons["Cancel"].click()
        XCTAssertFalse(settings.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", destination.path)).firstMatch.exists)
        selectDestination()
        option.click()
        app.dialogs.buttons["Change Folder"].click()
        let selected = settings.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", destination.lastPathComponent, destination.lastPathComponent)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let retained = list.buttons.matching(NSPredicate(format: "label == %@", originalPath)).firstMatch
        XCTAssertTrue(retained.waitForExistence(timeout: 5))
        let customImage = XCTAttachment(screenshot: list.screenshot())
        customImage.name = "CP06 shortened custom path"
        customImage.lifetime = .keepAlways
        add(customImage)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        app.typeKey("q", modifierFlags: .command)
    }

    func testAddExistingCustomFileSaveAndRelaunch() throws {
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchArguments = ["--test-session", session] + englishLocaleArguments
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-custom-file-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Registered note.txt")
        let sibling = parent.appendingPathComponent("unselected.txt")
        try "Custom file content".write(to: target, atomically: true, encoding: .utf8)
        try "Unrelated sibling".write(to: sibling, atomically: true, encoding: .utf8)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: parent)
        }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["Add Existing Files"].click()
        let picker = app.dialogs["Add Existing Files"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        chooseNativePath(target, app: app, prompt: "Open")
        let custom = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", try fixtureDisplayPath(target))).firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 10))
        XCTAssertFalse(list.staticTexts["Unrelated sibling"].exists)

        custom.click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "An available custom note opens the Move To panel")
        XCTAssertFalse(app.windows["Note location"].exists)
        XCTAssertEqual(panel.textFields["saveAsNameTextField"].value as? String, "Registered note.txt")
        XCTAssertTrue(panel.buttons["Move"].exists)
        panel.buttons["Cancel"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Custom file content")

        list.staticTexts["Custom file content"].doubleClick()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        try UITestFixtureInput.replace("Updated custom file content", in: editor)
        app.typeKey("w", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: target, encoding: .utf8)) == "Updated custom file content"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Updated custom file content")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(list.buttons.matching(NSPredicate(format: "label CONTAINS %@", try fixtureDisplayPath(target))).firstMatch.waitForExistence(timeout: 10), "File bookmark must restore the custom note after relaunch")
        XCTAssertTrue(list.staticTexts["Updated custom file content"].exists)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Updated custom file content")
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "Unrelated sibling")
        app.typeKey("q", modifierFlags: .command)
    }

    func testMissingCustomFileCanBeRemovedFromList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-missing-file-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Missing note.txt")
        try "Registered missing-file fixture".write(to: target, atomically: true, encoding: .utf8)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: parent)
        }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["Add Existing Files"].click()
        let picker = app.dialogs["Add Existing Files"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        chooseNativePath(target, app: app, prompt: "Open")
        let pathLabel = try fixtureDisplayPath(target)
        let location = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", pathLabel)).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 10))

        location.click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "An available note opens the Move To panel, which has no Remove from List action")
        XCTAssertFalse(app.windows["Note location"].exists)
        panel.buttons["Cancel"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))

        try FileManager.default.removeItem(at: target)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(location.waitForExistence(timeout: 10), "A missing custom file must stay registered across restart")
        location.click()
        let dialog = app.windows["Note location"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let explanation = dialog.staticTexts["Location error"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertEqual(explanation.value as? String, "RAMnotes cannot find this file. Removing this entry does not delete any files.")
        let remove = dialog.buttons["Remove from List"]
        XCTAssertTrue(remove.exists)
        remove.click()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 10))
        XCTAssertTrue(location.waitForNonExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        app.typeKey("q", modifierFlags: .command)
    }

    func testRestoreFileAccessPickerCancellationAndRepair() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString, "--test-folder-access-fixture"] + englishLocaleArguments
        defer { app.terminate() }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let actions = list.buttons["Actions…"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        let repair = app.menuItems["Restore File Access…"]
        XCTAssertTrue(list.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "File access required", "File access required")).firstMatch.exists)
        let prefix = "Change note location: "
        let location = list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        let displayedPath = String(location.label.dropFirst(prefix.count))
        guard let account = getpwuid(getuid()) else { XCTFail("Cannot resolve the test user's home folder"); return }
        let home = String(cString: account.pointee.pw_dir)
        let path = displayedPath.hasPrefix("~/") ? home + displayedPath.dropFirst() : displayedPath
        let expectedFile = URL(fileURLWithPath: String(path))
        actions.click()
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        repair.click()
        let allow = app.dialogs.buttons["Allow Access"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        app.dialogs.buttons["Cancel"].click()
        actions.click()
        XCTAssertTrue(repair.waitForExistence(timeout: 5), "Cancelling keeps Restore File Access offered")
        repair.click()
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        chooseNativePath(expectedFile, app: app, prompt: "Allow Access")
        XCTAssertTrue(list.staticTexts["Folder repair UI content"].waitForExistence(timeout: 10))
        XCTAssertTrue(actions.waitForNonExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
    }

    private func fixtureDisplayPath(_ url: URL) throws -> String {
        let account = try XCTUnwrap(getpwuid(getuid()))
        let home = String(cString: account.pointee.pw_dir)
        return url.path.replacingOccurrences(of: home + "/", with: "~/", options: .anchored)
    }

    private func chooseNativePath(_ path: URL, app: XCUIApplication, prompt: String) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let go = app.sheets.firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        let pathField = go.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { clipboard.clearContents(); clipboard.writeObjects(saved) }
        clipboard.clearContents(); clipboard.setString(path.path, forType: .string)
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeKey("v", modifierFlags: .command)
        pathField.typeKey(.return, modifierFlags: [])
        let sheetRemains = !go.waitForNonExistence(timeout: 3)
        if sheetRemains && pathField.exists { pathField.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(go.waitForNonExistence(timeout: 5))
        // Return may already have accepted the picker. Callers verify the resulting path or repair.
        let choose = app.dialogs.buttons[prompt]
        if choose.exists { choose.click() }
    }

    private func chooseSavePanelFolder(_ folder: URL, app: XCUIApplication) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { clipboard.clearContents(); clipboard.writeObjects(saved) }
        clipboard.clearContents(); clipboard.setString(folder.path, forType: .string)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeKey("v", modifierFlags: .command)
        path.typeKey(.return, modifierFlags: [])
        if !path.waitForNonExistence(timeout: 3) { path.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }

    private func assertShortcut(_ recorder: XCUIElement, app: XCUIApplication) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            recorder.value as? String == "⌃⌥⌘J"
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
    }
    private func checkboxValue(_ element: XCUIElement) -> Int? {
        if let value = element.value as? NSNumber { return value.intValue }
        return Int(element.value as? String ?? "")
    }
}
