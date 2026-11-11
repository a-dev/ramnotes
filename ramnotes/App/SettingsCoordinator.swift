import AppKit

/// What the settings layer needs from the app. Small, so tests can fake it.
@MainActor
protocol SettingsHost: AnyObject {
    /// Normalized settings. Apply them to open windows and save them.
    func settingsDidChange(_ settings: AppSettings)
    func shortcutMessageChanged(_ message: String)
    var defaultFolderBusy: Bool { get }
    var folderStatus: String { get }
    var defaultFolderMissing: Bool { get }
    func chooseFolder()
}

extension SettingsHost {
    var defaultFolderBusy: Bool { false }
    var defaultFolderMissing: Bool { false }
}

/// Owns settings, the Settings window, and the shortcut, menu-bar gesture, and login item
/// services that the window shows.
@MainActor
final class SettingsCoordinator {
    let shortcut = ShortcutService()
    let listShortcut = ShortcutService(signature: 0x4E324C53)
    let gesture = GestureService()
    let loginService = LoginService()
    private(set) var settings = AppSettings()
    private(set) var recordingShortcut = false
    private var shortcutSettingsMessage = ""
    private var listShortcutSettingsMessage = ""
    var makeUpdateControls: (() -> NSView)?
    private var controller: SettingsController?
    weak var host: SettingsHost?

    /// Installs settings read from disk. Does not save them again.
    func load(_ value: AppSettings) {
        settings = EditorTypography.normalized(value)
        NSApp.appearance = settings.appearance.nativeAppearance
        controller?.reload(settings)
        registerShortcut(ShortcutChord(storedValue: settings.shortcut) ?? .default, persist: false)
        registerListShortcut(ShortcutChord(storedValue: settings.listGlobalShortcut) ?? .toggleWithList, persist: false)
        gesture.start(enabled: settings.menuBarGestureEnabled, horizontal: settings.menuBarHorizontalGestureEnabled)
    }

    func registerShortcut(_ chord: ShortcutChord, persist: Bool) {
        if persist, settings.isTaken(chord) || chord == listShortcut.chord || chord == (ShortcutChord(storedValue: settings.listGlobalShortcut) ?? .toggleWithList) {
            shortcutSettingsMessage = String(localized: "This shortcut is already used. Choose another combination.", comment: "Shown when a recorded shortcut conflicts with another")
            updateShortcutStatus()
            return
        }
        let status = shortcut.start(chord)
        let message: String
        if status == 0 {
            message = ""
            if persist {
                settings.shortcut = chord.storedValue
                save()
            }
        } else if let current = shortcut.chord {
            let title = current.title
            message = String(localized: "Shortcut registration failed (\(status)). Still using \(title). Choose another shortcut. Manual reopen and Toggle Notes remain available.", comment: "Settings: global shortcut failed; first value is a system status code, second is the shortcut still in use")
        } else {
            message = String(localized: "Shortcut registration failed (\(status)). Choose another shortcut. Manual reopen and Toggle Notes remain available.", comment: "Settings: global shortcut failed and no shortcut is active; value is a system status code")
        }
        shortcutSettingsMessage = status == 0 ? "" : message
        updateShortcutStatus()
        if let chord = shortcut.chord { controller?.recorder.chord = chord }
    }

    func registerListShortcut(_ chord: ShortcutChord, persist: Bool) {
        if persist, settings.isTaken(chord) || chord == shortcut.chord || chord == (ShortcutChord(storedValue: settings.shortcut) ?? .default) {
            listShortcutSettingsMessage = String(localized: "This shortcut is already used. Choose another combination.", comment: "Shown when a recorded shortcut conflicts with another")
            updateShortcutStatus()
            return
        }
        let status = listShortcut.start(chord)
        if status == 0 {
            listShortcutSettingsMessage = ""
            if persist { settings.listGlobalShortcut = chord.storedValue; save() }
        } else {
            if let current = listShortcut.chord {
                let title = current.title
                listShortcutSettingsMessage = String(localized: "Notes and note list shortcut registration failed (\(status)). Still using \(title). Choose another shortcut.", comment: "Settings: note list shortcut failed; first value is a system status code, second is the shortcut still in use")
            } else {
                listShortcutSettingsMessage = String(localized: "Notes and note list shortcut registration failed (\(status)). Choose another shortcut.", comment: "Settings: note list shortcut failed and no shortcut is active; value is a system status code")
            }
        }
        updateShortcutStatus()
        if let chord = listShortcut.chord { controller?.listGlobalRecorder.chord = chord }
    }

