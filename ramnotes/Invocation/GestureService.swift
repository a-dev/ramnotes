import AppKit

struct MenuBarScrollFilter {
    enum Action: Equatable { case toggle, toggleWithList }
    private enum Axis { case vertical, horizontal }
    var horizontalEnabled = false
    private var axis: Axis?
    var threshold = 24.0
    var cooldown = 0.4
    private var toggledInGesture = false
    private var accumulated = 0.0
    private var lastAction = -Double.infinity

    mutating func receive(point: CGPoint, menuBars: [CGRect], deltaX: Double, deltaY: Double, inverted: Bool,
                          precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase, time: Double) -> Action? {
        if phase.contains(.began) || !phase.intersection([.ended, .cancelled]).isEmpty {
            toggledInGesture = false
            accumulated = 0
            axis = nil
        }
        let inside = menuBars.contains { point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY }
        guard inside, precise, momentum.isEmpty,
              !phase.intersection([.began, .changed, .stationary]).isEmpty else { accumulated = 0; return nil }
        guard !toggledInGesture, time - lastAction >= cooldown else { accumulated = 0; return nil }
        if axis == nil {
            let x = abs(deltaX), y = abs(deltaY)
            if x == 0 && y == 0 { return nil }
            if x >= 1.5 * y { axis = .horizontal }
            else if y >= 1.5 * x { axis = .vertical }
            else { return nil }
        }
        guard let axis, axis != .horizontal || horizontalEnabled else { return nil }
        let delta = axis == .horizontal ? deltaX : deltaY
        let down = inverted ? delta : -delta
        if phase.contains(.began) || down * accumulated < 0 { accumulated = 0 }
        accumulated += down
        guard abs(accumulated) >= threshold else { return nil }
        toggledInGesture = true
        accumulated = 0
        lastAction = time
        return axis == .vertical ? .toggle : .toggleWithList
    }
}

@MainActor
final class GestureService {
    private var global: Any?
    private var local: Any?
    private var filter = MenuBarScrollFilter()
    private(set) var status = String(localized: "Menu-bar scroll is off.", comment: "Settings status when the menu bar scroll gesture is off")
    var invoke: ((MenuBarScrollFilter.Action) -> Void)?
    func start(enabled: Bool, horizontal: Bool) {
        stop()
        filter.horizontalEnabled = horizontal
        guard enabled else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
        if global == nil || local == nil {
            stop()
            status = String(localized: "Menu-bar scroll monitor is unavailable. Check macOS access restrictions, then turn the gesture off and on. Manual reopen and shortcut remain available.", comment: "Settings status when macOS blocks the scroll gesture monitor")
        } else { status = "" }
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil; filter = MenuBarScrollFilter()
        status = String(localized: "Menu-bar scroll is off.", comment: "Settings status when the menu bar scroll gesture is off")
    }
    var isListening: Bool { global != nil && local != nil }
    private func receive(_ event: NSEvent) {
        // A global monitor misses this app's own events. The local monitor catches those.
        // Track all gesture phases. Compute menu bar rectangles only near the top of a screen.
        let pointer = NSEvent.mouseLocation
        func barHeight(_ screen: NSScreen) -> CGFloat { max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        let nearTop = NSScreen.screens.contains { pointer.y >= $0.frame.maxY - barHeight($0) }
        let bars = nearTop ? NSScreen.screens.map { CGRect(x: $0.frame.minX, y: $0.frame.maxY - barHeight($0), width: $0.frame.width, height: barHeight($0)) } : []
        if let action = filter.receive(point: pointer, menuBars: bars, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas,
            phase: event.phase, momentum: event.momentumPhase, time: event.timestamp) { invoke?(action) }
    }
}
