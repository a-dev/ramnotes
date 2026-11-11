import AppKit
import Carbon

@MainActor final class WindowProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 230), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ramnotes Window Probe"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications]
        let alwaysOnTop = CommandLine.arguments.contains("--always-on-top")
        window.level = alwaysOnTop ? .floating : .normal
        let label = NSTextField(labelWithString: "Press Command–Option–Control–N to show or hide this window.")
        label.frame = NSRect(x: 20, y: 90, width: 300, height: 50)
        label.maximumNumberOfLines = 2
        window.contentView = label
        self.window = window
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { sharedProbe?.toggle() }
            return noErr
        }, 1, &spec, nil, &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: OSType(0x4E325750), id: 1), GetApplicationEventTarget(), 0, &hotKey)
        NSLog("WindowProbe handler=%d hotkey=%d alwaysOnTop=%@", installed, registered, String(alwaysOnTop))
    }

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
            NSLog("WindowProbe hidden")
        }
        else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSLog("WindowProbe visible=%@ activeSpace=%@", String(window.isVisible), String(window.isOnActiveSpace))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor var sharedProbe: WindowProbe?
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = WindowProbe()
    sharedProbe = delegate
    app.delegate = delegate
    app.run()
}
