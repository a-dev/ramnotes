import AppKit

// This sandboxed helper communicates only a hidden-launch hint. It accepts no paths or commands.
@MainActor
final class LoginHelperDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([URL(string: "ramnotes-login://login")!], withApplicationAt: mainApp, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
let app = NSApplication.shared
let delegate = LoginHelperDelegate()
app.delegate = delegate
app.run()
