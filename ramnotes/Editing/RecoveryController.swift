import ramnotesDomain
import AppKit

/// What recovery needs from the app. Recovery reads it at each step, so it sees a folder
/// switch or reload that happens mid-action.
@MainActor
protocol RecoveryHost: AnyObject {
    var recoveryNotes: (any RecoveryNotes)? { get }
    var windows: WindowCoordinator? { get }
    var folder: FolderSelection? { get }
    var metadataStore: MetadataStore? { get }
    var metadataDelivery: MetadataPersistence? { get }
    var folderState: FolderState { get }
    /// Quitting or a folder transaction is in progress.
    var recoveryBlocked: Bool { get }
    func showMessage(_ text: String)
    func refreshList()
    func showList()
    func revealNote(_ id: NoteID)
    func persistMetadata()
}

extension RecoveryHost {
    func revealNote(_ id: NoteID) { showList() }
}

/// Owns recovery links, kept windows, and deletion presentation.
@MainActor
final class RecoveryController {
    private let loadTone: ((RetainedEditSummary) async -> NoteBackgroundTone?)?
    private var settings = AppSettings()
    var allowFolderAccess: ((NoteSnapshot) -> Void)?
    var saveCopy: ((NoteSnapshot, NoteEditorController?) -> Void)?
    var showLocation: ((NoteSnapshot, @escaping () -> Void) -> Void)?
    weak var host: RecoveryHost?
    private var store: (any RecoveryNotes)? { host?.recoveryNotes }
    private var windows: WindowCoordinator? { host?.windows }
    private var folder: FolderSelection? { host?.folder }
    private var metadataStore: MetadataStore? { host?.metadataStore }
    private var metadataDelivery: MetadataPersistence? { host?.metadataDelivery }
    private var notes: [NoteID: NoteSnapshot] { host?.folderState.notes ?? [:] }
    /// A projection of `NoteStore.recoveryNotices()`. Refresh it with `project(_:)`; never
    /// add a notice the store does not hold.
    var recoveryNotices: [URL: RecoveryNotice] = [:]
    let announcements = AccessibilityAnnouncements()
    var retainedEdits: [RetainedEditSummary] = [] {
        didSet {
            for record in oldValue where !retainedEdits.contains(where: { $0.id == record.id }) {
                announcements.update(nil, for: record.id.uuidString)
            }
            for record in retainedEdits {
                announcements.update(String(localized: "Recovery text is available for \(PathIsolation.isolate(record.originalURL.lastPathComponent)). Use Open Preserved Text on its note.", comment: "VoiceOver announcement. The value is a file name. Open Preserved Text must match the translated context menu item"),
                                     for: record.id.uuidString)
            }
            if oldValue != retainedEdits { refreshList() }
        }
    }
    private let deletion = DeletionWorkflow()
    private(set) var recoveryWindows: [UUID: RecoveryWindowController] = [:]
    private var openingRecords: Set<UUID> = []

    private let exporter: (any RecoveryTextExporting)?

