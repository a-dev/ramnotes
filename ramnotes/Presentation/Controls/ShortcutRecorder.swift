import AppKit
import Carbon

@MainActor
final class ShortcutRecorder: NSButton, NSPopoverDelegate {
    var chord: ShortcutChord = .default { didSet { refreshTitle() } }
    private let popover = NSPopover()
    private var interfaceScale = 1.0
    private var interfaceWidth: NSLayoutConstraint!
    private var interfaceHeight: NSLayoutConstraint!
    private let modifierPreview = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: String(localized: "Add a key", comment: "Prompt in the shortcut recording popover after modifier keys were pressed"))
    var recorded: ((ShortcutChord) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    /// The popover text is not focused, so VoiceOver does not read its changes by itself.
    var announce: (String) -> Void = { message in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private var recording = false
    private var monitor: Any?
    init() {
        super.init(frame: .zero)
        title = ShortcutChord.default.title
        bezelStyle = .rounded
        font = .systemFont(ofSize: 14, weight: .medium)
        interfaceWidth = widthAnchor.constraint(equalToConstant: 180)
        interfaceHeight = heightAnchor.constraint(equalToConstant: 32)
        interfaceWidth.isActive = true
        interfaceHeight.isActive = true
        toolTip = String(localized: "Click to record a shortcut", comment: "Tooltip of the shortcut recorder button")
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel(String(localized: "Record Shortcut", comment: "Accessibility label of the shortcut recorder button"))
    }
    func applyInterfaceScale(_ scale: Double) {
        interfaceScale = scale
        interfaceWidth.constant = 180 * scale
        interfaceHeight.constant = 32 * scale
    }
    private func refreshTitle() {
        title = recording ? String(localized: "Type shortcut…", comment: "Title of the shortcut recorder button while it waits for a key combination") : chord.title
        setAccessibilityValue(chord.title)
    }
    private func showRecordingPopover() {
        let escape = NSTextField(labelWithString: String(localized: "esc", comment: "Label of the Escape key in the recording popover. Use the keyboard term, lowercase if keyboards in your language print it that way"))
        escape.font = .systemFont(ofSize: 13, weight: .medium)
        escape.textColor = .secondaryLabelColor
        escape.alignment = .center
        escape.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        modifierPreview.font = .systemFont(ofSize: 15, weight: .medium)
        modifierPreview.alignment = .center
        // The key cap pads the label. Its minimum width stops the popover jumping as modifiers change.
        let keyCap = NSView()
        modifierPreview.translatesAutoresizingMaskIntoConstraints = false
        keyCap.addSubview(modifierPreview)
        NSLayoutConstraint.activate([
            modifierPreview.centerXAnchor.constraint(equalTo: keyCap.centerXAnchor),
            modifierPreview.centerYAnchor.constraint(equalTo: keyCap.centerYAnchor),
            modifierPreview.leadingAnchor.constraint(greaterThanOrEqualTo: keyCap.leadingAnchor, constant: 16),
            modifierPreview.topAnchor.constraint(equalTo: keyCap.topAnchor, constant: 10),
            keyCap.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        for view in [escape, keyCap] {
            view.wantsLayer = true
            view.layer?.cornerRadius = 7
            view.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        // A trailing spacer keeps esc at the leading edge. The other rows stay centered.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        escape.setContentHuggingPriority(.required, for: .horizontal)
        let escapeRow = NSStackView(views: [escape, spacer])
        escapeRow.orientation = .horizontal
        prompt.font = .systemFont(ofSize: 13, weight: .semibold)
        prompt.textColor = .secondaryLabelColor
        let content = NSStackView(views: [escapeRow, keyCap, prompt])
        content.orientation = .vertical
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        content.frame = NSRect(x: 0, y: 0, width: 180, height: 124)
        escapeRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.delegate = self
        if let content = popover.contentViewController?.view { InterfaceTypography.apply(to: content, scale: interfaceScale) }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
    func popoverDidClose(_ notification: Notification) { if recording { finish() } }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    @objc private func beginRecording() {
        cancel()
        recording = true
        refreshTitle()
        modifierPreview.stringValue = " "
        prompt.stringValue = String(localized: "Add a key", comment: "Prompt in the shortcut recording popover after modifier keys were pressed")
        recordingChanged?(true)
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.recording, self.window?.isKeyWindow == true else { return false }
                if event.type == .flagsChanged {
                    let symbols = ShortcutChord(event: event).modifierSymbols
                    self.modifierPreview.stringValue = symbols.isEmpty ? " " : symbols
                } else { self.keyDown(with: event) }
                return true
            }
            return consumed ? nil : event
        }
        showRecordingPopover()
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    func cancel() { finish() }
    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let wasRecording = recording
        recording = false
        popover.close()
        refreshTitle()
        if wasRecording { recordingChanged?(false) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    func accept(_ chord: ShortcutChord) { finish(); recorded?(chord) }
    override func keyDown(with event: NSEvent) {
        // When not recording, keys keep their normal meaning: Tab moves focus, Space records.
        guard recording else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { finish(); return }
        let chord = ShortcutChord(event: event)
        guard chord.isValid else {
            prompt.stringValue = String(localized: "Include ⌘, ⌥, or ⌃", comment: "Error in the recording popover when the shortcut has no modifier key. Keep the modifier symbols unchanged")
            // VoiceOver skips the modifier symbols, so speak their names.
            announce(String(localized: "Include Command, Option, or Control.", comment: "VoiceOver announcement when a recorded shortcut has no modifier key. Use the names your language's keyboards and macOS use for these keys"))
            return
        }
        accept(chord)
    }
}
