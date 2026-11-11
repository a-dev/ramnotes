import AppKit

@MainActor
func alignNativeHeaderControls(in header: NSView) {
    guard let window = header.window else { return }
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
        let center = parent.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), from: header)
        let y = center.y - button.frame.height / 2
        if abs(button.frame.origin.y - y) > 0.01 {
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
        }
    }
}

@MainActor
final class HeaderRowView: NSView {
    override func layout() {
        super.layout()
        alignNativeHeaderControls(in: self)
    }
}

enum HeaderMetrics {
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 29
    static let verticalPadding: CGFloat = 6
    static let height = buttonHeight + 2 * verticalPadding
    static let buttonSpacing: CGFloat = 6
    static let symbolSize: CGFloat = 13
    static let capsuleCornerRadius: CGFloat = 16
}

// Keep compact header controls aligned to their layout bounds.
@MainActor
final class HeaderButton: NSButton {
    private var onAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    private func configureAppearance() {
        bezelStyle = .glass
        borderShape = .capsule
        isBordered = true
        showsBorderOnlyWhileMouseInside = false
        contentTintColor = .labelColor
    }

    /// A compact title-bar symbol button that runs `action` when clicked.
    convenience init(symbol: String, label: String, toolTip: String, action: @escaping () -> Void) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: HeaderMetrics.symbolSize, weight: .medium))!
        self.init(image: image, target: nil, action: nil)
        onAction = action
        target = self
        self.action = #selector(performAction)
        focusRingType = .exterior
        self.toolTip = toolTip
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: HeaderMetrics.buttonWidth).isActive = true
        heightAnchor.constraint(equalToConstant: HeaderMetrics.buttonHeight).isActive = true
    }

    @objc private func performAction() { onAction?() }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor
final class ToneBackingView: NSGlassEffectView {
    override func layout() {
        super.layout()
        alignNativeHeaderControls(in: self)
    }

    let controlsView = NSView()
    var surface: NSColor = .textBackgroundColor {
        didSet { tintColor = surface.withAlphaComponent(0.18) }
    }
    var appearanceChanged: (() -> Void)?
    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 0
        contentView = controlsView
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaySettingsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func displaySettingsChanged() {
        appearanceChanged?()
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
        needsDisplay = true
    }
}

/// Wraps a title-bar control in the shared glass bezel.
@MainActor
func headerGlass(_ control: NSView) -> NSGlassEffectView {
    // Draw our own bezel so buttons and segments share exact bounds.
    // Native bezels can draw outside their frames.
    let glass = NSGlassEffectView()
    glass.style = .regular
    glass.cornerRadius = HeaderMetrics.capsuleCornerRadius
    glass.effectIsInteractive = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    glass.contentView = control
    control.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        control.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
        control.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        control.topAnchor.constraint(equalTo: glass.topAnchor),
        control.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
    ])
    return glass
}
