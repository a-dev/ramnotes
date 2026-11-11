import XCTest

/// Pins English UI tests to the English locale so label queries stay stable.
let englishLocaleArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

@MainActor final class LaunchTests: XCTestCase {
    func testRevealWithListKeepsSearchFocusedAfterNotesFinishRevealing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        defer { app.terminate() }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("Reveal focus fixture")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
        app.typeKey("\\", modifierFlags: [.control, .command])
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        // Let asynchronous file verification and window presentation finish before typing.
        Thread.sleep(forTimeInterval: 1)
        app.typeText("focus query")
        XCTAssertEqual(list.searchFields["Search notes"].value as? String, "focus query")
        XCTAssertEqual(editor.value as? String, "Reveal focus fixture")
    }

    func testCommandsAreDiscoverableWithoutDockOrStatusIcon() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        defer { app.terminate() }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["Commands"].click()
        for title in ["RAMnotes", "File", "Edit", "View", "Window", "Help"] {
            XCTAssertTrue(list.menuItems[title].exists, title)
        }
        list.menuItems["File"].click()
        XCTAssertFalse(list.menuItems["Move to Trash…"].isEnabled)
        list.menuItems["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("A07 disposable commands fixture")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        app.typeKey("?", modifierFlags: [.command, .shift])
        XCTAssertTrue(note.menuItems["View"].waitForExistence(timeout: 5))
        note.menuItems["File"].click()
        XCTAssertTrue(note.menuItems["Move to Trash…"].isEnabled)
        note.menuItems["Move to Trash…"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        app.typeKey("?", modifierFlags: [.command, .shift])
        note.menuItems["Help"].click()
        XCTAssertTrue(note.menuItems["RAMnotes Help"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Captures native AX evidence; this does not establish assistive-technology traversal or speech.
    func testAccessibilitySurfaceInventory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        defer { app.terminate() }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("A01 disposable accessibility fixture")
        let note = app.windows.containing(.textView, identifier: "Note text").firstMatch
        for label in ["New Note", "Note list", "Move to Trash", "Background tint", "Increase Font Size", "Decrease Font Size"] {
            XCTAssertEqual(note.buttons.matching(identifier: label).count, 1, label)
            XCTAssertTrue(note.buttons[label].isHittable, label)
        }
        captureAccessibility(note, named: "Note header and editor")
        note.buttons["Background tint"].click()
        captureAccessibility(app, named: "Tint menu")
        app.typeKey(.escape, modifierFlags: [])
        note.buttons["Note list"].click()
        XCTAssertTrue(list.staticTexts["A01 disposable accessibility fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Change note location: ")).firstMatch.exists)
        captureAccessibility(list, named: "Note list with row location")
        list.buttons["Settings"].click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for page in ["General", "Windows", "Appearance", "Shortcuts", "About"] {
            settings.tables["Settings categories"].staticTexts[page].click()
            captureAccessibility(settings, named: "Settings " + page)
        }
        settings.tables["Settings categories"].staticTexts["Windows"].click()
        let recorder = settings.buttons["Toggle notes shortcut"]
        let original = recorder.value as? String
        recorder.click()
        app.typeKey("a", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Include ⌘, ⌥, or ⌃"].waitForExistence(timeout: 5))
        captureAccessibility(app, named: "Shortcut invalid input")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(recorder.value as? String, original)
        XCTAssertTrue(settings.isHittable)
    }

    private func captureAccessibility(_ element: XCUIElement, named name: String) {
        let tree = XCTAttachment(string: element.debugDescription)
        tree.name = name + " accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: element.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testOpenLinkContextMenuFollowsKeyboardSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        defer { app.terminate() }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("https://example.com")
        editor.typeKey("a", modifierFlags: .command)
        editor.rightClick()
        XCTAssertEqual(editor.menuItems.matching(identifier: "openLink:").count, 1)
        XCTAssertTrue(editor.menuItems["openLink:"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        editor.typeText("plain text")
        editor.rightClick()
        XCTAssertFalse(editor.menuItems["openLink:"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testManualLaunchShowsListAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        app.launch()
        let listVisible = app.windows["Note list"].waitForExistence(timeout: 5)
        XCTAssertTrue(listVisible)
        let settingsButtonVisible = app.windows["Note list"].buttons["Settings"].exists
        XCTAssertTrue(settingsButtonVisible)
        app.windows["Note list"].buttons["Settings"].click()
        let settingsVisible = app.windows["Settings"].waitForExistence(timeout: 5)
        XCTAssertTrue(settingsVisible)
        let quitVisible = app.windows["Settings"].buttons["Quit RAMnotes"].exists
        XCTAssertTrue(quitVisible)
    }

    func testLoginLaunchStartsHidden() {
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments(loginLaunch: true)
        app.launch()
        let listVisible = app.windows["Note list"].exists
        XCTAssertFalse(listVisible)
    }

    func testNewNoteCloseReopenAndDirectHeaderActions() {
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        app.launch()

        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let newNoteButton = list.buttons["New Note"]
        XCTAssertTrue(newNoteButton.waitForExistence(timeout: 5))
        newNoteButton.click()

        let noteText = app.textViews["Note text"]
        XCTAssertTrue(noteText.waitForExistence(timeout: 10))
        let noteWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(noteWindow.waitForExistence(timeout: 5))
        for title in ["New Note", "Note list", "Move to Trash"] {
            XCTAssertTrue(noteWindow.buttons[title].waitForExistence(timeout: 5), "Missing note header button: \(title)")
        }

        let noteBody = "UI workflow note"
        noteText.click()
        noteText.typeText(noteBody)
        let noteRow = list.staticTexts[noteBody]
        XCTAssertTrue(noteRow.waitForExistence(timeout: 10))

        noteText.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !noteWindow.isHittable }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        XCTAssertFalse(list.buttons["Enable Eye"].exists)
        XCTAssertFalse(noteWindow.isHittable, "Command-W should hide the note window")

        noteRow.doubleClick()
        let reopenedText = app.textViews["Note text"]
        XCTAssertTrue(reopenedText.waitForExistence(timeout: 10))
        let reopenedWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(reopenedWindow.waitForExistence(timeout: 5))
        XCTAssertFalse(reopenedWindow.checkBoxes["Eye"].exists)

        XCTAssertTrue(reopenedWindow.buttons["Move to Trash"].exists)
        XCTAssertFalse(reopenedWindow.buttons["More"].exists)
        XCTAssertFalse(reopenedWindow.buttons["Settings"].exists)
    }

    func testKeyboardSearchOpensMatchingNoteAndKeepsEmptyResultsActionable() throws {
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        app.launch()

        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()

        let noteText = app.textViews["Note text"]
        XCTAssertTrue(noteText.waitForExistence(timeout: 10))
        let noteWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(noteWindow.waitForExistence(timeout: 5))
        let uniqueBody = "Mixed Quartz \(UUID().uuidString) keyboard search note"
        try UITestFixtureInput.replace(uniqueBody, in: noteText)
        XCTAssertTrue(list.staticTexts[uniqueBody].waitForExistence(timeout: 10))

        noteWindow.buttons["Note list"].click()
        let searchField = list.searchFields["Search notes"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        // showList() should focus search, so send the query without clicking the field.
        app.typeText("mIxEd qUaRtZ")
        XCTAssertEqual(searchField.value as? String, "mIxEd qUaRtZ")
        XCTAssertTrue(list.staticTexts[uniqueBody].waitForExistence(timeout: 10))

        searchField.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        searchField.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        let reopenedWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(reopenedWindow.waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.windows.containing(.textView, identifier: "Note text").count,
            1,
            "Opening a search result should reuse the existing note window"
        )
        XCTAssertEqual(app.textViews["Note text"].value as? String, uniqueBody)

        reopenedWindow.buttons["Note list"].click()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("no-such-search-result-\(UUID().uuidString)")

        XCTAssertTrue(list.staticTexts["No matching notes."].waitForExistence(timeout: 10))
        XCTAssertFalse(list.staticTexts[uniqueBody].exists)
        XCTAssertTrue(list.buttons["New Note"].isEnabled)
        XCTAssertTrue(list.buttons["Settings"].isEnabled)
    }

    func testDeleteDisposableNoteFromList() {
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let noteWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(noteWindow.waitForExistence(timeout: 10))
        noteWindow.buttons["Move to Trash"].click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts["The original file will be moved to Trash. You can restore it in Finder."].exists)
        confirmation.buttons["Move to Trash"].click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !noteWindow.exists }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(list.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Undo Delete: ")).firstMatch.exists)
        XCTAssertFalse(app.textViews["Note text"].exists)
    }

    func testBlankNoteSurvivesControlledQuitAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = isolatedSessionArguments()
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.buttons["New Note"].click()
        let noteWindow = app.windows.containing(.textView, identifier: "Note text").firstMatch
        XCTAssertTrue(noteWindow.waitForExistence(timeout: 10))
        let row = list.staticTexts["Empty note"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.windows.containing(.textView, identifier: "Note text").firstMatch.buttons["Note list"].click()
        list.buttons["Settings"].click()
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.buttons["Quit RAMnotes"].click()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
        app.launch()
        XCTAssertTrue(app.textViews["Note text"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.windows["Note list"].exists)
        XCTAssertEqual(app.textViews["Note text"].value as? String, "")

        app.windows.containing(.textView, identifier: "Note text").firstMatch.buttons["Note list"].click()
        list.buttons["Settings"].click()
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
        app.windows["Settings"].buttons["Quit RAMnotes"].click()
        let quitAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [quitAgain], timeout: 10), .completed)
        app.launchArguments.append("--login-launch")
        app.launch()
        let unexpectedWindow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.count > 0 }, object: app)
        unexpectedWindow.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedWindow], timeout: 3), .completed,
                       "Login launch must stay hidden even with saved active notes")
    }

    /// Arabic smoke test. Every other UI test stays pinned to English.
    /// `-AppleTextDirection YES` is needed because an Arabic launch argument on an
    /// English system localizes text but does not flip the layout direction by itself.
    func testArabicLaunchMirrorsWindowAndLocalizesMenuAndSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString, "-AppleLanguages", "(ar)", "-AppleLocale", "ar",
                               "-AppleTextDirection", "YES"]
        defer { app.terminate() }
        app.launch()
        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let settingsButton = list.buttons["NoteListSettings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        // English puts Settings at the trailing (right) edge; mirrored it must sit on the left half.
        XCTAssertLessThan(settingsButton.frame.midX, list.frame.midX, "Settings button was not mirrored")
        XCTAssertGreaterThan(list.buttons["NoteListCommands"].frame.midX, settingsButton.frame.midX)

        list.buttons["NoteListCommands"].click()
        let titles = list.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
        XCTAssertFalse(titles.isEmpty)
        let english: Set<String> = ["File", "Edit", "View", "Window", "Help", "Format", "Find", "Services", "New Note", "Settings"]
        XCTAssertTrue(english.isDisjoint(with: titles), "English fallback in menu titles: \(titles)")
        app.typeKey(.escape, modifierFlags: [])

        settingsButton.click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertNotEqual(settings.title, "Settings")
        XCTAssertFalse(settings.title.isEmpty)
    }

    private func isolatedSessionArguments(loginLaunch: Bool = false) -> [String] {
        var arguments = ["--test-session", UUID().uuidString] + englishLocaleArguments
        if loginLaunch { arguments.append("--login-launch") }
        return arguments
    }
}
