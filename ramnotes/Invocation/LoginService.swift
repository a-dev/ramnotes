import Foundation
import ServiceManagement

struct LaunchOrigin: Sendable {
    static let loginURL = URL(string: "ramnotes-login://login")!
    private(set) var hidden = false
    private(set) var finished = false
    mutating func receive(_ urls: [URL]) {
        guard !finished, urls.contains(where: { $0.absoluteString == Self.loginURL.absoluteString }) else { return }
        hidden = true
    }
    mutating func finish() { finished = true }
    mutating func manualReopen() { hidden = false; finished = true }
}

@MainActor
final class LoginService {
    private let service = SMAppService.loginItem(identifier: "com.ramnotes.RAMnotes.LoginHelper")
    private(set) var error: String?
    var status: SMAppService.Status { service.status }
    var message: String {
        let description: String
        switch status {
        case .enabled: description = String(localized: "Enabled in macOS. Login starts RAMnotes hidden.", comment: "Settings status for launch at login. Keep the product name RAMnotes unchanged.")
        case .requiresApproval: description = String(localized: "Pending approval. Enable RAMnotes in System Settings → General → Login Items & Extensions.", comment: "Settings status for launch at login. Keep the product name RAMnotes unchanged. Use the exact names of the System Settings panes and keep the arrows")
        case .notRegistered: description = String(localized: "Off or disabled externally in macOS.", comment: "Settings status for launch at login")
        case .notFound: description = String(localized: "Login helper not found. Run an intact RAMnotes app bundle.", comment: "Settings status for launch at login. Keep the product name RAMnotes unchanged.")
        @unknown default: description = String(localized: "Unknown macOS login-item status. Refresh Login Status.", comment: "Settings status for launch at login. Refresh Login Status must match the button title")
        }
        return [description, error].compactMap { $0 }.joined(separator: "\n")
    }
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if status != .enabled && status != .requiresApproval { try service.register() }
            } else if status != .notRegistered { try service.unregister() }
            error = nil
            return true
        } catch { self.error = String(localized: "Login setting failed: \(error.localizedDescription)", comment: "Settings status when changing launch at login fails. The value is the system error"); return false }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
