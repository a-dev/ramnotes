import ramnotesDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NoteSearchField: NSSearchField {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.secondaryLabelColor.withAlphaComponent(increasedContrast ? 0.8 : 0.10).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}


/// Keeps the first row below the overlay while allowing later rows to pass behind it.
@MainActor
final class HeaderScrollContainer: NSView {
    private let scrollView: NSScrollView
    private let header: NSView
    private var hasPositionedContent = false

    init(scrollView: NSScrollView, header: NSView) {
        self.scrollView = scrollView
        self.header = header
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The glass view lays out its stack after this container. Finish that
        // layout before measuring, including changes to the empty-state label.
        header.superview?.layoutSubtreeIfNeeded()
        let height = header.frame.height + 12
        guard !hasPositionedContent || scrollView.contentInsets.top != height else { return }
        let wasAtTop = (!hasPositionedContent && scrollView.contentView.bounds.minY == 0) || scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top
        hasPositionedContent = true
        scrollView.contentInsets.top = height
        if wasAtTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -height))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

@MainActor
final class FileRegistrationButton: ActionButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}
