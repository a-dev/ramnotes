import ramnotesDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Commands the note list sends to the app.
@MainActor
protocol NoteListDelegate: AnyObject {
    func newNote()
    func trash(_ note: NoteSnapshot)
    func trashBatch(_ notes: [NoteSnapshot])
    func dragText(_ note: NoteSnapshot) throws -> String?
    func exportDrag(_ note: NoteSnapshot, text: String?, to url: URL) async throws
    func addExistingFiles()
    func moveTo(_ note: NoteSnapshot)
    func saveCopy(_ note: NoteSnapshot)
    func hasPreservedText(_ id: NoteID) -> Bool
    /// A problem that belongs to one note. The card shows it on the line below the title.
    func noteIssue(_ id: NoteID) -> String?
    func openPreservedText(_ note: NoteSnapshot)
    func showInFinder(_ note: NoteSnapshot)
    func actionsAllowed() -> Bool
    func restoreFileAccess(_ note: NoteSnapshot)
    func open(_ note: NoteSnapshot)
    func openBatch(_ notes: [NoteSnapshot])
    func backgroundTone(_ id: NoteID) -> NoteBackgroundTone?
    func isOpen(_ id: NoteID) -> Bool
    func locate(_ note: NoteSnapshot)
    func removeUnavailable(_ note: NoteSnapshot)
    func removeUnavailableBatch(_ notes: [NoteSnapshot])
    func location(_ note: NoteSnapshot)
    func registerFiles(_ urls: [URL])
}

