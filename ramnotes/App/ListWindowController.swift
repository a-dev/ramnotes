import ramnotesDomain
import AppKit

/// Owns the note list window: the note list, the shortcut and diagnostic labels, and recovery links.
@MainActor
final class ListWindowController {
    let discovery = NoteListController()
    let diagnostic = NSTextField(wrappingLabelWithString: String(localized: "Loading notes…", comment: "Note list footer status while notes load"))
    let missingFolderLabel = NSTextField(wrappingLabelWithString: String(localized: "Default folder is missing. Choose one in Settings.", comment: "Note list footer warning when the default notes folder no longer exists"))
    var defaultFolderMissing = false { didSet { updateFooterVisibility() } }
    let shortcutLabel = NSTextField(wrappingLabelWithString: String(localized: "Loading shortcut…", comment: "Note list footer status while the global shortcut registers"))
    private(set) var commandsButton: HeaderButton?
    private(set) var window: NSWindow?
    private var settings = AppSettings()
    private var recoveryStack: NSStackView?
    private var recoveryHeight: NSLayoutConstraint?
    private var footer: NSBox?
    nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

    deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }
    var showCommands: () -> Void = {}
    var showSettings: () -> Void = {}
    var escape: () -> Void = {}
    weak var recovery: RecoveryController?
    var isVisible: Bool { window?.isVisible == true }

    init() {
        discovery.isPresented = { [weak self] in self?.isVisible == true }
        discovery.notesChanged = { [weak self] in self?.noteStateChanged() }
    }

    /// Availability seen at the last footer update. A change ends the shown action result.
    private var lastAvailability: [NoteID: NoteAvailability] = [:]

    private func noteStateChanged() {
        let current = discovery.noteAvailability
        // Notes that were added or removed (for example, by the action itself) do not count.
        let changed = current.contains { id, value in lastAvailability[id].map { $0 != value } ?? false }
        lastAvailability = current
        if changed { clearActionResult() }
        updateFooterVisibility()
    }

    /// Builds the window on first use, then brings it forward. Calls `refresh` once after building.
    func present(focusing noteID: NoteID?, refresh: () -> Void) {
        if !isVisible { clearActionResult() }
        if window == nil {
            window = makeWindow()
            refresh()
        }
        updateFooterVisibility()
        window?.makeKeyAndOrderFront(nil)
        refresh()
        discovery.reveal()
        discovery.focus(noteID: noteID)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    let announcements = AccessibilityAnnouncements()

    func showFailure(_ message: String, refresh: () -> Void) {
        if window == nil { window = makeWindow() }
        diagnostic.stringValue = message
        window?.orderFront(nil)
        refresh()
        updateFooterVisibility()
        announcements.update(message, for: "failure")
    }

    func apply(_ value: AppSettings) {
        settings = EditorTypography.normalized(value)
        discovery.apply(settings)
        if let content = window?.contentView { InterfaceTypography.apply(to: content, scale: 1.0) }
        updateWindowMinimumSize()
    }

    func hide() {
        clearActionResult()
        window?.orderOut(nil)
    }

    /// The footer text set by `showActionResult`, if it is still shown.
    private var actionResult: String?

    /// Shows the result of a one-off action, such as moving notes to the Trash.
    /// Unlike failure diagnostics, it lasts only until the list is hidden or reopened, a note's
    /// availability changes, or a new recovery message appears.
    func showActionResult(_ text: String) {
        diagnostic.stringValue = text
        actionResult = text
        updateFooterVisibility()
    }

    private func clearActionResult() {
        defer { actionResult = nil }
        // A later diagnostic replaced the result: keep it.
        guard let actionResult, diagnostic.stringValue == actionResult else { return }
        diagnostic.stringValue = ""
        updateFooterVisibility()
    }

    func render(_ recovery: RecoveryController) {
        guard isVisible, let recoveryStack else { return }
        let messagesBefore = recoveryStack.arrangedSubviews.count
        recovery.render(in: recoveryStack, height: recoveryHeight)
        if recoveryStack.arrangedSubviews.count > messagesBefore { clearActionResult() }
        if let footer { InterfaceTypography.apply(to: footer, scale: 1.0) }
        updateFooterVisibility()
    }

    private func updateFooterVisibility() {
        // Problems with one note show on its card. The footer shows only window-wide messages.
        let hasError = defaultFolderMissing
        footer?.borderColor = hasError ? .systemRed : .separatorColor
        footer?.borderWidth = hasError ? 1 : 0.5
        missingFolderLabel.isHidden = !defaultFolderMissing
        diagnostic.isHidden = diagnostic.stringValue.isEmpty
        shortcutLabel.isHidden = shortcutLabel.stringValue.isEmpty
        footer?.isHidden = !hasError && diagnostic.isHidden && shortcutLabel.isHidden
            && (recoveryStack?.arrangedSubviews.isEmpty ?? true)
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: 420, height: 600)
        let window = GroupWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
        window.escape = { [weak self] in self?.escape() }
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Note list", comment: "Title of the note list window and its visible heading")
        window.setAccessibilityIdentifier("Note list")
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.minSize = NSSize(width: 420, height: 420)
        // Match the Note window: glass symbol buttons in the title bar row.
        let commands = HeaderButton(symbol: "ellipsis.circle", label: String(localized: "Commands", comment: "Note list header button and accessibility label that pops up the menu of all commands"), toolTip: String(localized: "Commands (⇧⌘?)", comment: "Tooltip of the Commands header button. Keep the shortcut symbols unchanged")) { [weak self] in self?.showCommands() }
        commandsButton = commands
        commands.setAccessibilityIdentifier("NoteListCommands")
        let settings = HeaderButton(symbol: "gearshape", label: String(localized: "Settings", comment: "Note list header button, tooltip and accessibility label that opens Settings"), toolTip: String(localized: "Settings", comment: "Note list header button, tooltip and accessibility label that opens Settings")) { [weak self] in self?.showSettings() }
        settings.setAccessibilityIdentifier("NoteListSettings")
        let controls = NSStackView(views: [settings])
        controls.spacing = HeaderMetrics.buttonSpacing
        controls.alignment = .centerY
        let menu = commands
        let header = HeaderRowView()
        let title = NSTextField(labelWithString: String(localized: "Note list", comment: "Title of the note list window and its visible heading"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        for child in [title, menu, controls] {
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        // The header sits inside the root's 12-point side insets; offsets place
        // the buttons where the Note window puts them relative to the window edge.
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            header.heightAnchor.constraint(equalToConstant: HeaderMetrics.height),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 66),
            menu.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -12),
            menu.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            menu.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: 6),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        root.addArrangedSubview(discovery.view)
        root.addSubview(header, positioned: .above, relativeTo: discovery.view)
        discovery.view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        let footerContent = NSStackView()
        footerContent.orientation = .vertical
        footerContent.alignment = .centerX
        footerContent.spacing = 6
        footerContent.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        footerContent.addArrangedSubview(scroll)
        for label in [shortcutLabel, diagnostic, missingFolderLabel] {
            label.alignment = .center
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            footerContent.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: footerContent.widthAnchor, constant: -24).isActive = true
        }
        let footer = NSBox()
        footer.boxType = .custom
        footer.titlePosition = .noTitle
        footer.fillColor = .controlBackgroundColor
        footer.borderColor = .separatorColor
        footer.borderWidth = 0.5
        footer.cornerRadius = 8
        footer.contentViewMargins = .zero
        footer.contentView = footerContent
        self.footer = footer
        root.setCustomSpacing(8, after: discovery.view)
        root.addArrangedSubview(footer)
        recoveryHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        recoveryHeight?.isActive = true
        NSLayoutConstraint.activate([footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: footerContent.widthAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        recoveryStack = stack
        scroll.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stack = self.recoveryStack, !stack.arrangedSubviews.isEmpty else { return }
                RecoveryController.fitFooterHeight(stack, height: self.recoveryHeight)
            }
        }
        window.contentView = root
        InterfaceTypography.apply(to: root, scale: 1.0)
        let autosaveName = WindowPlacement.frameAutosaveName("RAMnotes.NoteList")
        window.setFrameAutosaveName(autosaveName)
        let hasSavedFrame = window.setFrameUsingName(autosaveName)
        let savedFrame = hasSavedFrame ? window.frame : nil
        let restoredFrame = placement(savedFrame, defaultSize: size, minimumSize: minimumWindowSize)
        window.minSize = WindowPlacement.boundedMinimumSize(minimumWindowSize, for: restoredFrame)
        window.setFrame(restoredFrame, display: false)
        return window
    }

    private var minimumWindowSize: NSSize {
        NSSize(width: 420, height: 420)
    }

    private func updateWindowMinimumSize() {
        guard let window else { return }
        let minimum = minimumWindowSize
        window.minSize = WindowPlacement.boundedMinimumSize(minimum, for: window.frame)
        let frame = placement(window.frame, defaultSize: NSSize(width: 420, height: 600), minimumSize: minimum)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    private func placement(_ frame: CGRect?, defaultSize: NSSize, minimumSize: NSSize) -> CGRect {
        WindowPlacement.restore(frame: frame, defaultSize: defaultSize, minimumSize: minimumSize)
    }
}

