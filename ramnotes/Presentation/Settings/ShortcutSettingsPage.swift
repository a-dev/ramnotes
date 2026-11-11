import AppKit

/// Shortcuts settings: commands used inside RAMnotes. It displays values and emits edits.
/// Conflict checks stay with `SettingsController`, which also sees the global chords.
@MainActor
final class ShortcutSettingsPage {
    let appShortcutRecorders = Dictionary(uniqueKeysWithValues: AppShortcut.allCases.map { ($0, ShortcutRecorder()) })
    private let navigationError = NSTextField(wrappingLabelWithString: "")
    private(set) var view: NSView!

    var appShortcutRecorded: ((ShortcutChord, AppShortcut) -> Void)?

    init(settings: AppSettings, layout: SettingsPageLayout) {
        for (shortcut, recorder) in appShortcutRecorders {
            recorder.setAccessibilityLabel(String(localized: "\(shortcut.title) shortcut", comment: "Accessibility label for a shortcut recorder. The value is the localized command name, such as Next Note"))
            recorder.recorded = { [weak self] in self?.appShortcutRecorded?($0, shortcut) }
        }
        navigationError.textColor = .systemRed
        navigationError.isHidden = true
        show(settings)
        view = layout.page(String(localized: "Shortcuts", comment: "Settings category and page title for shortcuts used inside RAMnotes"), sections: [
            layout.section(String(localized: "RAMnotes Shortcuts", comment: "Settings section title. Keep the product name RAMnotes unchanged."), AppShortcut.allCases.map { layout.row($0.title, appShortcutRecorders[$0]!) } + [navigationError])])
    }

    func show(_ settings: AppSettings) {
        for (shortcut, recorder) in appShortcutRecorders { recorder.chord = settings.chord(for: shortcut) }
    }
    /// Shows or clears the conflict message under the command shortcuts.
    func showConflict(_ conflict: Bool) {
        navigationError.stringValue = conflict ? String(localized: "This shortcut is already used. Choose another combination.", comment: "Shown when a recorded shortcut conflicts with another") : ""
        navigationError.isHidden = !conflict
    }
    func cancelRecording() { appShortcutRecorders.values.forEach { $0.cancel() } }
}
