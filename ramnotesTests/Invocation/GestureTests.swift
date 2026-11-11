import XCTest
import AppKit
@testable import ramnotes

final class GestureTests: XCTestCase {
    private let primaryBar = CGRect(x: 0, y: 0, width: 100, height: 10)
    private let secondDisplayBar = CGRect(x: 200, y: 400, width: 80, height: 12)

    func testMenuBarBoundsIncludeTopAndRightEdgesAndSupportSecondDisplay() {
        var filter = MenuBarScrollFilter()
        let bars = [primaryBar, secondDisplayBar]

        let topRight = filter.receive(
            point: CGPoint(x: primaryBar.maxX, y: primaryBar.maxY),
            menuBars: bars,
            deltaX: 0, deltaY: -24,
            inverted: false,
            precise: true,
            phase: .changed,
            momentum: [],
            time: 1
        )
        XCTAssertEqual(topRight, .toggle)

        let secondDisplay = filter.receive(
            point: CGPoint(x: secondDisplayBar.midX, y: secondDisplayBar.midY),
            menuBars: bars,
            deltaX: 0, deltaY: -24,
            inverted: false,
            precise: true,
            phase: .began,
            momentum: [],
            time: 2
        )
        XCTAssertEqual(secondDisplay, .toggle)
    }

    func testPointOutsideEveryMenuBarDoesNothing() {
        var filter = MenuBarScrollFilter()

        let action = filter.receive(
            point: CGPoint(x: secondDisplayBar.maxX + 1, y: secondDisplayBar.midY),
            menuBars: [primaryBar, secondDisplayBar],
            deltaX: 0, deltaY: -100,
            inverted: false,
            precise: true,
            phase: .changed,
            momentum: [],
            time: 1
        )

        XCTAssertNil(action)
    }

    func testPreciseActivePhaseIsRequiredAndMomentumIsRejected() {
        let point = CGPoint(x: 50, y: 5)
        func receive(precise: Bool = true, phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []) -> MenuBarScrollFilter.Action? {
            var filter = MenuBarScrollFilter()
            return filter.receive(
                point: point,
                menuBars: [primaryBar],
                deltaX: 0, deltaY: -24,
                inverted: false,
                precise: precise,
                phase: phase,
                momentum: momentum,
                time: 1
            )
        }

        XCTAssertNil(receive(precise: false))
        XCTAssertNil(receive(phase: .ended))
        XCTAssertNil(receive(momentum: .changed))
        XCTAssertEqual(receive(), .toggle)
    }

    func testEitherDirectionTogglesWithEitherNaturalScrollSetting() {
        var ordinary = MenuBarScrollFilter()
        var inverted = MenuBarScrollFilter()

        XCTAssertEqual(ordinary.receive(point: CGPoint(x: 50, y: 5), menuBars: [primaryBar], deltaX: 0, deltaY: -24,
                                           inverted: false, precise: true, phase: .changed, momentum: [], time: 1), .toggle)
        XCTAssertEqual(inverted.receive(point: CGPoint(x: 50, y: 5), menuBars: [primaryBar], deltaX: 0, deltaY: 24,
                                          inverted: true, precise: true, phase: .changed, momentum: [], time: 1), .toggle)

        var ordinaryUp = MenuBarScrollFilter()
        var invertedUp = MenuBarScrollFilter()
        XCTAssertEqual(ordinaryUp.receive(point: CGPoint(x: 50, y: 5), menuBars: [primaryBar], deltaX: 0, deltaY: 24,
                                           inverted: false, precise: true, phase: .changed, momentum: [], time: 1), .toggle)
        XCTAssertEqual(invertedUp.receive(point: CGPoint(x: 50, y: 5), menuBars: [primaryBar], deltaX: 0, deltaY: -24,
                                          inverted: true, precise: true, phase: .changed, momentum: [], time: 1), .toggle)
    }

    func testAccumulationSignReversalAndCooldown() {
        var filter = MenuBarScrollFilter()
        let point = CGPoint(x: 50, y: 5)
        func receive(_ deltaY: Double, at time: Double, phase: NSEvent.Phase = .changed) -> MenuBarScrollFilter.Action? {
            filter.receive(point: point, menuBars: [primaryBar], deltaX: 0, deltaY: deltaY, inverted: false,
                           precise: true, phase: phase, momentum: [], time: time)
        }

        XCTAssertNil(receive(-12, at: 1))
        XCTAssertEqual(receive(-12, at: 1.1), .toggle)

        // A reversal drops the partial downward travel. It doesn't subtract it from the upward travel.
        XCTAssertNil(receive(-18, at: 2, phase: .began))
        XCTAssertNil(receive(12, at: 2.1))
        XCTAssertEqual(receive(12, at: 2.2), .toggle)

        XCTAssertNil(receive(-24, at: 2.5), "An action inside the cooldown should be suppressed")
        XCTAssertEqual(receive(-24, at: 2.7, phase: .began), .toggle)
    }