    init(host: RecoveryHost? = nil,
         loadTone: ((RetainedEditSummary) async -> NoteBackgroundTone?)? = nil,
         exporter: (any RecoveryTextExporting)? = nil) {
        self.loadTone = loadTone
        self.exporter = exporter
        self.host = host
    }
    func apply(_ settings: AppSettings) {
        self.settings = EditorTypography.normalized(settings)
        for controller in recoveryWindows.values { controller.apply(self.settings) }
    }
    private var blocked: Bool { host?.recoveryBlocked ?? true }
    private func message(_ text: String) { host?.showMessage(text) }
    private func refreshList() { host?.refreshList() }
    private func persistMetadata() { host?.persistMetadata() }
    private func showList(_ sender: Any?) { host?.showList() }
    private struct RecoveryPresentation: Equatable {
        let blocked: Bool
        let notices: [RecoveryNotice]
        let records: [RetainedEditSummary]
    }
    private var recoveryPresentation: RecoveryPresentation?
    private(set) var rebuildCount = 0
    func render(in stack: NSStackView, height: NSLayoutConstraint?) {
        let presentation = RecoveryPresentation(
            blocked: blocked,
            notices: recoveryNotices.values
                .sorted { $0.recoveryURL.path < $1.recoveryURL.path },
            records: retainedEdits)
        guard presentation != recoveryPresentation else { return }
        recoveryPresentation = presentation
        rebuildCount += 1
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        // Show a notice here only when neither related note has a card.
        var seen: Set<String> = []
        for notice in presentation.notices where cardNoteID(of: notice) == nil {
            guard seen.insert(notice.originalURL.path).inserted else { continue }
            let name = PathIsolation.isolate(notice.originalURL.lastPathComponent)
            let text = notice.originalMissing
                ? String(localized: "Original missing. Local text preserved: \(name)", comment: "Note list footer about a recovery note. The value is the original file name")
                : String(localized: "External change. Local text preserved: \(name)", comment: "Note list footer about a recovery note. The value is the original file name")
            stack.addArrangedSubview(FooterMessage(text, toolTip: notice.originalURL.path) { [weak self] in
                self?.reveal(notice)
            })
        }
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.enclosingScrollView?.isHidden = stack.arrangedSubviews.isEmpty
        Self.fitFooterHeight(stack, height: height)
    }
    /// Sizes the footer scroll view to its wrapped messages at the current width, up to 140 pt.
    static func fitFooterHeight(_ stack: NSStackView, height: NSLayoutConstraint?) {
        guard let height else { return }
        stack.layoutSubtreeIfNeeded()
        height.constant = min(140, stack.fittingSize.height)
    }
    /// Bumped by every projection, so a caller that read the store before an `await` can tell
    /// that a newer projection already ran.
    private(set) var projectionGeneration = 0
    /// Replaces the in-memory notices with the store's list, so the UI shows only what the
    /// store owns. Announces notices that are new to this projection, clears the banner and
    /// tint of dropped ones, then persists window state and refreshes the list once.
    func project(_ storeNotices: [RecoveryNotice]) {
        projectionGeneration += 1
        let incoming = Dictionary(storeNotices.map { ($0.recoveryURL, $0) }, uniquingKeysWith: { _, last in last })
        var changed = false
        for (url, notice) in recoveryNotices where incoming[url] == nil {
            discard(notice)
            changed = true
        }
        for notice in incoming.values where recoveryNotices[notice.recoveryURL] != notice {
            present(notice)
            changed = true
        }
        let stale = recoveryNotices.values.filter(isStale)
        for notice in stale { discard(notice) }
        forgetInStore(stale)
        if changed || !stale.isEmpty { persistMetadata() }
        refreshList()
    }
    private func shows(_ notice: RecoveryNotice, in controller: NoteWindowController) -> Bool {
        notice.sourceNoteID.map { controller.editor.note.id == $0 } ?? (controller.editor.note.fileURL == notice.originalURL)
    }
    /// Pure update plus window presentation. The caller persists and refreshes.
    private func present(_ notice: RecoveryNotice) {
        recoveryNotices[notice.recoveryURL] = notice
        windows?.inheritRecoveryTone(notice)
        let shown = windows?.windows.values.filter { shows(notice, in: $0) } ?? []
        for controller in shown { controller.setRecoveryNotice(notice) }
        if shown.isEmpty {
            announcements.update(String(localized: "Recovery text is available for \(PathIsolation.isolate(notice.originalURL.lastPathComponent)). Open its recovery note from the note list.", comment: "VoiceOver announcement. The value is a file name"),
                                 for: notice.recoveryURL.path)
        }
    }
    /// Removes a notice and what presenting it set up. The caller persists and refreshes.
    private func discard(_ notice: RecoveryNotice) {
        recoveryNotices[notice.recoveryURL] = nil
        announcements.update(nil, for: notice.recoveryURL.path)
        windows?.releaseRecoveryTone(notice)
        for controller in windows?.windows.values ?? Dictionary<NoteID, NoteWindowController>().values
        where controller.recoveryNotice?.recoveryURL == notice.recoveryURL {
            controller.setRecoveryNotice(nil)
        }
    }
    private func forgetInStore(_ removed: [RecoveryNotice]) {
        guard !removed.isEmpty else { return }
        let urls = Set(removed.map(\.recoveryURL))
        Task { [store] in try? await store?.forgetRecoveryNotices(urls) }
    }