/// Tracks active problems independently so background refreshes cannot repeat speech.
@MainActor
final class AccessibilityAnnouncements {
    private var messages: [String: String] = [:]
    private var waiting: [String: Task<Void, Never>] = [:]
    /// True while the user is typing. VoiceOver's key echo cuts off any announcement, so a
    /// warning waits until typing pauses and is then spoken once, if it still applies.
    var isBusy: () -> Bool = { false }
    var quietCheckInterval: Duration = .milliseconds(300)
    var deliver: (String, NSAccessibilityPriorityLevel) -> Void = { message, priority in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: priority.rawValue
        ])
    }

    /// Use `.high` for a warning that arrives while the user types: VoiceOver's key echo
    /// interrupts a medium-priority announcement, and the warning is spoken only once.
    func update(_ message: String?, for key: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard let message, !message.isEmpty else { messages[key] = nil; waiting[key]?.cancel(); waiting[key] = nil; return }
        guard messages[key] != message else { return }
        messages[key] = message
        waiting[key]?.cancel()
        guard isBusy() else { waiting[key] = nil; deliver(message, priority); return }
        waiting[key] = Task { [weak self] in
            while let self, self.isBusy() {
                do { try await Task.sleep(for: self.quietCheckInterval) } catch { return }
            }
            guard let self, self.messages[key] == message else { return }
            self.waiting[key] = nil
            self.deliver(message, priority)
        }
    }
}
