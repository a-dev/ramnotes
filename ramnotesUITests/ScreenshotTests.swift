import XCTest

/// Captures the main surfaces for the language chosen by the `Screenshots` test plan
/// configuration (Application Language and Region). Everything is located by position
/// or accessibility identifier, never by English text, so it runs in every language.
@MainActor
final class ScreenshotTests: XCTestCase {
    func testMainSurfacesInPlanLanguage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-session", UUID().uuidString]
        app.launch()
        defer { app.terminate() }

        let list = app.windows["Note list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        attach(list, "note-list")

        list.buttons["NoteListCommands"].click()
        attach(list, "commands-menu")
        app.typeKey(.escape, modifierFlags: [])

        list.buttons["NoteListSettings"].click()
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let rows = settings.tables.firstMatch.tableRows
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let pages = ["general", "appearance", "keyboard", "about"]
        for (index, page) in pages.enumerated() {
            rows.element(boundBy: index).click()
            if page == "about" {
                XCTAssertTrue(settings.images.firstMatch.waitForExistence(timeout: 5))
                continue
            }
            attach(settings, "settings-" + page)
        }
        // The Appearance popup lists System, Light, Dark in this order.
        rows.element(boundBy: 1).click()
        let popup = settings.popUpButtons.firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        for (index, theme) in ["light", "dark"].enumerated() {
            popup.click()
            settings.menuItems.element(boundBy: index + 1).click()
            rows.element(boundBy: 3).click()
            XCTAssertTrue(settings.images.firstMatch.waitForExistence(timeout: 5))
            attach(settings, "about-" + theme)
            rows.element(boundBy: 1).click()
        }
    }

    private func attach(_ element: XCUIElement, _ name: String) {
        let shot = XCTAttachment(screenshot: element.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