@MainActor
final class NoteListController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSStackView()
    let search: NSSearchField = NoteSearchField()
    let table: NSTableView = NoteListTableView()
    let sortPicker = NSPopUpButton()
    private var sort: NoteSort = .updated
    private var ascending = false
    weak var delegate: NoteListDelegate?
    func actionsAllowed() -> Bool { delegate?.actionsAllowed() ?? true }
    private func isOpen(_ id: NoteID) -> Bool { delegate?.isOpen(id) ?? false }
    private func backgroundTone(_ id: NoteID) -> NoteBackgroundTone? { delegate?.backgroundTone(id) }
    private func hasPreservedText(_ id: NoteID) -> Bool { delegate?.hasPreservedText(id) ?? false }
    private func noteIssue(_ id: NoteID) -> String? { delegate?.noteIssue(id) }
    var canTrashSelection: Bool { actionsAllowed() && !selectedNotes.isEmpty && selectedNotes.allSatisfy { availability(of: $0) == .available } }
    func trashSelection() {
        guard canTrashSelection else { return }
        let selected = selectedNotes
        if selected.count == 1 { delegate?.trash(selected[0]) } else { delegate?.trashBatch(selected) }
    }
    var selectedNotes: [NoteSnapshot] { table.selectedRowIndexes.compactMap { results.indices.contains($0) ? results[$0].note : nil } }
    private let count = NSTextField(labelWithString: "")
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    let status = NSTextField(wrappingLabelWithString: String(localized: "Indexing…", comment: "Note list status while notes are being indexed"))
    /// A confirmed missing original needs Locate File, even when its bookmark also failed.
    func needsAccessRepair(_ note: NoteSnapshot) -> Bool {
        availability(of: note) != .missingOriginal && note.accessFailure?.requiresFolderAccess == true
    }
    let emptyMessage = NSTextField(wrappingLabelWithString: String(localized: "Drop .txt files here, or add existing files.", comment: "Empty note list message. Keep .txt unchanged"))
    // Hide the whole row, not only its children: an empty arranged row still adds stack spacing.
    private let emptyActions = NSStackView()
    private var headerRowWidths: [NSLayoutConstraint] = []
    private func setHeaderRow(_ row: NSView, hidden: Bool) {
        guard row.isHidden != hidden else { return }
        row.isHidden = hidden
        // The header stack detaches hidden rows, which deactivates their width constraints.
        if !hidden { NSLayoutConstraint.activate(headerRowWidths) }
    }
    let emptyAddButton = FileRegistrationButton(String(localized: "Add Existing Files…", comment: "Button that adds existing text files from disk to the note collection")) {}
    private(set) var results: [NoteListResult] = []
    private var showingSearchResults = false
    private let index = SearchIndex()
    private var task: Task<Void, Never>?
    private var request = UUID()
    private var pendingSelection: NoteID?
    /// The selection when `pendingSelection` was requested. A different selection means the user chose a row.
    private var pendingSelectionBase: Set<NoteID> = []
    private var pendingRegisteredSelection: Set<NoteID>?
    private var interfaceScale: CGFloat = 1
    private var createButton: ActionButton!
    private var searchHeightConstraint: NSLayoutConstraint!
    private var createHeightConstraint: NSLayoutConstraint!
    private var createWidthConstraint: NSLayoutConstraint!
    private var notes: [NoteSnapshot] = []
    private var captures: [NoteID: NoteListEditCapture] = [:]
    // Live editor text stays searchable even when its file is unavailable.
    private var sourceAvailability: [NoteID: NoteAvailability] = [:]
    private func availability(of note: NoteSnapshot) -> NoteAvailability { sourceAvailability[note.id] ?? note.availability }
    /// The current availability of each listed note.
    var noteAvailability: [NoteID: NoteAvailability] {
        Dictionary(uniqueKeysWithValues: notes.map { ($0.id, availability(of: $0)) })
    }
    /// Runs after the listed notes or their availability change, so the footer can follow them.
    var notesChanged: () -> Void = {}
    var indexing = false {
        didSet { if indexing != oldValue { runQuery() } }
    }
    var isPresented: () -> Bool = { true }
    private(set) var queryCount = 0
    private(set) var lastAppliedQueryGeneration = 0
    private var needsQuery = true
    private var deferredUpdate: (notes: [NoteSnapshot], availability: [NoteID: NoteAvailability], captures: [NoteID: NoteListEditCapture])?

    func apply(_ settings: AppSettings) {
        let scale = CGFloat(min(2, max(1, 1.0)))
        guard scale != interfaceScale else { return }
        let selectedIDs = Set(selectedNotes.map(\.id))
        let clipView = table.enclosingScrollView?.contentView
        let scrollOrigin = clipView?.bounds.origin
        interfaceScale = scale
        InterfaceTypography.apply(to: view, scale: scale)
        updateControlMetrics()
        table.rowHeight = Self.rowHeight(scale: scale)
        table.reloadData()
        for row in results.indices {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCell)?.applyScale(scale)
        }
        table.selectRowIndexes(IndexSet(results.indices.filter { selectedIDs.contains(results[$0].note.id) }), byExtendingSelection: false)
        if let scrollOrigin, let clipView {
            clipView.scroll(to: scrollOrigin)
            table.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    private static func rowHeight(scale: CGFloat) -> CGFloat {
        let preview = NoteListCell.titleBlockHeight(scale: scale)
        let metadata = NSFont.systemFont(ofSize: 11 * scale).boundingRectForFont.height + 4
        return preview + metadata + 4 + 16 + 12
    }

    private func updateControlMetrics() {
        let searchFont = search.font ?? NSFont.systemFont(ofSize: 13 * interfaceScale)
        let createFont = createButton.font ?? NSFont.systemFont(ofSize: 13 * interfaceScale)
        let controlHeight = ceil(max(searchFont.boundingRectForFont.height, createFont.boundingRectForFont.height)) + 16
        searchHeightConstraint.constant = controlHeight
        createHeightConstraint.constant = controlHeight
        let titleWidth = (String(localized: "New Note", comment: "Note list button that creates a note") as NSString).size(withAttributes: [.font: createFont]).width
        let imageWidth = CGFloat(14) * interfaceScale
        createWidthConstraint.constant = max(116, ceil(titleWidth + imageWidth + 34))
    }

    private func updateKeyViewLoop(empty: Bool) {
        search.nextKeyView = createButton
        createButton.nextKeyView = sortPicker
        sortPicker.nextKeyView = empty ? emptyAddButton : table
        emptyAddButton.nextKeyView = table
        table.nextKeyView = search
    }

    @objc private func displaySettingsChanged() {
        search.needsDisplay = true
        table.reloadData()
        table.needsDisplay = true
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    func refreshTones() {
        guard isPresented() else { return }
        for row in results.indices {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteListCell else { continue }
            cell.apply(opened: isOpen(results[row].note.id), tone: backgroundTone(results[row].note.id))
        }
    }
    var defaultFolder: URL? { didSet { if oldValue != defaultFolder { table.reloadData() } } }
    func returnFocus(to id: NoteID) {
        table.window?.makeKeyAndOrderFront(nil)
        table.window?.makeFirstResponder(table)
        guard let row = results.firstIndex(where: { $0.note.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }


    /// Selects registered files that are visible under the current search. Hidden additions
    /// remain registered and are reported without changing the search string.
    func selectRegisteredFiles(ids: [NoteID]) {
        pendingRegisteredSelection = Set(ids)
        runQuery()
    }

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaySettingsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        view.orientation = .vertical
        view.spacing = 16
        view.alignment = .leading
        sortPicker.pullsDown = true
        sortPicker.addItems(withTitles: ["", String(localized: "Recently updated", comment: "Sort menu choice: newest modification date first"), String(localized: "Oldest updated first", comment: "Sort menu choice: oldest modification date first"), String(localized: "Recently created", comment: "Sort menu choice: newest creation date first"), String(localized: "Oldest created first", comment: "Sort menu choice: oldest creation date first"), String(localized: "A–Z", comment: "Sort menu choice: alphabetical order, ascending. Keep the en dash between the first and last letter of the alphabet"), String(localized: "Z–A", comment: "Sort menu choice: alphabetical order, descending. Keep the en dash between the last and first letter of the alphabet")])
        sortPicker.item(at: 0)?.title = String(localized: "Recently updated", comment: "Sort menu choice: newest modification date first")
        sortPicker.isBordered = false
        sortPicker.contentTintColor = .controlAccentColor
        sortPicker.font = .systemFont(ofSize: 13)
        sortPicker.setAccessibilityIdentifier("NoteListSort")
        sortPicker.setAccessibilityLabel(String(localized: "Sort notes by", comment: "Accessibility label of the sort pop-up in the note list"))
        sortPicker.target = self
        sortPicker.action = #selector(changeSort)
        search.controlSize = .large
        search.bezelStyle = .roundedBezel
        search.cell?.wraps = false
        search.placeholderString = String(localized: "Search notes", comment: "Placeholder and accessibility label of the note list search field")
        search.setAccessibilityIdentifier("NoteListSearch")
        search.setAccessibilityLabel(String(localized: "Search notes", comment: "Placeholder and accessibility label of the note list search field"))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.searchMenuTemplate = nil
        let create = ActionButton(String(localized: "New Note", comment: "Note list button that creates a note")) { [weak self] in self?.delegate?.newNote() }
        createButton = create
        create.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        create.imagePosition = .imageLeading
        create.bezelStyle = .glass
        create.borderShape = .capsule
        create.contentTintColor = .labelColor

        create.controlSize = .large
        let actions = NSStackView(views: [search, create])
        actions.distribution = .fill
        actions.spacing = 16
        actions.alignment = .centerY
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let sorting = NSStackView(views: [sortPicker, NSView(), count])
        sorting.spacing = 8
        // Long translations shorten the count before they push it out of the window.
        count.lineBreakMode = .byTruncatingTail
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sortPicker.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.isHidden = true
        emptyAddButton.onAction = { [weak self] in self?.delegate?.addExistingFiles() }
        emptyAddButton.setAccessibilityLabel(String(localized: "Add Existing Files", comment: "Accessibility label of the Add Existing Files button in the empty note list"))
        emptyAddButton.isHidden = true
        table.addTableColumn(NSTableColumn(identifier: .init("Note")))
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.tableColumns[0].width = 396
        table.rowHeight = Self.rowHeight(scale: interfaceScale)
        table.intercellSpacing = NSSize(width: 0, height: 12)
        table.style = .fullWidth
        table.backgroundColor = .windowBackgroundColor
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([.fileURL])
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        (table as? NoteListTableView)?.handleCommand = { [weak self] command in
            self?.handleCommand(command) ?? false
        }
        (table as? NoteListTableView)?.rowMenu = { [weak self] row in self?.menu(forRow: row) }
        table.setAccessibilityLabel(String(localized: "Notes", comment: "Accessibility label of the table of notes"))
        table.setAccessibilityHelp(String(localized: "Command-click to toggle notes. Shift-click or Shift-arrow to select a range. Press Return to open selected notes or Shift-F10 for batch actions.", comment: "Accessibility help of the note table. Keep key names consistent with the user's keyboard terms"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        emptyActions.setViews([emptyMessage, emptyAddButton], in: .leading)
        emptyActions.spacing = 8
        emptyActions.isHidden = true
        let header = NSStackView(views: [actions, sorting, status, emptyActions])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 16
        header.edgeInsets = NSEdgeInsets(top: HeaderMetrics.height + 8, left: 24, bottom: 12, right: 24)
        let material = NSGlassEffectView()
        material.style = .regular
        material.cornerRadius = 0
        material.contentView = header
        let content = HeaderScrollContainer(scrollView: scroll, header: header)
        content.clipsToBounds = true
        view.addArrangedSubview(content)
        for child in [scroll, material] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        // Give wrapping labels a width so long warnings and the empty message wrap instead of clipping.
        headerRowWidths = [sorting, status, emptyActions].map { $0.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -48) }
        NSLayoutConstraint.activate(headerRowWidths.filter { !($0.firstItem as! NSView).isHidden })
        emptyMessage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 100, left: 0, bottom: 0, right: 0)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: view.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            material.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: -12),
            material.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 12),
            material.topAnchor.constraint(equalTo: header.topAnchor),
            material.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        searchHeightConstraint = search.heightAnchor.constraint(equalToConstant: 32)
        createHeightConstraint = create.heightAnchor.constraint(equalToConstant: 32)
        createWidthConstraint = create.widthAnchor.constraint(equalToConstant: 116)
        NSLayoutConstraint.activate([
            actions.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchHeightConstraint,
            createHeightConstraint,
            createWidthConstraint,
            sorting.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24),
            sorting.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            status.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        updateKeyViewLoop(empty: true)
        updateControlMetrics()
    }
    func focus(noteID: NoteID? = nil) {
        if let noteID {
            pendingSelection = noteID
            pendingSelectionBase = Set(selectedNotes.map(\.id))
            search.stringValue = ""
            runQuery()
        }
        search.window?.makeFirstResponder(search)
    }
    /// `captures` holds unsaved editor text. It stays searchable even when its file is unavailable.
    func update(_ notes: [NoteSnapshot], availability: [NoteID: NoteAvailability] = [:], captures: [NoteID: NoteListEditCapture] = [:]) {
        // A hidden list skips the query, so defer sorting until reveal.
        guard isPresented() else {
            deferredUpdate = (notes, availability, captures)
            needsQuery = true
            return
        }
        deferredUpdate = nil
        // Compare UUIDs, not strings, to skip two allocations per comparison.
        let latest = notes.sorted { $0.id.rawValue < $1.id.rawValue }
        guard self.notes != latest || sourceAvailability != availability || self.captures != captures || needsQuery else { return }
        let availabilityChanged = sourceAvailability != availability
        sourceAvailability = availability
        if availabilityChanged { table.reloadData() }
        self.notes = latest
        self.captures = captures
        runQuery()
        notesChanged()
    }
    func reveal() {
        if let (notes, availability, captures) = deferredUpdate { update(notes, availability: availability, captures: captures) }
        else if needsQuery { runQuery() }
        refreshTones()
    }
    func controlTextDidChange(_ obj: Notification) { runQuery() }
    private func runQuery() {
        needsQuery = true
        task?.cancel()
        request = UUID()
        guard isPresented() else { return }
        queryCount += 1
        let generation = queryCount
        let ticket = UUID()
        request = ticket
        let selectedAtStart = Set(selectedNotes.map(\.id))
        if pendingSelection != nil, selectedAtStart != pendingSelectionBase { pendingSelection = nil }
        let requested = pendingRegisteredSelection ?? pendingSelection.map { Set([$0]) } ?? selectedAtStart
        let registeredSelection = pendingRegisteredSelection
        let query = search.stringValue
        let snapshots = notes
        let items = notes.map { NoteListItem(note: $0, capture: captures[$0.id], sourceAvailability: availability(of: $0)) }
        let searchQuery = SearchQuery(text: query, sort: sort, ascending: ascending)
        // Keep the current status and its layout until replacement results arrive.
        // Live edits must not collapse an existing file-error or empty-state message.
        if indexing {
            status.stringValue = String(localized: "Indexing… Available results are shown below.", comment: "Note list status while indexing continues and partial results are shown")
            setHeaderRow(status, hidden: false)
        }
        task = Task { [weak self, index] in
            let matches = await index.search(items.map(\.searchDocument), query: searchQuery)
            let found = matches.map { NoteListResult(item: items[$0.offset], match: $0) }
            guard let self, !Task.isCancelled, request == ticket, isPresented() else { return }
            needsQuery = false
            // A selection the user made while the search ran wins over the requested one.
            // Replacing it would move the selection under a click and drop a double-click.
            let current = Set(selectedNotes.map(\.id))
            let selected = current != selectedAtStart ? current : requested
            let previous = results
            let wasShowingSearchResults = showingSearchResults
            results = found
            showingSearchResults = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if showingSearchResults == wasShowingSearchResults, previous.map(\.note.id) == found.map(\.note.id) {
                // Same rows in the same order, usually after one edit. Redraw only changed rows.
                let changed = IndexSet(found.indices.filter { previous[$0] != found[$0] })
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
            } else { table.reloadData() }
            var rows = IndexSet(found.indices.filter { selected.contains(found[$0].note.id) })
            if rows.isEmpty, !found.isEmpty, registeredSelection == nil { rows.insert(0) }
            table.selectRowIndexes(rows, byExtendingSelection: false)
            if pendingSelection != nil, let row = rows.first { table.scrollRowToVisible(row) }
            pendingSelection = nil
            pendingRegisteredSelection = nil
            lastAppliedQueryGeneration = generation
            let unavailable = snapshots.filter { availability(of: $0) != .available }.count
            updateSelectionCount()
            let empty = snapshots.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            emptyMessage.isHidden = !empty
            emptyAddButton.isHidden = !empty
            setHeaderRow(emptyActions, hidden: !empty)
            updateKeyViewLoop(empty: empty)
            setHeaderRow(status, hidden: !indexing && unavailable == 0 && !found.isEmpty)
            let visibleAdded = registeredSelection.map { ids in found.filter { ids.contains($0.note.id) }.count }
            let hiddenAdded = registeredSelection.map { max(0, $0.count - $0.filter { id in found.contains { $0.note.id == id } }.count) }
            status.stringValue = Self.statusText(indexing: indexing, added: visibleAdded == nil ? nil : (registeredSelection?.count ?? 0, hiddenAdded ?? 0),
                                                 resultCount: found.count, unavailable: unavailable, hasNotes: !snapshots.isEmpty)
            if visibleAdded != nil { setHeaderRow(status, hidden: false) }
        }
    }
    static func statusText(indexing: Bool, added: (total: Int, hidden: Int)?, resultCount: Int, unavailable: Int, hasNotes: Bool) -> String {
        if indexing { return String(localized: "Indexing… Available results are shown below.", comment: "Note list status while the search index builds") }
        if let added {
            return String(localized: "Added \(added.total) files. \(added.hidden) hidden by the current search.", comment: "Note list status after adding files; first count is files added, second is how many the search filter hides")
        }
        if unavailable > 0 {
            return String(localized: "\(resultCount) results · \(unavailable) unavailable files", comment: "Note list status; first count is search results, second is files that cannot be read")
        }
        if resultCount == 0 { return hasNotes ? String(localized: "No matching notes.", comment: "Note list status when the search matches nothing") : "" }
        return String(localized: "\(resultCount) notes", comment: "Note list status: number of notes shown")
    }

    private func updateSelectionCount() {
        let total = results.count
        let selected = table.numberOfSelectedRows
        count.stringValue = String(localized: "\(total) notes · \(selected) selected", comment: "Note list footer; first count is notes shown, second is selected notes")
        count.setAccessibilityLabel(count.stringValue)
        table.setAccessibilityValue(String(localized: "\(selected) notes selected", comment: "VoiceOver value of the note list: number of selected notes"))
        table.setAccessibilityCustomActions(menu(forRow: table.selectedRow)?.items.compactMap { item in
            guard let item = item as? NoteRowMenuItem, item.isEnabled else { return nil }
            return NSAccessibilityCustomAction(name: item.title) { item.invoke(); return true }
        })
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionCount() }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL]? {
        guard actionsAllowed(), info.draggingSource == nil,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
              urls.allSatisfy({ $0.isFileURL && NoteFilename($0.lastPathComponent) != nil }) else { return nil }
        return urls
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard delegate != nil, droppedFiles(info) != nil else { (tableView as? NoteListTableView)?.isDropTarget = false; return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        (tableView as? NoteListTableView)?.isDropTarget = true
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = droppedFiles(info), let delegate else { return false }
        (tableView as? NoteListTableView)?.isDropTarget = false
        delegate.registerFiles(urls)
        return true
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard actionsAllowed(), results.indices.contains(row), let delegate else { return nil }
        let note = results[row].note
        guard availability(of: note) == .available else { return nil }
        let text: String?
        do { text = try delegate.dragText(note) } catch { return nil }
        let promise = NoteDragPromise(name: note.fileURL.lastPathComponent) { url in
            try await delegate.exportDrag(note, text: text, to: url)
        }
        return promise.provider
    }

    /// The tooltip of a row whose original file is unavailable.
    nonisolated static func unavailableDetail(_ item: NoteListItem) -> String {
        switch item.textAvailability {
        case .available:
            String(localized: "Local text is retained. The original file is unavailable.", comment: "Tooltip of a note row whose original file is unavailable but whose text is kept")
        case .trashed:
            String(localized: "File was moved to Trash", comment: "Row title for a note whose file was moved to the Trash. Use the system term for Trash")
        case let .unavailable(reason):
            String(String(localized: "Unavailable: \(reason)", comment: "Search result snippet for an unavailable note. The value is the reason, already localized").prefix(160))
        case .missingOriginal:
            String(localized: "Original missing", comment: "Tooltip of a note row whose original file can't be found")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.rowHeight(scale: interfaceScale)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NoteListRow()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = results[row]
        let note = result.note
        // Use the query that made these rows, not a newer one that is still indexing.
        let item = result.item
        let excerpt: String
        if showingSearchResults, case let .text(text) = result.match.excerpt { excerpt = text } else { excerpt = result.match.preview }
        let updated = item.updatedAt.map { Self.dateFormatter.string(from: $0) } ?? ""
        let cell = tableView.makeView(withIdentifier: NoteListCell.reuseIdentifier, owner: self) as? NoteListCell ?? NoteListCell()
        cell.applyScale(interfaceScale)
        cell.configure(excerpt: excerpt, updated: updated, opened: isOpen(note.id), tone: backgroundTone(note.id),
                       unavailableDetail: item.sourceAvailability == .available ? nil : Self.unavailableDetail(item),
                       issue: noteIssue(note.id),
                       trashed: availability(of: note) == .trashed, failureTitle: availability(of: note) == .trashed ? String(localized: "File was moved to Trash", comment: "Row title for a note whose file was moved to the Trash. Use the system term for Trash") : availability(of: note) == .missingOriginal ? String(localized: "File not located…", comment: "Row title for a note whose file could not be found") : NoteLocationPresentation.failureTitle(note.accessFailure), path: NoteLocationPresentation.path(note.fileURL), locationTitle: NoteLocationPresentation.label(note.fileURL, defaultFolder: defaultFolder),
                       locationAction: { [weak self] in self?.delegate?.location(note) },
                       actions: { [weak self] anchor in
                           guard let self, let row = self.results.firstIndex(where: { $0.note.id == note.id }),
                                 let menu = self.menu(forRow: row) else { return }
                           menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : -4), in: anchor)
                       })
        cell.setAccessibilityCustomActions(menu(forRow: row)?.items.compactMap { item -> NSAccessibilityCustomAction? in
            guard let item = item as? NoteRowMenuItem, item.isEnabled else { return nil }
            return NSAccessibilityCustomAction(name: item.title) { item.invoke(); return true }
        })
        return cell
    }
    /// Capture identity, never a selection or row index that can change while the menu is open.
    func menu(forRow row: Int) -> NSMenu? {
        guard results.indices.contains(row) else { return nil }
        let note = results[row].note
        if table.isRowSelected(row), selectedNotes.count > 1 {
            let captured = selectedNotes
            let menu = NSMenu()
            menu.autoenablesItems = false
            func addBatch(_ title: String, action: @escaping ([NoteSnapshot]) -> Void) {
                let item = NoteRowMenuItem(title: title) { [weak self] in
                    guard let self, self.actionsAllowed() else { return }
                    let current = captured.compactMap { old in self.notes.first { $0.id == old.id && $0.collectionToken == old.collectionToken } }
                    guard current.count == captured.count, current.allSatisfy({ self.availability(of: $0) == .available }) else { return }
                    action(current)
                }
                item.isEnabled = actionsAllowed() && captured.allSatisfy { availability(of: $0) == .available }
                menu.addItem(item)
            }
            addBatch(String(localized: "Open \(captured.count) Notes", comment: "Note list context menu: open several selected notes")) { [weak self] in self?.delegate?.openBatch($0) }
            addBatch(String(localized: "Move \(captured.count) Notes to Trash…", comment: "Note list context menu: move several selected notes to the Trash")) { [weak self] in self?.delegate?.trashBatch($0) }
            let problems = captured.filter { availability(of: $0) != .available }
            if !problems.isEmpty {
                menu.addItem(.separator())
                let item = NoteRowMenuItem(title: String(localized: "Remove \(problems.count) Notes from List", comment: "Note list context menu: remove several selected unavailable notes from the list without deleting files")) { [weak self] in
                    guard let self, self.actionsAllowed() else { return }
                    let current = problems.compactMap { old in self.notes.first { $0.id == old.id && $0.collectionToken == old.collectionToken } }
                        .filter { self.availability(of: $0) != .available }
                    guard !current.isEmpty else { return }
                    self.delegate?.removeUnavailableBatch(current)
                }
                item.isEnabled = actionsAllowed()
                item.toolTip = String(localized: "Removes the selected unavailable notes from the list. Does not delete any files.", comment: "Tooltip of the batch Remove from List item")
                menu.addItem(item)
            }
            return menu
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, toolTip: String? = nil, availableOnly: Bool = false, unavailableOnly: Bool = false, _ action: @escaping (NoteSnapshot) -> Void) {
            let item = NoteRowMenuItem(title: title) { [weak self] in
                guard let self, self.actionsAllowed(),
                      let current = self.notes.first(where: { $0.id == note.id && $0.collectionToken == note.collectionToken }),
                      !availableOnly || self.availability(of: current) == .available,
                      !unavailableOnly || self.availability(of: current) != .available else { return }
                action(current)
            }
            item.isEnabled = actionsAllowed() && (!availableOnly || availability(of: note) == .available)
                && (!unavailableOnly || availability(of: note) != .available)
            item.toolTip = toolTip
            menu.addItem(item)
        }
        add(String(localized: "Open", comment: "Note row context menu item that opens the note (verb)"), availableOnly: true) { [weak self] in self?.delegate?.open($0) }
        add(String(localized: "Show in Finder", comment: "Note row context menu item. Use the system term for Finder"), availableOnly: true) { [weak self] in self?.delegate?.showInFinder($0) }
        if availability(of: note) == .available {
            add(String(localized: "Move To…", comment: "Note row context menu item that moves the note file to another location"), availableOnly: true) { [weak self] in self?.delegate?.moveTo($0) }
        } else {
            add(String(localized: "Save a Copy…", comment: "Note row context menu item that saves the text to a new file")) { [weak self] in self?.delegate?.saveCopy($0) }
            if hasPreservedText(note.id) {
                add(String(localized: "Open Preserved Text", comment: "Note row context menu item that opens the text kept for an unavailable note"), unavailableOnly: true) { [weak self] in self?.delegate?.openPreservedText($0) }
            }
        }
        add(String(localized: "Move to Trash…", comment: "Note row context menu item that moves the note file to the Trash. Use the system term for Trash"), availableOnly: true) { [weak self] in self?.delegate?.trash($0) }
        if availability(of: note) != .available {
            menu.addItem(.separator())
            if needsAccessRepair(note) {
                add(String(localized: "Restore File Access…", comment: "Note list button and context menu item that asks the user to grant access to the notes folder again")) { [weak self] in self?.delegate?.restoreFileAccess($0) }
            } else {
                add(String(localized: "Locate File…", comment: "Note list button and context menu item that lets the user pick the file for an unavailable note")) { [weak self] in self?.delegate?.locate($0) }
            }
            add(String(localized: "Remove from List", comment: "Note row context menu item that removes an unavailable note from the list without deleting files"), toolTip: String(localized: "Removing this entry does not delete any files.", comment: "Tooltip of Remove from List"), unavailableOnly: true) { [weak self] in
                self?.delegate?.removeUnavailable($0)
            }
        }
        return menu
    }

    @objc private func changeSort() {
        let selection = sortPicker.indexOfSelectedItem - 1
        guard (0..<6).contains(selection) else { return }
        sortPicker.item(at: 0)?.title = sortPicker.titleOfSelectedItem ?? String(localized: "Recently updated", comment: "Sort menu choice: newest modification date first")
        sortPicker.selectItem(at: 0)
        sort = selection < 2 ? .updated : selection < 4 ? .created : .alphabetical
        ascending = selection == 1 || selection == 3 || selection == 4
        runQuery()
    }
    @objc private func openSelected() {
        guard actionsAllowed() else { return }
        let selected = selectedNotes.filter { availability(of: $0) == .available }
        if selected.count == 1 { delegate?.open(selected[0]) }
        else if !selected.isEmpty { delegate?.openBatch(selected) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector)
    }
    private func handleCommand(_ commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !results.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(results.count - 1, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        }
        return false
    }
}

@MainActor
private final class NoteRowMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func invoke() { guard isEnabled else { return }; perform() }
}
