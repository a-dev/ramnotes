import AppKit
import ServiceManagement

#if LOGIN_HELPER
let mainApp = Bundle.main.bundleURL
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // LoginProbe.app
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
let marker = URL(string: "ramnotes-login-probe://login")!
NSWorkspace.shared.open([marker], withApplicationAt: mainApp, configuration: configuration) { _, error in
    if let error { NSLog("LoginProbe helper open failed: %@", String(describing: error)) }
    else { NSLog("LoginProbe helper sent login URL") }
    NSApp.terminate(nil)
}
NSApplication.shared.run()
#else
@MainActor final class LoginProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var status: NSTextField?
    private var receivedLoginURL = false
    private let service = SMAppService.loginItem(identifier: "dev.ramnotes.LoginProbe.Helper")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ramnotes Login Probe"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        let status = NSTextField(labelWithString: "Login item status: \(service.status.rawValue)")
        status.frame = NSRect(x: 20, y: 105, width: 480, height: 48)
        status.maximumNumberOfLines = 2
        content.addSubview(status)
        self.status = status
        let register = NSButton(title: "Register Login Item", target: self, action: #selector(registerItem(_:)))
        register.frame = NSRect(x: 20, y: 40, width: 180, height: 32)
        content.addSubview(register)
        let unregister = NSButton(title: "Unregister", target: self, action: #selector(unregisterItem(_:)))
        unregister.frame = NSRect(x: 210, y: 40, width: 140, height: 32)
        content.addSubview(unregister)
        window.contentView = content
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.receivedLoginURL else { return }
            self.showWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "ramnotes-login-probe" && $0.host == "login" }) else { return }
        receivedLoginURL = true
        window?.orderOut(nil)
        NSLog("LoginProbe main received login URL; remaining hidden")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        status?.stringValue = "Login item status: \(service.status.rawValue)"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func registerItem(_ sender: Any?) {
        do {
            try service.register()
            status?.stringValue = "Register returned; status: \(service.status.rawValue)"
        } catch { status?.stringValue = "Register failed: \(error.localizedDescription)" }
    }

    @objc private func unregisterItem(_ sender: Any?) {
        do {
            try service.unregister()
            status?.stringValue = "Unregister returned; status: \(service.status.rawValue)"
        } catch { status?.stringValue = "Unregister failed: \(error.localizedDescription)" }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = LoginProbeDelegate()
    app.delegate = delegate
    app.run()
}
#endif
