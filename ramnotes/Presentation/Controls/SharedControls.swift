import AppKit

/// A label that VoiceOver reads as `spokenText` instead of its visible text. Setting both
/// the label and the value makes VoiceOver read both strings.
@MainActor
final class SpokenLabel: NSTextField {
    var spokenText: String?
    override func accessibilityValue() -> String? { spokenText ?? super.accessibilityValue() }
    override func accessibilityLabel() -> String? { spokenText == nil ? super.accessibilityLabel() : nil }
}

/// A push button with a red title. A bordered push button ignores `contentTintColor` for its
/// title, so the color is set in the attributed title and kept when the font changes.
@MainActor
final class DestructiveButton: NSButton {
    override var font: NSFont? { didSet { applyColor() } }
    override var title: String { didSet { applyColor() } }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        bezelStyle = .push
        self.title = title
        self.target = target
        self.action = action
    }
    private func applyColor() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
    }
}

@MainActor
class ActionButton: NSButton {
    var onAction: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        onAction = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(performAction)
        setAccessibilityLabel(title)
        toolTip = title
    }
    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { onAction() }
}