    private func updateShortcutStatus() {
        let message = [shortcutSettingsMessage, listShortcutSettingsMessage].filter { !$0.isEmpty }.joined(separator: "\n")
        host?.shortcutMessageChanged(message)
        controller?.showShortcutStatus(message)
    }

    private func save() {
        settings = EditorTypography.normalized(settings)
        NSApp.appearance = settings.appearance.nativeAppearance
        host?.settingsDidChange(settings)
    }

    func show() {
        if controller == nil { controller = makeController() }
        updateStatus()
        let opening = controller?.window?.isVisible != true
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if opening { controller?.focusCategories() }
    }

    func updateStatus() {
        guard let controller else { return }
        controller.loginStatus.stringValue = loginService.message
        controller.login.state = loginService.status == .enabled ? .on : (loginService.status == .requiresApproval ? .mixed : .off)
        updateShortcutStatus()
        if let chord = shortcut.chord { controller.recorder.chord = chord }
        if let chord = listShortcut.chord { controller.listGlobalRecorder.chord = chord }
        controller.gestureStatus.stringValue = gesture.status
        controller.gestureStatus.isHidden = gesture.status.isEmpty
        controller.folderStatus.stringValue = host?.folderStatus ?? ""
        controller.showMissingDefaultFolder(host?.defaultFolderMissing ?? false)
        controller.showFolderActivity(busy: host?.defaultFolderBusy ?? false)
        controller.showLoginRefresh(loginService.status == .requiresApproval)
    }

    private func makeController() -> SettingsController {
        let controller = SettingsController(settings: settings, updateControls: makeUpdateControls?())
        controller.changed = { [weak self] value in
            guard let self else { return }
            let restartGesture = settings.menuBarGestureEnabled != value.menuBarGestureEnabled ||
                settings.menuBarHorizontalGestureEnabled != value.menuBarHorizontalGestureEnabled
            let shortcutValue = settings.shortcut
            let listShortcutValue = settings.listGlobalShortcut
            let loginValue = settings.launchAtLogin
            settings = value
            settings.shortcut = shortcutValue
            settings.listGlobalShortcut = listShortcutValue
            settings.launchAtLogin = loginValue
            save()
            if restartGesture { gesture.start(enabled: settings.menuBarGestureEnabled, horizontal: settings.menuBarHorizontalGestureEnabled) }
            updateStatus()
        }
        for recorder in [controller.recorder, controller.listGlobalRecorder] {
            recorder.recordingChanged = { [weak self, weak recorder] recording in
                guard let self else { return }
                recordingShortcut = recording
                let capture: ((ShortcutChord) -> Void)? = recording ? { [weak recorder] chord in recorder?.accept(chord) } : nil
                shortcut.recordPressed = capture
                listShortcut.recordPressed = capture
            }
        }
        for recorder in controller.appShortcutRecorders.values {
            recorder.recordingChanged = { [weak self] recording in self?.recordingShortcut = recording }
        }
        controller.recorder.recorded = { [weak self] in self?.registerShortcut($0, persist: true) }
        controller.listGlobalRecorder.recorded = { [weak self] in self?.registerListShortcut($0, persist: true) }
        controller.chooseFolder = { [weak self] in self?.host?.chooseFolder() }
        controller.loginChanged = { [weak self] enabled in
            guard let self else { return }
            if loginService.setEnabled(enabled) { settings.launchAtLogin = enabled; save() }
            updateStatus()
        }
        controller.openLoginSettings = { [weak self] in self?.loginService.openSystemSettings() }
        controller.refreshLogin = { [weak self] in self?.updateStatus() }
        // Re-read login and folder state when the user comes back from System Settings.
        controller.becameKey = { [weak self] in self?.updateStatus() }
        controller.quit = { NSApp.terminate(nil) }
        return controller
    }
}
