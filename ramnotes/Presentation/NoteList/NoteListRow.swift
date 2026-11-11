import ramnotesDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NoteListRow: NSTableRowView {
    var isMenuTarget = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaySettingsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func displaySettingsChanged() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var cardRect: NSRect {
        // Leading inset is 12 pt, trailing is `noteCardTrailingPadding`. NSRect math is physical, so swap sides in RTL.
        let leadingInset: CGFloat = 12
        let leftInset = userInterfaceLayoutDirection == .rightToLeft ? noteCardTrailingPadding : leadingInset
        return NSRect(x: visibleRect.minX + leftInset, y: bounds.minY,
                      width: visibleRect.width - leadingInset - noteCardTrailingPadding, height: bounds.height - 12)
            .insetBy(dx: 0.25, dy: 0.25)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let fill = NSColor.controlBackgroundColor
        let border = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : NSColor.separatorColor
        let card = cardPath(in: cardRect)
        fill.setFill()
        card.fill()
        border.setStroke()
        card.lineWidth = 0.5
        card.stroke()
        guard isMenuTarget else { return }
        NSColor.controlAccentColor.setStroke()
        let ring = cardPath(in: cardRect.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = increasedContrast ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.45)
        color.setStroke()
        let outline = cardPath(in: cardRect.insetBy(dx: 0.75, dy: 0.75))
        outline.lineWidth = increasedContrast ? 2 : 1
        outline.stroke()
    }

    private func cardPath(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(cgPath: RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: rect).cgPath)
    }
}