    func configureRecovery(_ controller: NoteWindowController) {
        controller.editor.contentChanged = { [weak self] note in
            guard note.collectionToken == self?.folder?.collectionToken else { return }
            self?.host?.folderState.apply(.changed(note))
            self?.refreshList()
        }
        if let store {
            Task { [weak controller] in
                guard let controller else { return }
                if let status = await store.status(controller.editor.note.id) {
                    controller.editor.receive(status)
                    // The warning already appeared in an earlier window for this note.
                    if case .recoverable = status { controller.dismissRecoveryWarning() }
                }
                else if controller.editor.note.availability != .available { controller.display(.failed(controller.editor.state.currentRevision, .unavailable, journaled: false)) }
            }
        }
        controller.allowFolderAccessRequested = { [weak self, weak controller] in
            guard let note = controller?.editor.note else { return }
            self?.allowFolderAccess?(note)
        }
        controller.saveCopyRequested = { [weak self, weak controller] in
            guard let controller else { return }
            self?.saveCopy?(controller.editor.note, controller.editor)
        }
        controller.closeWithoutSavingRequested = { [weak self, weak controller] in
            guard let id = controller?.editor.note.id else { return }
            self?.windows?.closeWithoutSaving(id)
        }
        controller.locationRequested = { [weak self, weak controller] onDismiss in
            guard let note = controller?.editor.note else { return }
            self?.showLocation?(note, onDismiss)
        }
        controller.exportRequested = { [weak controller] in
            guard let controller, let window = controller.window else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = String(localized: "Recovered note", comment: "Suggested filename for an exported recovered note, without extension") + ".txt"
            panel.beginSheetModal(for: window) { response in
                Task { @MainActor in controller.restoreRecoveryActionFocus(to: "Export") }
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    do {
                        try await controller.editor.export(to: url)
                        controller.status.stringValue = String(localized: "Text exported safely to \(PathIsolation.isolate(url.lastPathComponent)).", comment: "Status in a note window after exporting text. The value is a file name")
                        controller.announcements.update(nil, for: "blocker")
                    }
                    catch { controller.showBlocker(error, operation: .export) }
                }
            }
        }
        controller.originalRequested = { [weak self, weak controller] in
            guard let notice = controller?.recoveryNotice else { return }
            self?.openOriginal(notice)
        }
        controller.recoveryRequested = { [weak self, weak controller] in
            guard let notice = controller?.recoveryNotice else { return }
            self?.openRecovery(notice)
        }
        if let notice = recoveryNotices.values.first(where: { notice in
            notice.sourceNoteID.map { $0 == controller.editor.note.id } ?? (notice.originalURL == controller.editor.note.fileURL)
        }) { controller.setRecoveryNotice(notice, showsWarning: false) }
    }
    private func reveal(_ notice: RecoveryNotice) {
        host?.revealNote(sourceID(of: notice) ?? notice.recoveryNoteID)
    }
    /// The listed note whose card shows this notice: the source note, else the recovery note.
    private func cardNoteID(of notice: RecoveryNotice) -> NoteID? {
        if let id = sourceID(of: notice), notes[id] != nil { return id }
        return notes[notice.recoveryNoteID] != nil ? notice.recoveryNoteID : nil
    }
    /// Show a card warning while retained text needs attention.
    func cardIssue(for id: NoteID) -> String? {
        if retainedEdit(for: id) != nil {
            return String(localized: "Original unavailable. Local text preserved.", comment: "Line below a note card title about retained text")
        }
        return nil
    }
    /// Retained text for a note whose original is unavailable, if any.
    func retainedEdit(for id: NoteID) -> RetainedEditSummary? { retainedEdits.first { $0.noteID == id } }
    private func openOriginal(_ notice: RecoveryNotice) {
        let note: NoteSnapshot?
        if let id = notice.sourceNoteID { note = notes[id] }
        else { note = notes.values.first(where: { $0.fileURL == notice.originalURL }) }
        if let note { windows?.open(note) }
        else { message(String(localized: "The original is unavailable. Open its preserved text. RAMnotes reconnects when the folder returns.", comment: "Note list message. Keep the product name RAMnotes unchanged.")); showList(nil) }
    }
    private func openRecovery(_ notice: RecoveryNotice) {
        guard let store, let folder else {
            message(String(localized: "Open the collection to read this recovery note. Preserved journals are available below.", comment: "Note list message when a recovery note cannot be opened before the collection loads"))
            return
        }
        Task {
            do { let note = try await store.read(notice.recoveryNoteID, collectionToken: folder.collectionToken)
                guard folder.collectionToken == self.folder?.collectionToken else { return }; host?.folderState.apply(.changed(note)); windows?.open(note) }
            catch {
                guard folder.collectionToken == self.folder?.collectionToken else { return }
                message(String(localized: "Cannot open recovery note: \(error.localizedDescription)", comment: "Note list message. The value is the system error"))
            }
        }
    }
    func openRetained(_ record: RetainedEditSummary) {
        guard openingRecords.insert(record.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.openingRecords.remove(record.id) }
            var tone: NoteBackgroundTone?
            var fontSize: Double?
            if let metadataStore {
                let local = await metadataStore.loadCollection()
                tone = local.value.notes[record.noteID]?.backgroundTone
                fontSize = local.value.notes[record.noteID]?.fontSize
            }
            if let loadTone { tone = await loadTone(record) }
            let controller = recoveryWindows[record.id] ?? RecoveryWindowController(record: record, backgroundTone: tone,
                settings: settings, fontSize: fontSize, exporter: exporter)
            recoveryWindows[record.id] = controller
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func deletionEditor(_ id: NoteID) -> DeletionEditor? {
        let controller = windows?.windows[id]
        let lock = controller?.editor.beginEditingLock()
        guard let controller, let lock else { return nil }
        return DeletionEditor(flush: { try await controller.editor.flushForDeletion() },
                              release: { controller.editor.endEditingLock(lock) })
    }
    private func presentDeletion(_ id: NoteID) {
        windows?.remove(id)
        if let token = notes[id]?.collectionToken { host?.folderState.apply(.removed(id, token)) }
        // Trashing either side of a notice resolves it.
        removeNotices { $0.recoveryNoteID == id || self.sourceID(of: $0) == id }
    }
    /// Drops notices whose original and recovery note are both gone from the collection.
    func pruneNotices() {
        removeNotices(where: isStale)
    }
    private func isStale(_ notice: RecoveryNotice) -> Bool {
        notes[notice.recoveryNoteID] == nil && sourceID(of: notice).flatMap { notes[$0] } == nil
    }
    private func sourceID(of notice: RecoveryNotice) -> NoteID? {
        notice.sourceNoteID ?? notes.values.first(where: { $0.fileURL == notice.originalURL })?.id
    }
    private func removeNotices(where stale: (RecoveryNotice) -> Bool) {
        let removed = recoveryNotices.values.filter(stale)
        guard !removed.isEmpty else { return }
        for notice in removed { discard(notice) }
        persistMetadata()
        refreshList()
        forgetInStore(removed)
    }
    func deleteNote(_ id: NoteID) {
        guard !blocked, let store, let folder, let note = windows?.windows[id]?.editor.note else { return }
        Task {
            let result = await deletion.delete([note], in: folder.collectionToken, using: store,
                isCurrent: { self.folder?.collectionToken == folder.collectionToken }, canProceed: { !self.blocked },
                editor: { self.deletionEditor($0) },
                didDelete: { self.presentDeletion($0) })
            if result.succeeded > 0 {
                let summary = String(localized: "Moved \(1) notes to Trash.", comment: "Status after moving notes to the Trash; value is the number moved")
                refreshList()
                host?.revealNote(id)
                message(summary)
                announcements.update(summary, for: "single-trash")
            }
            if let failure = result.failures.first { windows?.windows[id]?.showBlocker(failure.1, operation: .trash) }
        }
    }
    func deleteNotes(_ selected: [NoteSnapshot]) {
        guard !blocked, let store, let folder else { return }
        Task {
            let result = await deletion.delete(selected, in: folder.collectionToken, using: store,
                isCurrent: { self.folder?.collectionToken == folder.collectionToken }, canProceed: { !self.blocked },
                editor: { self.deletionEditor($0) },
                didDelete: { self.presentDeletion($0) })
            refreshList()
            let failures = result.failures.map { failure in
                let name = PathIsolation.isolate(failure.0.fileURL.lastPathComponent), reason = failure.1.localizedDescription
                return String(localized: "\(name): \(reason)", comment: "One Trash failure: file name, then the reason")
            }
            let moved = result.succeeded
            let summary = String(localized: "Moved \(moved) notes to Trash.", comment: "Status after moving notes to the Trash; value is the number moved")
            if failures.isEmpty {
                message(summary)
                announcements.update(summary, for: "batch-trash")
            } else {
                let list = failures.joined(separator: "; "), failed = failures.count
                message(String(localized: "Moved \(moved) notes to Trash. Could not move: \(list)", comment: "Status after a partial Trash; first value is the number moved, second lists failed files with reasons"))
                announcements.update(String(localized: "Moved \(moved) notes to Trash. \(failed) files could not be moved. See the note list for details.", comment: "VoiceOver announcement after a partial Trash; first count is moved, second is failed"), for: "batch-trash")
            }
        }
    }
}

/// A footer status line that selects its note when clicked.
final class FooterMessage: NSTextField {
    private let onPress: () -> Void
    init(_ text: String, toolTip: String, action: @escaping () -> Void) {
        onPress = action
        super.init(frame: .zero)
        stringValue = text
        self.toolTip = toolTip
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        // Wrap long filenames within the window width.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        setAccessibilityHelp(String(localized: "Shows this note in the list.", comment: "Accessibility help of a recovery message in the note list footer"))
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(press)))
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { press(); return true }
    @objc func press() { onPress() }
}
