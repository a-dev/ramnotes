import AppKit
import Carbon
import ApplicationServices

var first: EventHotKeyRef?
var duplicate: EventHotKeyRef?
let hotKey = EventHotKeyID(signature: OSType(0x4E325052), id: 1)
let modifiers = UInt32(cmdKey | optionKey | controlKey)
let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), modifiers, hotKey, GetApplicationEventTarget(), 0, &first)
let duplicateStatus = RegisterEventHotKey(UInt32(kVK_ANSI_N), modifiers, hotKey, GetApplicationEventTarget(), 0, &duplicate)
print("command-option-control-N registration=\(status) duplicate=\(duplicateStatus) accessibilityTrusted=\(AXIsProcessTrusted())")
if let duplicate { UnregisterEventHotKey(duplicate) }
if let first { UnregisterEventHotKey(first) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var localMonitor: Any?
var globalMonitor: Any?
if CommandLine.arguments.contains("--listen-scroll") {
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 480, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "ramnotes Scroll Probe"
    window.contentView = NSTextField(labelWithString: "Scroll over the menu bar with this window focused, then with another app focused. Results print in Terminal.")
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    func report(_ event: NSEvent, source: String) {
        let point = NSEvent.mouseLocation
        // The pointer can sit exactly on a screen frame's upper edge.
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
        let menuBar = screen.map { point.y >= $0.visibleFrame.maxY - 1 && point.y <= $0.frame.maxY + 2 }
        print("\(source) point=\(point) menuBar=\(String(describing: menuBar)) precise=\(event.hasPreciseScrollingDeltas) dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) inverted=\(event.isDirectionInvertedFromDevice)")
        fflush(stdout)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        report(event, source: "local")
        return event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
        report(event, source: "global")
    }
    for screen in NSScreen.screens {
        print("screen frame=\(screen.frame) visibleFrame=\(screen.visibleFrame)")
    }
    print("scroll listeners ready; press Control-C to stop")
    fflush(stdout)
    app.run()
}
_ = (localMonitor, globalMonitor)
