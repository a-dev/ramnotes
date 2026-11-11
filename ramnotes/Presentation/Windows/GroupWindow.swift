import AppKit

@MainActor
class GroupWindow: NSWindow {
    weak var headerView: NSView?

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out, let headerView {
            // Complete the native titlebar layout as well as the content layout
            // before ordering the window onto the screen.
            contentView?.superview?.layoutSubtreeIfNeeded()
            alignNativeHeaderControls(in: headerView)
        }
        super.order(place, relativeTo: otherWin)
    }

    var escape: (() -> Void)?
    var fontSizeRequested: ((Double?) -> Void)?
    var deleteRequested: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if attachedSheet == nil, let fontSizeRequested,
           modifiers == .command || modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "+", "=": fontSizeRequested(1)
            case "-" where modifiers == .command: fontSizeRequested(-1)
            case "0" where modifiers == .command: fontSizeRequested(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if attachedSheet != nil { super.cancelOperation(sender) }
        else { escape?() }
    }
}
