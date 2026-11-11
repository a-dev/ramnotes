import AppKit

/// General settings: default folder, launch at login, and debug-only controls.
/// It displays values and emits edits. `SettingsCoordinator` owns the accepted settings.
@MainActor
final class GeneralSettingsPage {
    let folderStatus = NSTextField(wrappingLabelWithString: String(localized: "Loading folder…", comment: "Settings status while the default notes folder is loading"))
    let missingFolderStatus: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: String(localized: "Default folder is missing. Choose a default folder below.", comment: "Settings warning when the default notes folder no longer exists"))
        label.isHidden = true
        return label
    }()
    let loginStatus = NSTextField(wrappingLabelWithString: String(localized: "Launch at login is not configured yet.", comment: "Settings status before the login item state is known"))
    let login = NSButton(checkboxWithTitle: String(localized: "Launch at login", comment: "Settings checkbox that starts the app when the user logs in"), target: nil, action: nil)
    let folderProgress = NSProgressIndicator()
    let folderActivityLabel = NSTextField(labelWithString: String(localized: "Changing default notes folder…", comment: "Settings status while the default folder is being moved"))
    private var folderActions: [NSButton] = []
    private var refreshLoginButton: NSButton!
    private var folderBusy = false
    private(set) var view: NSView!

    var chooseFolder: (() -> Void)?
    var loginChanged: ((Bool) -> Void)?
    var openLoginSettings: (() -> Void)?
    var refreshLogin: (() -> Void)?

    init(layout: SettingsPageLayout) {
        login.target = self; login.action = #selector(changeLogin)
        layout.wraps(login)
        let folderButtons = NSStackView(views: [ActionButton(String(localized: "Choose Default Folder…", comment: "Settings button that opens a folder chooser")) { [weak self] in self?.chooseFolder?() }])
        folderActions = folderButtons.arrangedSubviews.compactMap { $0 as? NSButton }
        layout.adaptive(folderButtons)
        folderProgress.style = .spinning
        folderProgress.controlSize = .small
        folderProgress.isHidden = true
        folderActivityLabel.isHidden = true
        folderProgress.setAccessibilityLabel(String(localized: "Changing default notes folder", comment: "Accessibility label for the progress spinner"))
        let refreshLoginButton = ActionButton(String(localized: "Refresh Login Status", comment: "Settings button that rechecks the login item state")) { [weak self] in self?.refreshLogin?() }
        refreshLoginButton.isHidden = true
        self.refreshLoginButton = refreshLoginButton
        let loginButtons = NSStackView(views: [refreshLoginButton,
                                              ActionButton(String(localized: "Open Login Settings", comment: "Settings button that opens the Login Items pane of System Settings")) { [weak self] in self?.openLoginSettings?() }])
        layout.adaptive(loginButtons)
        view = layout.page(String(localized: "General", comment: "Settings category and page title"), sections: [
            layout.section(String(localized: "Default notes folder", comment: "Settings section title"), [folderStatus, missingFolderStatus, folderProgress, folderActivityLabel, folderButtons]),
            layout.section(String(localized: "Startup", comment: "Settings section title for launch at login"), [login, layout.caption(String(localized: "At login, RAMnotes runs in the background without opening windows. Use the global shortcut to reveal active notes.", comment: "Settings explanation under Launch at login. Keep the product name RAMnotes unchanged.")), loginStatus, loginButtons])
        ] + Self.debugSections(layout))
    }

    func showMissingDefaultFolder(_ missing: Bool) {
        missingFolderStatus.textColor = .systemRed
        missingFolderStatus.isHidden = !missing
    }
    func showLoginRefresh(_ visible: Bool) { refreshLoginButton.isHidden = !visible }
    func showFolderActivity(busy: Bool, reduceMotion: Bool) {
        folderActions.forEach { $0.isEnabled = !busy }
        folderBusy = busy
        applyDisplayPreferences(reduceMotion: reduceMotion)
    }
    func applyDisplayPreferences(reduceMotion: Bool) {
        folderProgress.isHidden = !folderBusy || reduceMotion
        folderActivityLabel.isHidden = !folderBusy || !reduceMotion
        if folderBusy && !reduceMotion { folderProgress.startAnimation(nil) }
        else { folderProgress.stopAnimation(nil) }
    }

    @objc private func changeLogin() { loginChanged?(login.state == .on) }

    private static func debugSections(_ layout: SettingsPageLayout) -> [NSView] {
        #if DEBUG
        return [layout.section("Developer", [layout.row("Language", DebugLanguageControl.makePopup()), layout.caption("Debug builds only. Relaunches RAMnotes.")])]
        #else
        return []
        #endif
    }
}

#if DEBUG
/// Developer-only language override for checking translations. Deliberately unlocalized.
@MainActor
private enum DebugLanguageControl {
    private static let languages = ["en", "es", "pt", "de", "fr", "ar", "ja", "zh-Hans"]
    private static var isTestSession: Bool { ProcessInfo.processInfo.arguments.contains("--test-session") }
    private static let target = Target()

    static func makePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "System")
        for code in languages {
            popup.addItem(withTitle: Locale(identifier: code).localizedString(forIdentifier: code)?.localizedCapitalized ?? code)
        }
        let current = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first
        popup.selectItem(at: current.flatMap { languages.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        popup.target = target
        popup.action = #selector(Target.chosen(_:))
        popup.setAccessibilityIdentifier("Debug language")
        popup.setAccessibilityLabel("Language")
        return popup
    }

    @MainActor private final class Target: NSObject {
        @objc func chosen(_ sender: NSPopUpButton) {
            // An isolated test session must not touch the user's real defaults or restart.
            guard !DebugLanguageControl.isTestSession else { return }
            let index = sender.indexOfSelectedItem
            if index == 0 { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([DebugLanguageControl.languages[index - 1]], forKey: "AppleLanguages") }
            UserDefaults.standard.synchronize()
            // The new instance waits in main.swift until this one has flushed notes and exited.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--debug-relaunch-after", String(ProcessInfo.processInfo.processIdentifier)]
            // Don't wait for the completion: the new instance blocks before checking in, so the
            // completion would wait for this instance to exit.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                if let error { NSLog("Debug language relaunch failed: \(error)") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }
}
#endif
