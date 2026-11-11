import AppKit

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let editor: NoteEditorController
    let externalChangeFooter = SpokenLabel(wrappingLabelWithString: "")
    private let noticeContainer = NSStackView()
    private var noticeTimestamp: Date?
    private var noticeTimer: Task<Void, Never>?
    // Written once during setup on the main actor, read only in deinit.
    nonisolated(unsafe) private var environmentObservers: [NSObjectProtocol] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private let locationIcon = NSImageView()
    private let titleContent = NSStackView()
    var defaultFolder: URL? { didSet { updateLocationIcon() } }
    private var trashConfirmation: NSAlert?
    let header = ToneBackingView()
    let backgroundTintButton = HeaderButton()
    private(set) var backgroundTintMenu = NSMenu()
    var backgroundToneChanged: ((NoteBackgroundTone?) -> Void)?
    func setBackgroundTone(_ tone: NoteBackgroundTone?) {
        editor.backgroundTone = tone
        applyBackground()
        backgroundTintButton.setAccessibilityValue(NoteBackgroundTone.localizedName(tone))
        for (index, item) in backgroundTintMenu.items.enumerated() {
            item.state = (index == 0 ? tone == nil : tone == NoteBackgroundTone.allCases[index - 1]) ? .on : .off
        }
    }
    private func applyBackground() {
        let color = NoteTonePalette.surface(editor.backgroundTone)
        window?.backgroundColor = color
        header.surface = color
        editor.applyBackground()
        let errorColor = NoteTonePalette.readable(.systemRed, on: color)
        errorBlock.applyErrorColor(errorColor)
        externalChangeFooter.textColor = NoteTonePalette.readable(.secondaryLabelColor, on: color)
    }
    @objc private func showBackgroundTints() {
        let previousResponder = window?.firstResponder
        backgroundTintMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: backgroundTintButton.bounds.maxY), in: backgroundTintButton)
        window?.makeFirstResponder(previousResponder ?? editor.textView)
    }
    @objc func chooseBackgroundTint(_ sender: NSMenuItem) {
        let tone = sender.tag == 0 ? nil : NoteBackgroundTone.allCases[sender.tag - 1]
        setBackgroundTone(tone)
        backgroundToneChanged?(tone)
    }
    let fontSizeControl = NSStackView()
    private(set) var fontSizeButtons: [NSButton] = []
    private(set) var headerGlassViews: [NSGlassEffectView] = []
    private(set) var headerButtons: [NSButton] = []
    /// Save status and recovery actions. This controller supplies display state and routes its actions.
    let errorBlock = RecoveryBannerView()
    var status: NSTextField { errorBlock.status }
    var recoveryActionButtons: [String: NSButton] { errorBlock.actionButtons }
    private(set) var errorScrollView = NSScrollView()
    private var errorScrollWidth: NSLayoutConstraint?
    private var errorScrollHeight: NSLayoutConstraint?
    private var errorDocumentWidth: NSLayoutConstraint?
    private var interfaceScale = 1.0
    private(set) var recoveryNotice: RecoveryNotice?
    /// The time Note list sorts this note by while it has unsaved edits. Once the text is preserved
    /// in a recovery note, that note carries the edits, so this one keeps its file date and the two
    /// rows do not trade places on every keystroke.
    var listedEditTime: Date? { recoveryNotice == nil ? editor.lastEditedAt : nil }
    var hideRequested: (() -> Void)?
    var deleteRequested: (() -> Void)?
    var newRequested: (() -> Void)?
    var listRequested: (() -> Void)?
    var allowFolderAccessRequested: (() -> Void)?
    var locationRequested: ((@escaping () -> Void) -> Void)?
    var exportRequested: (() -> Void)?
    var saveCopyRequested: (() -> Void)?
    var closeWithoutSavingRequested: (() -> Void)?
    var originalRequested: (() -> Void)?
    var recoveryRequested: (() -> Void)?
    var focusLost: (() -> Void)?
    var focused: (() -> Void)?
    var geometryChanged: (() -> Void)?

    // Edit > Undo goes through the window. Return the text view's history, not a separate one.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor.textView.undoManager
    }

    init(editor: NoteEditorController) {
        self.editor = editor
        let window = GroupWindow(contentRect: NSRect(x: 180, y: 180, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayPreferencesChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        window.fontSizeRequested = { [weak editor] delta in
            if let delta { editor?.adjustFontSize(by: delta) }
            else { editor?.setFontSize(nil) }
        }
        window.deleteRequested = { [weak self] in self?.deleteNote() }
        NotificationCenter.default.addObserver(self, selector: #selector(textTyped), name: NSText.didChangeNotification, object: editor.textView)
        announcements.isBusy = { [weak self] in
            guard let typed = self?.lastTyping else { return false }
            return Date().timeIntervalSince(typed) < 1.0
        }
        window.title = editor.note.title
        window.isDocumentEdited = editor.state.hasUnsavedEdits
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 375, height: 260)
        window.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications]
        window.delegate = self
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.headerView = header
        titleLabel.stringValue = editor.note.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = editor.note.title
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        configureHeader()
        let editorSurface = HeaderScrollContainer(scrollView: editor.scrollView, header: header)
        root.addArrangedSubview(editorSurface)
        for child in [editor.scrollView, header] {
            child.translatesAutoresizingMaskIntoConstraints = false
            editorSurface.addSubview(child)
        }
        editor.scrollView.automaticallyAdjustsContentInsets = false
        editor.scrollView.contentInsets.top = HeaderMetrics.height
        NSLayoutConstraint.activate([
            editorSurface.widthAnchor.constraint(equalTo: root.widthAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: editorSurface.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: editorSurface.trailingAnchor),
            editor.scrollView.topAnchor.constraint(equalTo: editorSurface.topAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: editorSurface.bottomAnchor),
            header.topAnchor.constraint(equalTo: editorSurface.topAnchor),
            header.leadingAnchor.constraint(equalTo: editorSurface.leadingAnchor)
        ])
        noticeContainer.orientation = .vertical
        noticeContainer.edgeInsets = NSEdgeInsets(top: 5, left: 16, bottom: 7, right: 16)
        noticeContainer.addArrangedSubview(externalChangeFooter)
        externalChangeFooter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        externalChangeFooter.isSelectable = false
        externalChangeFooter.setAccessibilityIdentifier("externalChangeNotice")
        root.addArrangedSubview(noticeContainer)
        noticeContainer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        externalChangeFooter.widthAnchor.constraint(equalTo: noticeContainer.widthAnchor, constant: -32).isActive = true
        noticeContainer.isHidden = true
        // The day-change notification is posted on a background queue at midnight.
        // Deliver every one on the main queue, where this controller is isolated.
        environmentObservers = [NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSCalendarDayChanged,
                                NSLocale.currentLocaleDidChangeNotification, NSApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshExternalChangeNotice() }
            }
        }
        errorBlock.actionRequested = { [weak self] in self?.performRecoveryAction($0) }
        errorBlock.dismissRequested = { [weak self] in self?.dismissRecoveryWarning() }
        errorScrollView.documentView = errorBlock
        root.addArrangedSubview(errorScrollView)
        errorScrollView.isHidden = true
        errorBlock.isHidden = true
        updateActionAvailability()
        window.contentView = root
        header.appearanceChanged = { [weak self] in self?.applyBackground() }
        setBackgroundTone(nil)
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: HeaderMetrics.height),
            editor.scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: 0),
            editor.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        errorScrollView.hasVerticalScroller = true
        errorScrollView.autohidesScrollers = true
        errorScrollView.drawsBackground = false
        errorScrollView.borderType = .noBorder
        errorScrollView.setAccessibilityLabel(String(localized: "Save status and recovery actions", comment: "Accessibility label for the scroll area that holds the save status and recovery buttons"))
        errorBlock.translatesAutoresizingMaskIntoConstraints = false
        errorScrollHeight = errorScrollView.heightAnchor.constraint(equalToConstant: 100)
        errorScrollWidth = errorScrollView.widthAnchor.constraint(equalTo: root.widthAnchor)
        errorDocumentWidth = errorBlock.widthAnchor.constraint(equalTo: errorScrollView.contentView.widthAnchor)
        errorScrollWidth?.isActive = true
        errorDocumentWidth?.isActive = true
        window.initialFirstResponder = editor.textView
        window.recalculateKeyViewLoop()
        editor.statusChanged = { [weak self] in self?.display($0) }
        editor.titleChanged = { [weak self] title in self?.updateTitle(title) }
        editor.documentStateChanged = { [weak self] in self?.updateDocumentState() }
    }

    func setExternalChangeNotice(_ timestamp: Date?) {
        guard timestamp != noticeTimestamp else { return }
        noticeTimestamp = timestamp
        noticeContainer.isHidden = timestamp == nil
        noticeTimer?.cancel()
        noticeTimer = nil
        if timestamp != nil {
            // Recalculate the next local midnight after clock or timezone changes.
            refreshExternalChangeNotice()
        }
    }

    func refreshExternalChangeNotice() {
        guard let timestamp = noticeTimestamp else { return }
        let calendar = Calendar.autoupdatingCurrent
        let text = Self.externalChangeText(timestamp: timestamp)
        externalChangeFooter.stringValue = text.label
        externalChangeFooter.toolTip = text.description
        externalChangeFooter.spokenText = text.description
        noticeTimer?.cancel()
        if let midnight = calendar.nextDate(after: Date(), matching: DateComponents(hour: 0), matchingPolicy: .nextTime) {
            let delay = max(0, midnight.timeIntervalSinceNow)
            noticeTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.refreshExternalChangeNotice()
            }
        }
    }

    static func externalChangeText(timestamp: Date, now: Date = Date(),
                                   locale: Locale = .autoupdatingCurrent,
                                   timeZone: TimeZone = .autoupdatingCurrent) -> (label: String, description: String) {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        // Hour without a fixed cycle lets each locale pick 12- or 24-hour time.
        style = calendar.isDate(timestamp, inSameDayAs: now)
            ? style.hour().minute()
            : style.day().month(.abbreviated).year().hour().minute()
        let display = timestamp.formatted(style)
        let full = timestamp.formatted(Date.FormatStyle(date: .complete, time: .complete, locale: locale, calendar: calendar, timeZone: timeZone))
        return (String(localized: "Changed outside • \(display)", comment: "Note footer after an outside edit; value is a date or time"),
                String(localized: "Changed outside RAMnotes • \(full)", comment: "Note footer tooltip after an outside edit; value is the full date and time"))
    }

    private func configureHeader() {
        let actions: [(String, String, Selector, String)] = [
            ("list.bullet", String(localized: "Note list", comment: "Header button tooltip and accessibility label that shows the note list window"), #selector(list), String(localized: "Note list", comment: "Header button tooltip and accessibility label that shows the note list window")),
            ("plus", String(localized: "New Note", comment: "Header button tooltip and accessibility label that creates a note"), #selector(newNote), String(localized: "New Note", comment: "Header button tooltip and accessibility label that creates a note")),
            ("trash", String(localized: "Move to Trash", comment: "Header button tooltip, accessibility label and alert button that moves the note to the Trash. Use the system term for Trash"), #selector(deleteNote), String(localized: "Move to Trash", comment: "Header button tooltip, accessibility label and alert button that moves the note to the Trash. Use the system term for Trash"))
        ]
        let controls = NSStackView()
        controls.spacing = HeaderMetrics.buttonSpacing
        controls.alignment = .centerY
        fontSizeControl.orientation = .horizontal
        fontSizeControl.spacing = 0
        fontSizeControl.alignment = .centerY
        fontSizeControl.setAccessibilityLabel(String(localized: "Font size", comment: "Accessibility label for the group of font size buttons"))
        for (index, symbol) in ["textformat.size.smaller", "textformat.size.larger"].enumerated() {
            let label = index == 0 ? String(localized: "Decrease Font Size", comment: "Header button tooltip and accessibility label") : String(localized: "Increase Font Size", comment: "Header button tooltip and accessibility label")
            let shortcut = index == 0 ? "⌘−" : "⌘+"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                .withSymbolConfiguration(.init(pointSize: HeaderMetrics.symbolSize, weight: .medium))!
            let button = HeaderButton(image: image, target: self,
                                      action: index == 0 ? #selector(decreaseFontSize) : #selector(increaseFontSize))
            button.focusRingType = .exterior
            button.bezelStyle = .regularSquare
            button.showsBorderOnlyWhileMouseInside = true
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.contentTintColor = .labelColor
            button.toolTip = String(localized: "\(label) (\(shortcut))", comment: "Tooltip of a header button: the localized action name followed by its keyboard shortcut in parentheses, such as ⌘+")
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: HeaderMetrics.buttonWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: HeaderMetrics.buttonHeight).isActive = true
            fontSizeControl.addArrangedSubview(button)
            fontSizeButtons.append(button)
        }
        backgroundTintButton.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: String(localized: "Background tint", comment: "Header button tooltip and accessibility label for choosing the note's background color"))
        backgroundTintButton.focusRingType = .exterior
        backgroundTintButton.contentTintColor = .labelColor
        backgroundTintButton.toolTip = String(localized: "Background tint", comment: "Header button tooltip and accessibility label for choosing the note's background color")
        backgroundTintButton.setAccessibilityLabel(String(localized: "Background tint", comment: "Header button tooltip and accessibility label for choosing the note's background color"))
        backgroundTintButton.target = self
        backgroundTintButton.action = #selector(showBackgroundTints)
        backgroundTintButton.widthAnchor.constraint(equalToConstant: HeaderMetrics.buttonWidth).isActive = true
        backgroundTintButton.heightAnchor.constraint(equalToConstant: HeaderMetrics.buttonHeight).isActive = true
        backgroundTintMenu.autoenablesItems = false
        let tones: [NoteBackgroundTone?] = [nil] + NoteBackgroundTone.allCases.map { Optional($0) }
        for (index, tone) in tones.enumerated() {
            let item = NSMenuItem(title: NoteBackgroundTone.localizedName(tone), action: #selector(chooseBackgroundTint), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NoteTonePalette.image(tone)
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            backgroundTintMenu.addItem(item)
        }
        controls.addArrangedSubview(backgroundTintButton)
        controls.addArrangedSubview(glassControl(fontSizeControl))
        for (symbol, label, action, tooltip) in actions {
            let button = HeaderButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                .withSymbolConfiguration(.init(pointSize: HeaderMetrics.symbolSize, weight: .medium))!,
                                  target: self, action: action)
            button.focusRingType = .exterior
            button.controlSize = .regular
            button.toolTip = tooltip
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: HeaderMetrics.buttonWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: HeaderMetrics.buttonHeight).isActive = true
            controls.addArrangedSubview(button)
            headerButtons.append(button)
        }
        locationIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: String(localized: "Outside the default folder", comment: "Tooltip and accessibility description of the icon that marks a note stored outside the default notes folder"))
        locationIcon.contentTintColor = .systemBlue
        locationIcon.toolTip = String(localized: "Outside the default folder", comment: "Tooltip and accessibility description of the icon that marks a note stored outside the default notes folder")
        locationIcon.isHidden = true
        locationIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        locationIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        titleContent.orientation = .horizontal
        titleContent.alignment = .centerY
        titleContent.spacing = 4
        titleContent.addArrangedSubview(locationIcon)
        titleContent.addArrangedSubview(titleLabel)
        for view in [titleContent, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.controlsView.addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            titleContent.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 78),
            titleContent.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleContent.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -6),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
    }

    private func glassControl(_ control: NSView) -> NSGlassEffectView {
        let glass = headerGlass(control)
        headerGlassViews.append(glass)
        return glass
    }

    private func updateTitle(_ title: String) {
        window?.title = title
        titleLabel.stringValue = title
        titleLabel.toolTip = title
    }

    private func updateLocationIcon() {
        locationIcon.isHidden = defaultFolder.map {
            NoteLocationPresentation.isDefault(editor.note.fileURL, folder: $0)
        } ?? true
    }

    private func updateDocumentState() {
        updateLocationIcon()
        guard let window else { return }
        window.isDocumentEdited = editor.state.hasUnsavedEdits
        // AppKit resets native button positions during document-state updates,
        // without laying out the custom header again.
        alignNativeHeaderControls(in: header)
    }

    deinit {
        noticeTimer?.cancel()
        for observer in environmentObservers { NotificationCenter.default.removeObserver(observer) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayPreferencesChanged() { applyDisplayPreferences() }

    func applyDisplayPreferences(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        for glass in headerGlassViews { glass.effectIsInteractive = !reduceMotion }
    }

    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideRequested?(); return false }
    func windowDidResignKey(_ notification: Notification) { focusLost?() }
    func windowDidBecomeKey(_ notification: Notification) { focused?() }
    func windowDidMove(_ notification: Notification) { geometryChanged?() }
    func windowDidResize(_ notification: Notification) {
        updateErrorScrollHeight()
        geometryChanged?()
    }

    func applyInterfaceScale(_ scale: Double) {
        let normalizedScale = min(2, max(1, scale.isFinite ? scale : 1))
        guard normalizedScale != interfaceScale else { return }
        interfaceScale = normalizedScale
        InterfaceTypography.apply(to: errorBlock, scale: normalizedScale)
        externalChangeFooter.font = .systemFont(ofSize: NSFont.smallSystemFontSize * normalizedScale)
        updateErrorScrollHeight()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func updateErrorScrollHeight() {
        errorBlock.actionsChanged()
        guard !errorBlock.isHidden, let window else {
            errorScrollHeight?.isActive = false
            return
        }
        errorScrollHeight?.isActive = true
        let availableHeight = window.contentView?.bounds.height ?? 180
        let fittedHeight = max(80, errorBlock.fittingSize.height)
        let maximumHeight = interfaceScale > 1.25 ? max(80, availableHeight - 130) : fittedHeight
        errorScrollHeight?.constant = min(fittedHeight, maximumHeight)
    }
    let announcements = AccessibilityAnnouncements()
    private var lastTyping: Date?
    @objc private func textTyped() { lastTyping = Date() }

    /// True while the window shows a save failure or recovery warning from `display`.
    private var showsSaveProblem = false

    func display(_ state: StorageSaveStatus) {
        // Each edit queues a save, which reports `.pending`. A shown problem stays until
        // the save resolves, so typing does not collapse and re-expand the warning.
        if case .pending = state, showsSaveProblem { return }
        showsSaveProblem = false
        errorBlock.hideAll()
        updateActionAvailability()
        if case let .failed(_, .accessFailure(failure), _) = state {
            updateAccessActions(for: failure)
        }
        switch state {
        case .saved:
            status.stringValue = ""
            announcements.update(nil, for: "save")
            announcements.update(nil, for: "blocker")
        case .pending:
            status.stringValue = ""
        case let .failed(_, error, journaled):
            // Text that failed to save can always be written to a separate file.
            errorBlock.setAction(.saveCopy, visible: true)
            errorBlock.isHidden = false
            status.isHidden = false
            let reason = error.localizedDescription.trimmingCharacters(in: .punctuationCharacters)
            if !editor.state.hasUnsavedEdits {
                // Nothing is waiting to be written, so no save failed and no recovery copy exists.
                status.stringValue = String(localized: "This note is unavailable: \(reason). All your edits were saved before this happened.", comment: "Shown in a note window when its storage becomes unavailable and no edit is waiting to be saved. The value is the system error")
            } else {
                status.stringValue = journaled
                ? String(localized: "Save failed: \(reason). A recovery copy is preserved.", comment: "Shown in a note window when saving fails but a recovery journal exists. The value is the system error")
                : String(localized: "Save failed: \(reason). Keep this window open. Saving retries automatically. Export your text to keep a copy.", comment: "Shown in a note window when saving fails and no recovery journal exists. The value is the system error")
            }
            errorBlock.actionsVisible = true
        case .recoverable:
            // The text is preserved separately, so a normal close works.
            errorBlock.setAction(.closeWithoutSaving, visible: false)
            errorBlock.isHidden = false
            status.isHidden = false
            status.stringValue = String(localized: "Your text is preserved separately. Open the recovery copy before continuing.", comment: "Shown in a note window when its text was retained in a recovery journal")
            errorBlock.actionsVisible = true
            errorBlock.dismissVisible = true
        }
        showsSaveProblem = !errorBlock.isHidden
        if !status.isHidden { announcements.update(status.stringValue, for: "save", priority: .high) }
        errorScrollView.isHidden = errorBlock.isHidden
        updateErrorScrollHeight()
        window?.recalculateKeyViewLoop()
    }
    /// A reopened window keeps the notice for Open Recovery but does not show the warning again.
    func setRecoveryNotice(_ notice: RecoveryNotice?, showsWarning: Bool = true) {
        guard let notice else {
            guard recoveryNotice != nil else { return }
            recoveryNotice = nil
            updateActionAvailability()
            hideRecoveryBanner()
            return
        }
        recoveryNotice = notice
        updateActionAvailability()
        guard showsWarning else { return }
        errorBlock.isHidden = false
        status.isHidden = false
        recoveryNotice = notice
        status.stringValue = notice.originalMissing ? String(localized: "The original is missing. Your local text is preserved in a recovery note.", comment: "Shown in a note window when the original file disappeared") : String(localized: "The original changed externally. Your local text is preserved in a recovery note.", comment: "Shown in a note window when the original file changed on disk")
        errorBlock.actionsVisible = true
        errorBlock.dismissVisible = true
        updateActionAvailability()
        announcements.update(String(localized: "\(status.stringValue) Use Open Recovery.", comment: "VoiceOver announcement. The first value is the visible warning. Open Recovery must match the translated button title"), for: "recovery")
        errorScrollView.isHidden = false
        updateErrorScrollHeight()
        window?.recalculateKeyViewLoop()
    }
    private func updateActionAvailability() {
        if let failure = editor.note.accessFailure { updateAccessActions(for: failure) }
        else {
            errorBlock.setAction(.restoreAccess, visible: false)
            errorBlock.setAction(.locate, visible: false)
            errorBlock.setAction(.saveCopy, visible: false)
        }
        // Always offered while the window holds unsaved text, so the user is never stuck.
        errorBlock.setAction(.closeWithoutSaving, visible: editor.state.hasUnsavedEdits)
        errorBlock.setAction(.openOriginal, visible: recoveryNotice?.originalMissing == false)
        errorBlock.setAction(.openRecovery, visible: recoveryNotice != nil)
        errorBlock.actionsChanged()
    }
    private func updateAccessActions(for failure: NoteAccessFailure) {
        errorBlock.setAction(.restoreAccess, visible: [NoteAccessFailureReason.folderAuthorization, .staleBookmark].contains(failure.reason))
        errorBlock.setAction(.locate, visible: failure.reason == .missingFile)
        errorBlock.setAction(.saveCopy, visible: true)
        errorBlock.actionsChanged()
    }
    enum BlockedOperation { case close, export, trash }
    func showBlocker(_ error: Error, operation: BlockedOperation = .close) {
        errorBlock.isHidden = false
        status.isHidden = false
        let reason = error.localizedDescription.trimmingCharacters(in: .punctuationCharacters)
        switch operation {
        case .close: status.stringValue = String(localized: "Cannot close: \(reason). Your text remains here. Try again, or export it.", comment: "Shown in a note window when closing fails. The value is the system error")
        case .trash: status.stringValue = String(localized: "Cannot move to Trash: \(reason). Your text remains here. Try again, or export it.", comment: "Shown in a note window when moving the note to the Trash fails. The value is the system error")
        case .export: status.stringValue = String(localized: "Cannot export: \(reason). Your text remains here. Try again, or export it.", comment: "Shown in a note window when exporting fails. The value is the system error")
        }
        errorBlock.actionsVisible = true
        updateActionAvailability()
        // The blocked text has not been saved, so it can always go to a separate file.
        if editor.state.hasUnsavedEdits { errorBlock.setAction(.saveCopy, visible: true) }
        announcements.update(status.stringValue, for: "blocker", priority: .high)
        errorScrollView.isHidden = false
        updateErrorScrollHeight()
        window?.recalculateKeyViewLoop()
    }
    @objc private func decreaseFontSize() { editor.adjustFontSize(by: -1) }
    @objc private func increaseFontSize() { editor.adjustFontSize(by: 1) }
    @objc private func deleteNote() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.window.identifier = NSUserInterfaceItemIdentifier("TrashConfirmation")
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Move this note to Trash?", comment: "Confirmation title before moving one note to the Trash. Use the system term for Trash")
        alert.informativeText = String(localized: "The original file will be moved to Trash. You can restore it in Finder.", comment: "Confirmation text before moving one note to the Trash. Use the system terms for Trash and Finder")
        alert.accessoryView = Self.trashTitlePreview(editor.note.fileURL.lastPathComponent)
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button that dismisses a dialog without acting"))
        let trashButton = alert.addButton(withTitle: String(localized: "Move to Trash", comment: "Header button tooltip, accessibility label and alert button that moves the note to the Trash. Use the system term for Trash"))
        trashButton.hasDestructiveAction = true
        trashConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.trashConfirmation = nil
            guard response == .alertSecondButtonReturn else { return }
            self?.deleteRequested?()
        }
    }
    static func trashTitlePreview(_ title: String) -> NSView {
        // NSAlert sizes accessory views from their frames. A width constraint on the label
        // alone still lets long text stretch the alert.
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font)) * 2
        let preview = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: height))
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = font
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        let leadingPadding: CGFloat = 4
        label.preferredMaxLayoutWidth = preview.bounds.width - leadingPadding
        label.toolTip = title
        label.setAccessibilityLabel(String(localized: "Note to move to Trash", comment: "Accessibility label for the filename shown in the Trash confirmation"))
        label.frame = NSRect(x: leadingPadding, y: 0,
                             width: preview.bounds.width - leadingPadding, height: preview.bounds.height)
        label.autoresizingMask = [.width, .height]
        preview.addSubview(label)
        return preview
    }

    @objc private func newNote() { newRequested?() }
    @objc private func list() { listRequested?() }
    /// Returns focus to the recovery button with this stable key, if it is still shown.
    func restoreRecoveryActionFocus(to key: String) {
        guard let window, let control = recoveryActionButtons[key], !control.isHidden, control.acceptsFirstResponder else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(control)
    }
    private func performRecoveryAction(_ action: RecoveryBannerAction) {
        switch action {
        case .export: exportText()
        case .restoreAccess: allowFolderAccess()
        case .locate: location()
        case .saveCopy: saveCopy()
        case .openOriginal: originalRequested?()
        case .openRecovery: recoveryRequested?()
        case .closeWithoutSaving: closeWithoutSaving()
        }
    }
    private func allowFolderAccess() { allowFolderAccessRequested?(); restoreRecoveryActionFocus(to: "Restore File Access…") }
    private func location() {
        locationRequested? { [weak self] in self?.restoreRecoveryActionFocus(to: "Locate File…") }
    }
    private func exportText() { exportRequested?() }
    private func saveCopy() { saveCopyRequested?(); restoreRecoveryActionFocus(to: "Save a Copy…") }
    private func closeWithoutSaving() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Close without saving?", comment: "Title of the confirmation before closing a note whose text could not be saved")
        alert.informativeText = String(localized: "The text that could not be saved will be lost. The file keeps its last saved text. To keep your text, use Export or Save a Copy instead.", comment: "Message of the confirmation before closing a note whose text could not be saved")
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button that keeps the note open"))
        let discard = alert.addButton(withTitle: String(localized: "Close Without Saving", comment: "Button that confirms closing a note and losing its unsaved text"))
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn { self.closeWithoutSavingRequested?() }
            else { self.restoreRecoveryActionFocus(to: "Close Without Saving…") }
        }
    }
    /// Hides the recovery banner without moving focus.
    private func hideRecoveryBanner() {
        showsSaveProblem = false
        errorBlock.hideAll()
        errorScrollView.isHidden = true
        announcements.update(nil, for: "save")
        announcements.update(nil, for: "recovery")
        updateErrorScrollHeight()
        window?.recalculateKeyViewLoop()
    }
    @objc func dismissRecoveryWarning() {
        showsSaveProblem = false
        errorBlock.hideAll()
        errorScrollView.isHidden = true
        announcements.update(nil, for: "save")
        announcements.update(nil, for: "recovery")
        updateErrorScrollHeight()
        window?.recalculateKeyViewLoop()
        window?.makeFirstResponder(editor.textView)
    }
}
