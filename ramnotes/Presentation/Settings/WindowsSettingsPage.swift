import AppKit

/// Windows settings: window layering, global shortcuts, and menu-bar gestures, the ways to show,
/// hide, and layer note windows. It displays values and emits edits.
@MainActor
final class WindowsSettingsPage {
    let gestureStatus = NSTextField(wrappingLabelWithString: "")
    let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    let recorder = ShortcutRecorder()
    let listGlobalRecorder = ShortcutRecorder()
    let bringForward = NSButton(checkboxWithTitle: String(localized: "Show notes when another app is active", comment: "Settings checkbox in Window Behavior. When on, a global shortcut or menu bar gesture used while another app is active shows notes instead of hiding them."), target: nil, action: nil)
    private let top = NSButton(checkboxWithTitle: String(localized: "Keep note windows on top", comment: "Settings checkbox that keeps note windows above other windows"), target: nil, action: nil)
    private let gesture = NSButton(checkboxWithTitle: String(localized: "Vertical menu-bar scroll shows notes", comment: "Settings checkbox for the vertical scroll gesture on the menu bar"), target: nil, action: nil)
    private let horizontalGesture = NSButton(checkboxWithTitle: String(localized: "Horizontal menu-bar scroll shows notes and the note list", comment: "Settings checkbox for the horizontal scroll gesture on the menu bar"), target: nil, action: nil)
    private(set) var view: NSView!

    var alwaysOnTopChanged: ((Bool) -> Void)?
    var bringForwardChanged: ((Bool) -> Void)?
    /// Emits the vertical and horizontal gesture choices.
    var gesturesChanged: ((_ vertical: Bool, _ horizontal: Bool) -> Void)?

    init(settings: AppSettings, layout: SettingsPageLayout) {
        top.target = self; top.action = #selector(changeTop)
        bringForward.target = self; bringForward.action = #selector(changeBringForward)
        for button in [gesture, horizontalGesture] { button.target = self; button.action = #selector(changeGestures) }
        layout.wraps(top, bringForward, gesture, horizontalGesture)
        showShortcutStatus("")
        recorder.setAccessibilityLabel(String(localized: "Toggle notes shortcut", comment: "Accessibility label for the recorder of the global shortcut that shows or hides notes"))
        listGlobalRecorder.setAccessibilityLabel(String(localized: "Toggle notes and the note list shortcut", comment: "Accessibility label for the recorder of the global shortcut that shows or hides notes and the note list"))
        show(settings)
        view = layout.page(String(localized: "Windows", comment: "Settings category and page title for window behavior, global shortcuts, and menu bar gestures"), sections: [
            layout.section(String(localized: "Window Behavior", comment: "Settings section title"), [top, bringForward, layout.caption(String(localized: "Applies to global shortcuts and menu bar gestures.", comment: "Settings caption under Show notes when another app is active"))]),
            layout.section(String(localized: "Global Shortcuts", comment: "Settings section title"), [layout.row(String(localized: "Toggle notes", comment: "Settings row label for the global shortcut that shows or hides notes"), recorder), layout.row(String(localized: "Toggle notes and the note list", comment: "Settings row label for the global shortcut that shows or hides notes and the note list"), listGlobalRecorder), shortcutStatus]),
            layout.section(String(localized: "Menu Bar Gestures", comment: "Settings section title"), [gesture, horizontalGesture, layout.caption(String(localized: "Scroll again to hide them. Use a trackpad or a mouse with precise scrolling.", comment: "Settings explanation for the menu bar scroll gesture")), gestureStatus])])
    }

    func show(_ settings: AppSettings) {
        top.state = settings.alwaysOnTop ? .on : .off
        bringForward.state = settings.bringNotesForwardWhenInactive ? .on : .off
        recorder.chord = ShortcutChord(storedValue: settings.shortcut) ?? .default
        listGlobalRecorder.chord = ShortcutChord(storedValue: settings.listGlobalShortcut) ?? .toggleWithList
        gesture.state = settings.menuBarGestureEnabled ? .on : .off
        horizontalGesture.state = settings.menuBarHorizontalGestureEnabled ? .on : .off
        horizontalGesture.isEnabled = settings.menuBarGestureEnabled
    }
    func showShortcutStatus(_ message: String) {
        shortcutStatus.stringValue = message
        shortcutStatus.isHidden = message.isEmpty
    }
    func cancelRecording() {
        recorder.cancel()
        listGlobalRecorder.cancel()
    }

    @objc private func changeTop() { alwaysOnTopChanged?(top.state == .on) }
    @objc private func changeBringForward() { bringForwardChanged?(bringForward.state == .on) }
    @objc private func changeGestures() {
        horizontalGesture.isEnabled = gesture.state == .on
        gesturesChanged?(gesture.state == .on, horizontalGesture.state == .on)
    }
}
