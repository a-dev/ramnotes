import Foundation
import AppKit

struct WindowDisplay: Sendable {
    let id: UInt32
    let visibleFrame: CGRect
}

enum WindowPlacement {
    static let defaultFrame = CGRect(x: 180, y: 180, width: 520, height: 440)
    #if DEBUG
    private static let unitTestFrameScope = UUID().uuidString
    #endif

    static func frameAutosaveName(_ name: String, arguments: [String] = ProcessInfo.processInfo.arguments) -> String {
        #if DEBUG
        if let index = arguments.firstIndex(of: "--test-session"), arguments.indices.contains(index + 1),
           UUID(uuidString: arguments[index + 1]) != nil {
            return "\(name).test.\(arguments[index + 1])"
        }
        if NSClassFromString("XCTestCase") != nil { return "\(name).unit-test.\(unitTestFrameScope)" }
        #endif
        return name
    }

    /// Caps a minimum size to the visible frame of the screen that shows `frame`.
    @MainActor
    static func boundedMinimumSize(_ minimum: CGSize, for frame: CGRect) -> CGSize {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        return CGSize(width: min(minimum.width, screen?.visibleFrame.width ?? minimum.width),
                      height: min(minimum.height, screen?.visibleFrame.height ?? minimum.height))
    }

    @MainActor
    static func restore(frame: CGRect?, defaultSize: CGSize, minimumSize: CGSize) -> CGRect {
        let displays = NSScreen.screens.compactMap { screen -> WindowDisplay? in
            guard let id = displayID(for: screen) else { return nil }
            return WindowDisplay(id: id, visibleFrame: screen.visibleFrame)
        }
        let current = NSScreen.main.flatMap { displayID(for: $0) }
        let savedDisplay = frame.flatMap { saved in
            NSScreen.screens.first { $0.visibleFrame.intersects(saved) }.flatMap { displayID(for: $0) }
        }
        return restore(frame: frame, displayID: savedDisplay, displays: displays, currentDisplayID: current,
                       defaultSize: defaultSize, minimumSize: minimumSize, centerWhenMissing: true)
    }

    @MainActor
    static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func restore(
        frame: CGRect?, displayID: UInt32?, displays: [WindowDisplay], currentDisplayID: UInt32?,
        defaultSize: CGSize = CGSize(width: defaultFrame.width, height: defaultFrame.height),
        minimumSize: CGSize = CGSize(width: 375, height: 260), centerWhenMissing: Bool = false
    ) -> CGRect {
        let validDisplays = displays.filter { isValid($0.visibleFrame) }
        guard !validDisplays.isEmpty else {
            return CGRect(origin: defaultFrame.origin, size: defaultSize)
        }

        let validFrame = frame.flatMap { isValid($0) ? $0 : nil }
        let frameDisplay = validFrame.flatMap { saved in
            validDisplays.first { $0.visibleFrame.intersects(saved) }
        }
        let target = displayID.flatMap { id in validDisplays.first { $0.id == id } }
            ?? currentDisplayID.flatMap { id in validDisplays.first { $0.id == id } }
            ?? frameDisplay
            ?? validDisplays[0]
        let visible = target.visibleFrame
        let candidate: CGRect
        if let validFrame {
            candidate = validFrame
        } else if centerWhenMissing {
            candidate = CGRect(x: visible.midX - defaultSize.width / 2,
                               y: visible.midY - defaultSize.height / 2,
                               width: defaultSize.width, height: defaultSize.height)
        } else {
            candidate = CGRect(origin: defaultFrame.origin, size: defaultSize)
        }

        let minimumWidth = min(minimumSize.width, visible.width)
        let minimumHeight = min(minimumSize.height, visible.height)
        let width = min(visible.width, max(minimumWidth, candidate.width))
        let height = min(visible.height, max(minimumHeight, candidate.height))
        let x = min(max(candidate.origin.x, visible.minX), visible.maxX - width)
        let y = min(max(candidate.origin.y, visible.minY), visible.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        guard values.allSatisfy({ $0.isFinite }), rect.width > 0, rect.height > 0 else { return false }
        return (rect.origin.x + rect.width).isFinite && (rect.origin.y + rect.height).isFinite
    }
}
