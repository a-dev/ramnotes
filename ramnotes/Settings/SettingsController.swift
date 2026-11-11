import AppKit

/// Pop-up items keep the stored value in `representedObject`, so titles can be localized
/// while `AppSettings` keeps the same raw strings ("System", "Regular", …).
extension NSPopUpButton {
    var selectedRawValue: String? { selectedItem?.representedObject as? String }
    func selectRawValue(_ value: String) {
        if let item = itemArray.first(where: { ($0.representedObject as? String) == value }) { select(item) }
    }
    func rawItem(_ value: String) -> NSMenuItem? { itemArray.first { ($0.representedObject as? String) == value } }
    func setRawItems(_ values: [String], title: (String) -> String) {
        removeAllItems()
        for value in values {
            addItem(withTitle: title(value))
            lastItem?.representedObject = value
        }
    }
}

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let sidebar = NSTableView()
    private let detail = NSView()
    private var focusObservation: NSKeyValueObservation?
    private var pages: [NSView] = []
    private let layout = SettingsPageLayout()
    private let general: GeneralSettingsPage
    private let editor: EditorSettingsPage
    private let windows: WindowsSettingsPage
    private let shortcuts: ShortcutSettingsPage
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var detailWidthConstraint: NSLayoutConstraint?
    private static let categories = [(String(localized: "General", comment: "Settings category and page title"), "gearshape"),
                              (String(localized: "Windows", comment: "Settings category and page title for window behavior, global shortcuts, and menu bar gestures"), "macwindow"),
                              (String(localized: "Appearance", comment: "Settings category and page title"), "paintpalette"),
                              (String(localized: "Shortcuts", comment: "Settings category and page title for shortcuts used inside RAMnotes"), "keyboard"), (String(localized: "About", comment: "Settings category and page title"), "info.circle")]
    private var categories: [(String, String)] { Self.categories }
    /// The settings this window last showed or edited. `SettingsCoordinator` owns the accepted value.
    private var settings: AppSettings
    var folderStatus: NSTextField { general.folderStatus }
    var missingFolderStatus: NSTextField { general.missingFolderStatus }
    var loginStatus: NSTextField { general.loginStatus }
    var login: NSButton { general.login }
    var folderProgress: NSProgressIndicator { general.folderProgress }
    var folderActivityLabel: NSTextField { general.folderActivityLabel }
    var error: NSTextField { editor.error }
    var shortcutStatus: NSTextField { windows.shortcutStatus }
    var gestureStatus: NSTextField { windows.gestureStatus }
    var bringForwardCheckbox: NSButton { windows.bringForward }
    var recorder: ShortcutRecorder { windows.recorder }
    var listGlobalRecorder: ShortcutRecorder { windows.listGlobalRecorder }
    var appShortcutRecorders: [AppShortcut: ShortcutRecorder] { shortcuts.appShortcutRecorders }
    var nextNoteRecorder: ShortcutRecorder { appShortcutRecorders[.nextNote]! }
    var previousNoteRecorder: ShortcutRecorder { appShortcutRecorders[.previousNote]! }
    func showMissingDefaultFolder(_ missing: Bool) { general.showMissingDefaultFolder(missing) }
    func showShortcutStatus(_ message: String) { windows.showShortcutStatus(message) }
    func showFolderActivity(busy: Bool) {
        general.showFolderActivity(busy: busy, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    /// Shows Refresh only while macOS waits for the user to approve the login item.
    func showLoginRefresh(_ visible: Bool) { general.showLoginRefresh(visible) }
    var changed: ((AppSettings) -> Void)?
    var chooseFolder: (() -> Void)?
    var becameKey: (() -> Void)?
    var loginChanged: ((Bool) -> Void)?
    var openLoginSettings: (() -> Void)?
    var refreshLogin: (() -> Void)?
    var quit: (() -> Void)?
    /// 176 pt, or wider when a translated category title or the Quit button needs more room.
    /// Button: 16 pt margins and bezel padding.
    private static let sidebarWidth: CGFloat = {
        // The selected row is semibold, which is wider than regular.
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let widest = categories.map { ceil(($0.0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        let quit = NSButton(title: String(localized: "Quit RAMnotes", comment: "Fixed shortcut list entry and sidebar button that quits the app. Keep the product name RAMnotes unchanged."), target: nil, action: nil)
        return max(176, 16 + 8 + 20 + 10 + widest + 8 + 16 + 4, quit.fittingSize.width + 32)
    }()
    private static let detailWidth: CGFloat = 500

    init(settings: AppSettings, updateControls: NSView? = nil, frameAutosaveName: String = WindowPlacement.frameAutosaveName("RAMnotes.Settings")) {
        let settings = EditorTypography.normalized(settings)
        self.settings = settings
        general = GeneralSettingsPage(layout: layout)
        editor = EditorSettingsPage(settings: settings, layout: layout)
        windows = WindowsSettingsPage(settings: settings, layout: layout)
        shortcuts = ShortcutSettingsPage(settings: settings, layout: layout)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 150, width: Self.sidebarWidth + 1 + Self.detailWidth, height: 620), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayPreferencesChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        window.title = String(localized: "Settings", comment: "Window title and menu bar item for the settings window")
        window.setAccessibilityIdentifier("Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.sidebarWidth + 1 + Self.detailWidth, height: 540)
        // A scroll view does not follow keyboard focus, so Tab could land on a hidden control.
        focusObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.revealFocusedControl(in: window) }
        }
        general.chooseFolder = { [weak self] in self?.chooseFolder?() }
        general.loginChanged = { [weak self] in self?.loginChanged?($0) }
        general.openLoginSettings = { [weak self] in self?.openLoginSettings?() }
        general.refreshLogin = { [weak self] in self?.refreshLogin?() }
        windows.alwaysOnTopChanged = { [weak self] in self?.edit { $0.alwaysOnTop = $1 }($0) }
        editor.appearanceChanged = { [weak self] in self?.edit { $0.appearance = $1 }($0) }
        editor.typographyChanged = { [weak self] value in
            self?.edit { settings, value in
                settings.fontFamily = value.fontFamily
                settings.fontWeight = value.fontWeight
                settings.fontSize = value.fontSize
                settings.lineHeight = value.lineHeight
            }(value)
        }
        windows.gesturesChanged = { [weak self] vertical, horizontal in
            self?.edit { settings, _ in
                settings.menuBarGestureEnabled = vertical
                settings.menuBarHorizontalGestureEnabled = horizontal
            }(())
        }
        windows.bringForwardChanged = { [weak self] in self?.edit { $0.bringNotesForwardWhenInactive = $1 }($0) }
        shortcuts.appShortcutRecorded = { [weak self] in self?.changeAppShortcut($0, for: $1) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
        pages = [general.view, windows.view, editor.view, shortcuts.view,
                 AboutSettingsPage.make(version: version, copyright: copyright, updateControls: updateControls, layout: layout)]
        // A plain container, not NSSplitView: the sidebar width is fixed, and a split view would
        // expose a splitter that VoiceOver and Switch Control stop on but cannot move.
        let container = NSView()
        let separator = NSBox()
        separator.boxType = .separator
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category")))
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 36
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel(String(localized: "Settings categories", comment: "Accessibility label for the list of settings categories"))
        sidebarScroll.documentView = sidebar
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebarScroll)
        let quitButton = ActionButton(String(localized: "Quit RAMnotes", comment: "Fixed shortcut list entry and sidebar button that quits the app. Keep the product name RAMnotes unchanged.")) { [weak self] in self?.quit?() }
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(quitButton)
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 12),
            sidebarScroll.bottomAnchor.constraint(equalTo: quitButton.topAnchor, constant: -16),
            sidebarScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            quitButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            quitButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            quitButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16)
        ])
        sidebarWidthConstraint = background.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        detailWidthConstraint = detail.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.detailWidth)
        sidebarWidthConstraint?.isActive = true
        detailWidthConstraint?.isActive = true
        for view in [background, separator, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: background.trailingAnchor),
            detail.topAnchor.constraint(equalTo: container.topAnchor),
            detail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        window.contentView = container
        window.initialFirstResponder = sidebar
        showPage(0)
        applyInterfaceScale()
        let autosaveName = frameAutosaveName
        window.setFrameAutosaveName(autosaveName)
        let hasSavedFrame = window.setFrameUsingName(autosaveName)
        let savedFrame = hasSavedFrame ? window.frame : nil
        let restoredFrame = placement(savedFrame, defaultSize: window.frame.size, minimumSize: frameMinimumSize)
        window.minSize = WindowPlacement.boundedMinimumSize(frameMinimumSize, for: restoredFrame)
        window.setFrame(restoredFrame, display: false)
    }
    /// Applies one page edit to the shown settings and reports the result.
    private func edit<Value>(_ change: @escaping (inout AppSettings, Value) -> Void) -> (Value) -> Void {
        { [weak self] value in
            guard let self else { return }
            change(&settings, value)
            changed?(settings)
        }
    }
    private func changeAppShortcut(_ chord: ShortcutChord, for shortcut: AppShortcut) {
        guard !settings.isTaken(chord, except: shortcut), chord != recorder.chord, chord != listGlobalRecorder.chord else {
            shortcuts.showConflict(true)
            return
        }
        shortcuts.showConflict(false)
        settings.setChord(chord, for: shortcut)
        appShortcutRecorders[shortcut]?.chord = chord
        changed?(settings)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: categories[row].0)
        label.font = .systemFont(ofSize: 13)
        let icon = NSImageView(image: NSImage(systemSymbolName: categories[row].1, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        cell.textField = label
        cell.imageView = icon
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showPage(sidebar.selectedRow) }
    private var shownPage = 0
    /// Selects the shown page's category and focuses the list, so the keyboard can choose a
    /// page right away. Call it each time the window opens.
    func focusCategories() {
        if sidebar.numberOfRows == 0 { sidebar.reloadData() }
        if sidebar.selectedRow != shownPage { sidebar.selectRowIndexes(IndexSet(integer: shownPage), byExtendingSelection: false) }
        window?.makeFirstResponder(sidebar)
    }
    private func showPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        shownPage = index
        cancelRecording()
        window?.makeFirstResponder(sidebar)
        detail.subviews.forEach { $0.removeFromSuperview() }
        let page = pages[index]
        page.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: detail.safeAreaLayoutGuide.topAnchor), page.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: detail.leadingAnchor), page.trailingAnchor.constraint(equalTo: detail.trailingAnchor)
        ])
        // The key view loop was built for the previous page. Without this, Tab only cycles
        // between the category list and Quit, and the new page's controls are unreachable.
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
    }
    /// Scrolls the page so the focused control, with some room around it, is visible.
    private func revealFocusedControl(in window: NSWindow) {
        guard var view = window.firstResponder as? NSView else { return }
        // Reveal the field that contains the field editor.
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { view = field }
        guard view.isDescendant(of: detail), view.enclosingScrollView != nil else { return }
        view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -16))
    }
    private func applyInterfaceScale() {
        let scale = 1.0
        for page in pages { InterfaceTypography.apply(to: page, scale: scale) }
        if let content = window?.contentView { InterfaceTypography.apply(to: content, scale: scale) }
        sidebar.rowHeight = max(36, ceil(16 * scale) + 16)
        sidebar.reloadData()
        for row in layout.adaptiveRows {
            row.orientation = scale > 1.25 ? .vertical : .horizontal
            row.alignment = scale > 1.25 ? .leading : .centerY
        }
        for (constraint, width) in layout.scaledWidths { constraint.constant = width * scale }
        sidebarWidthConstraint?.constant = Self.sidebarWidth * min(scale, 1.4)
        detailWidthConstraint?.constant = Self.detailWidth + (scale - 1) * 100
        let requestedMinimum = NSSize(width: Self.sidebarWidth * min(scale, 1.4) + Self.detailWidth + (scale - 1) * 100 + 1,
                                      height: 540)
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(window.frame) } ?? NSScreen.main
        let chromeWidth = max(0, window.frame.width - window.contentLayoutRect.width)
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let minimum = NSSize(
            width: min(requestedMinimum.width, max(0, (screen?.visibleFrame.width ?? requestedMinimum.width) - chromeWidth)),
            height: min(requestedMinimum.height, max(0, (screen?.visibleFrame.height ?? requestedMinimum.height) - chromeHeight))
        )
        window.contentMinSize = minimum
        let frameMinimum = frameMinimumSize
        window.minSize = WindowPlacement.boundedMinimumSize(frameMinimum, for: window.frame)
        if window.contentLayoutRect.width < minimum.width || window.contentLayoutRect.height < minimum.height {
            window.setContentSize(NSSize(width: max(minimum.width, window.contentLayoutRect.width),
                                         height: max(minimum.height, window.contentLayoutRect.height)))
        }
        let restored = placement(window.frame, defaultSize: window.frame.size, minimumSize: frameMinimum)
        if restored != window.frame { window.setFrame(restored, display: true) }
    }

    private var frameMinimumSize: NSSize {
        guard let window else { return NSSize(width: Self.sidebarWidth + Self.detailWidth + 1, height: 540) }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
    }

    private func placement(_ frame: CGRect?, defaultSize: NSSize, minimumSize: NSSize) -> CGRect {
        WindowPlacement.restore(frame: frame, defaultSize: defaultSize, minimumSize: minimumSize)
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func displayPreferencesChanged() {
        applyDisplayPreferences()
    }

    func applyDisplayPreferences(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        general.applyDisplayPreferences(reduceMotion: reduceMotion)
    }

    required init?(coder: NSCoder) { nil }
    func reload(_ value: AppSettings) {
        settings = EditorTypography.normalized(value)
        applyInterfaceScale()
        editor.show(settings)
        windows.show(settings)
        shortcuts.show(settings)
    }
    func windowWillClose(_ notification: Notification) { cancelRecording() }
    /// Stops every recorder, so a hidden one cannot capture the next keypress.
    private func cancelRecording() {
        windows.cancelRecording()
        shortcuts.cancelRecording()
    }
    func windowDidBecomeKey(_ notification: Notification) { becameKey?() }
}

extension AppearancePreference {
    static let allValues: [AppearancePreference] = [.system, .light, .dark]

    @MainActor var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