    func testSeparateScrollsToggleAfterEachCooldown() {
        var filter = MenuBarScrollFilter()
        let point = CGPoint(x: 50, y: 5)

        let first = filter.receive(point: point, menuBars: [primaryBar], deltaX: 0, deltaY: -24, inverted: false,
                                   precise: true, phase: .changed, momentum: [], time: 1)
        let repeated = filter.receive(point: point, menuBars: [primaryBar], deltaX: 0, deltaY: -24, inverted: false,
                                      precise: true, phase: .began, momentum: [], time: 2)

        XCTAssertEqual(first, .toggle)
        XCTAssertEqual(repeated, .toggle, "A second scroll in the same direction toggles again")
    }


    func testLongGestureDoesNotToggleAgainAfterCooldown() {
        var filter = MenuBarScrollFilter()
        func receive(_ phase: NSEvent.Phase, at time: Double) -> MenuBarScrollFilter.Action? {
            filter.receive(point: CGPoint(x: 50, y: 5), menuBars: [primaryBar], deltaX: 0, deltaY: 24,
                           inverted: false, precise: true, phase: phase, momentum: [], time: time)
        }
        XCTAssertEqual(receive(.began, at: 1), .toggle)
        XCTAssertNil(receive(.changed, at: 2))
        XCTAssertNil(receive(.ended, at: 2.1))
        XCTAssertEqual(receive(.began, at: 3), .toggle)
        XCTAssertNil(receive(.began, at: 3.1), "A new gesture inside the cooldown is suppressed")
    }

    @MainActor
    func testDisabledGestureServiceStaysOffWithoutRequestingPermission() {
        let service = GestureService()

        service.start(enabled: false, horizontal: false)

        XCTAssertFalse(service.isListening)
        XCTAssertEqual(service.status, "Menu-bar scroll is off.")
        XCTAssertFalse(service.status.localizedCaseInsensitiveContains("permission"))
    }
    func testHorizontalAxisLockAndCooldown() {
        let point = CGPoint(x: 50, y: 5)
        var filter = MenuBarScrollFilter()
        filter.horizontalEnabled = true
        func receive(_ x: Double, _ y: Double, _ phase: NSEvent.Phase, _ time: Double) -> MenuBarScrollFilter.Action? {
            filter.receive(point: point, menuBars: [primaryBar], deltaX: x, deltaY: y, inverted: false,
                           precise: true, phase: phase, momentum: [], time: time)
        }
        XCTAssertEqual(receive(-24, 0, .began, 1), .toggleWithList)
        XCTAssertEqual(receive(24, 0, .began, 2), .toggleWithList)
        XCTAssertNil(receive(10, 10, .began, 3))
        XCTAssertEqual(receive(24, 2, .changed, 3.1), .toggleWithList)
        XCTAssertNil(receive(0, 10, .began, 4))
        XCTAssertNil(receive(100, 0, .changed, 4.1))
        XCTAssertEqual(receive(0, 14, .changed, 4.2), .toggle)
        XCTAssertNil(receive(24, 0, .began, 4.3))
        XCTAssertEqual(receive(24, 0, .began, 5), .toggleWithList)
    }

    func testDisabledHorizontalAxisDoesNotFallBackToVertical() {
        var filter = MenuBarScrollFilter()
        let point = CGPoint(x: 50, y: 5)
        XCTAssertNil(filter.receive(point: point, menuBars: [primaryBar], deltaX: -100, deltaY: 0,
                                    inverted: false, precise: true, phase: .began, momentum: [], time: 1))
        XCTAssertNil(filter.receive(point: point, menuBars: [primaryBar], deltaX: 0, deltaY: 100,
                                    inverted: false, precise: true, phase: .changed, momentum: [], time: 2))
    }

    func testHorizontalSettingDecodesLegacyAndRoundTrips() throws {
        let decoder = JSONDecoder()
        XCTAssertFalse(try decoder.decode(AppSettings.self, from: Data("{}".utf8)).menuBarHorizontalGestureEnabled)
        var settings = AppSettings()
        settings.menuBarHorizontalGestureEnabled = true
        XCTAssertTrue(try decoder.decode(AppSettings.self, from: JSONEncoder().encode(settings)).menuBarHorizontalGestureEnabled)
    }

}
