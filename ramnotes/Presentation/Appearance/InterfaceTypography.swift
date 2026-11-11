import AppKit

@MainActor
enum InterfaceTypography {
    private static let fonts = NSMapTable<NSControl, NSFont>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static func apply(to view: NSView, scale: Double) {
        if view is NSTableView { return }
        (view as? ShortcutRecorder)?.applyInterfaceScale(scale)
        if let control = view as? NSControl, !(control is NSStepper) {
            let original = fonts.object(forKey: control) ?? control.font ?? NSFont.systemFont(ofSize: 13)
            fonts.setObject(original, forKey: control)
            control.font = NSFont(descriptor: original.fontDescriptor, size: original.pointSize * scale)
        }
        for child in view.subviews { apply(to: child, scale: scale) }
    }
}
