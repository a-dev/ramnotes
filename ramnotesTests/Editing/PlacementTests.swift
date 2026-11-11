import Foundation
import XCTest
@testable import ramnotes

final class PlacementTests: XCTestCase {
    func testReachableSavedFrameRemainsOnItsSavedDisplay() {
        let displays = [
            WindowDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)),
            WindowDisplay(id: 2, visibleFrame: CGRect(x: 1200, y: 0, width: 1000, height: 800))
        ]
        let saved = CGRect(x: 1450, y: 120, width: 620, height: 480)

        let result = WindowPlacement.restore(frame: saved, displayID: 2, displays: displays, currentDisplayID: 1)

        XCTAssertEqual(result, saved)
    }

    func testOversizedFrameIsResizedToFitVisibleArea() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)

        let result = WindowPlacement.restore(
            frame: CGRect(x: 100, y: 100, width: 1600, height: 1200), displayID: 1,
            displays: [WindowDisplay(id: 1, visibleFrame: screen)], currentDisplayID: nil
        )

        XCTAssertEqual(result, screen)
    }

    func testNegativeSavedOriginClampsToSelectedDisplayAmongMultipleDisplays() {
        let leftScreen = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let displays = [
            WindowDisplay(id: 1, visibleFrame: leftScreen),
            WindowDisplay(id: 2, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]

        let result = WindowPlacement.restore(
            frame: CGRect(x: -1900, y: -100, width: 520, height: 440), displayID: 1,
            displays: displays, currentDisplayID: 2
        )

        XCTAssertEqual(result.origin, CGPoint(x: -1600, y: 0))
        XCTAssertTrue(leftScreen.contains(result))
    }

    func testMissingSavedDisplayFallsBackToCurrentDisplay() {
        let currentScreen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let saved = CGRect(x: 80, y: 90, width: 520, height: 440)

        let result = WindowPlacement.restore(
            frame: saved, displayID: 99,
            displays: [WindowDisplay(id: 2, visibleFrame: currentScreen)], currentDisplayID: 2
        )

        XCTAssertEqual(result, saved)
    }

    func testMissingSavedAndCurrentDisplayFallsBackToFirstAvailable() {
        let firstScreen = CGRect(x: 0, y: 0, width: 900, height: 700)

        let result = WindowPlacement.restore(
            frame: CGRect(x: 100, y: 100, width: 520, height: 440), displayID: 99,
            displays: [WindowDisplay(id: 1, visibleFrame: firstScreen)], currentDisplayID: 88
        )

        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 520, height: 440))
    }

    func testResolutionShrinkClampsWindowSizeAndPosition() {
        let smallerScreen = CGRect(x: 0, y: 0, width: 800, height: 600)

        let result = WindowPlacement.restore(
            frame: CGRect(x: 1200, y: 900, width: 900, height: 700), displayID: nil,
            displays: [WindowDisplay(id: 5, visibleFrame: smallerScreen)], currentDisplayID: 5
        )

        XCTAssertEqual(result, smallerScreen)
        XCTAssertTrue(smallerScreen.contains(result))
    }

    func testSmallSavedFrameUsesSensibleMinimumSizeBoundedByScreen() {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 200)

        let result = WindowPlacement.restore(
            frame: CGRect(x: 10, y: 10, width: 100, height: 80), displayID: 1,
            displays: [WindowDisplay(id: 1, visibleFrame: screen)], currentDisplayID: nil
        )

        XCTAssertEqual(result, screen)
    }

    func testNarrowSavedWindowRestoresAt375PointMinimum() {
        let displays = [WindowDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900))]
        let result = WindowPlacement.restore(frame: CGRect(x: 20, y: 20, width: 320, height: 400),
                                             displayID: 1, displays: displays, currentDisplayID: 1)
        XCTAssertEqual(result.width, 375)
    }

    func testNonFiniteSavedFrameFallsBackToDefaultAndNoDisplaysReturnsDefault() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let invalid = CGRect(x: CGFloat.infinity, y: .nan, width: 520, height: 440)

        let onScreen = WindowPlacement.restore(
            frame: invalid, displayID: 1,
            displays: [WindowDisplay(id: 1, visibleFrame: screen)], currentDisplayID: nil
        )
        let noScreens = WindowPlacement.restore(frame: invalid, displayID: 1, displays: [], currentDisplayID: nil)

        XCTAssertEqual(onScreen, WindowPlacement.defaultFrame)
        XCTAssertEqual(noScreens, WindowPlacement.defaultFrame)
    }

    func testMissingFrameCentersDefaultSizeOnCurrentDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let result = WindowPlacement.restore(
            frame: nil, displayID: nil, displays: [WindowDisplay(id: 1, visibleFrame: screen)], currentDisplayID: 1,
            defaultSize: CGSize(width: 420, height: 600), minimumSize: CGSize(width: 420, height: 420), centerWhenMissing: true
        )

        XCTAssertEqual(result, CGRect(x: 390, y: 150, width: 420, height: 600))
    }

    func testRestoredFrameUsesScaledMinimumAndClampsToScreen() {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 700)
        let result = WindowPlacement.restore(
            frame: CGRect(x: 850, y: 650, width: 300, height: 300), displayID: 1,
            displays: [WindowDisplay(id: 1, visibleFrame: screen)], currentDisplayID: nil,
            defaultSize: CGSize(width: 420, height: 600), minimumSize: CGSize(width: 500, height: 520)
        )

        XCTAssertEqual(result, CGRect(x: 400, y: 180, width: 500, height: 520))
    }

    func testFrameAutosaveNameIsStableButScopedToDebugTestSession() {
        let session = UUID().uuidString
        #if DEBUG
        let unitName = WindowPlacement.frameAutosaveName("RAMnotes.NoteList", arguments: ["app"])
        XCTAssertTrue(unitName.hasPrefix("RAMnotes.NoteList.unit-test."))
        XCTAssertEqual(unitName, WindowPlacement.frameAutosaveName("RAMnotes.NoteList", arguments: ["app"]))
        XCTAssertNotEqual(unitName, WindowPlacement.frameAutosaveName("RAMnotes.Settings", arguments: ["app"]))
        XCTAssertEqual(WindowPlacement.frameAutosaveName("RAMnotes.NoteList", arguments: ["app", "--test-session", session]),
                       "RAMnotes.NoteList.test.\(session)")
        #endif
    }
}
