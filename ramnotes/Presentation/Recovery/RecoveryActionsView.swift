import AppKit

/// Lays out recovery buttons left to right and wraps them into rows that fit the width,
/// so every action stays visible as a button even in a narrow window.
/// Call `actionsChanged()` after showing or hiding a button.
@MainActor
final class RecoveryActionsView: NSView {
    private let spacing: CGFloat = 6
    /// Placed at the trailing edge of the last row, apart from the other actions,
    /// or at the leading edge of a new row when it does not fit.
    weak var trailing: NSView? { didSet { actionsChanged() } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frames(width: bounds.width).height)
    }
    func actionsChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = true
        actionsChanged()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { actionsChanged() }
    }
    override func layout() {
        super.layout()
        for (view, frame) in frames(width: bounds.width).frames { view.frame = frame }
    }
    /// Row layout of the visible buttons. A zero width (before the first layout) keeps one row.
    private func frames(width: CGFloat) -> (frames: [(NSView, NSRect)], height: CGFloat) {
        var result: [(NSView, NSRect)] = []
        var origin = NSPoint.zero
        var rowHeight: CGFloat = 0
        for view in subviews where !view.isHidden && view !== trailing {
            let size = view.fittingSize
            if origin.x > 0, width > 0, origin.x + size.width > width {
                origin = NSPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            result.append((view, NSRect(origin: origin, size: size)))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if let trailing, !trailing.isHidden {
            let size = trailing.fittingSize
            var wrapped = false
            if origin.x > 0, width > 0, origin.x + spacing * 2 + size.width > width {
                origin = NSPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
                wrapped = true
            }
            // On a row of its own it starts at the leading edge, under the other actions.
            let x = width > 0 && !wrapped ? max(0, width - size.width) : origin.x
            result.append((trailing, NSRect(origin: NSPoint(x: x, y: origin.y), size: size)))
            rowHeight = max(rowHeight, size.height)
        }
        return (result, origin.y + rowHeight)
    }
}
