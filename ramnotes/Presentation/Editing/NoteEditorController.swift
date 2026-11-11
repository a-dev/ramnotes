import ramnotesDomain
import AppKit
import CoreFoundation

/// The outbox sends edits to the store in order. Consecutive edits merge, and the latest
/// edit wins. Writing-state changes remain ordered between edits.
@MainActor
final class NoteEditorController: NSObject, NSTextViewDelegate, LocationEditor {
    private enum Delivery {
        case edit(EditSnapshot, composing: Bool)
        case writing(Bool)
    }

    let textView = PlainTextView()
    let scrollView = NSScrollView()
    private(set) var note: NoteSnapshot
    private(set) var state = NoteSaveState()
    private var sourceAvailable: Bool
    private var hasRecoverableBuffer: Bool
    private var editingLocks: Set<UUID> = []
    private let flushNote: @MainActor () async throws -> Void
    private let store: any EditorNotes
    /// Sends `outbox` to the store one call at a time. Await it to wait for a flush.
    private var delivery: Task<Void, Never>?
    private var outbox: [Delivery] = []
    /// Store calls not sent yet. Holds at most one edit between writing-state changes.
    var queuedDeliveryCount: Int { outbox.count }
    private var lastCapturedText: String
    private var deferredReload: NoteSnapshot?
    private var settings = AppSettings()
    private(set) var fontSizeOverride: Double?
    var backgroundTone: NoteBackgroundTone? { didSet { applyBackground() } }
    var positionChanged: (() -> Void)?
    var localTextEdited: ((EditRevision) -> Void)?
    var fontSizeChanged: ((Double?) -> Void)?
    var contentChanged: ((NoteSnapshot) -> Void)?
    var titleChanged: ((String) -> Void)?
    private(set) var lastEditedAt: Date?
    /// The text as of the latest capture. `textDidChange` captures synchronously, so this
    /// matches the view without copying the whole buffer the way `textView.string` does.
    var capturedText: String { lastCapturedText }
    var statusChanged: ((StorageSaveStatus) -> Void)?
    var documentStateChanged: (() -> Void)?

    init(note: NoteSnapshot, store: any EditorNotes, settings: AppSettings = AppSettings(), restoredEdit: EditSnapshot? = nil, flushNote: (@MainActor () async throws -> Void)? = nil) {
        // Drop a buffer the store already saved. Restoring it would reuse old revision numbers.
        let restoredEdit = restoredEdit.flatMap { $0.locationRevision == note.locationRevision && $0.revision > note.editRevision ? $0 : nil }
        self.note = restoredEdit.map { NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
            fileRevision: $0.baseRevision, text: note.text, availability: note.availability, accessFailure: note.accessFailure, editRevision: note.editRevision, locationRevision: note.locationRevision, createdAt: note.createdAt) } ?? note
        self.state = NoteSaveState(savedRevision: note.editRevision, currentRevision: restoredEdit?.revision)
        self.sourceAvailable = note.availability == .available
        self.hasRecoverableBuffer = restoredEdit != nil
        self.flushNote = flushNote ?? { try await store.flush(note.id) }
        self.store = store
        self.lastCapturedText = restoredEdit?.text ?? note.text
        super.init()
        updateEditability()
        textView.isRichText = false
        // The text controls writing direction independently of the interface language.
        textView.baseWritingDirection = .natural
        textView.alignment = .natural
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 20, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = restoredEdit?.text ?? note.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setAccessibilityLabel(String(localized: "Note text", comment: "Accessibility label of the note's text editor"))
        textView.delegate = self
        textView.compositionChanged = { [weak self] in self?.finishInteraction() }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.findBarPosition = .aboveContent
        scrollView.documentView = textView
        apply(settings)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var installingPresentation = false
    private(set) var positionRevision: UInt64 = 0
    @objc private func viewportChanged(_ notification: Notification) {
        if !installingPresentation { positionRevision &+= 1 }
        positionChanged?()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        if !installingPresentation { positionRevision &+= 1 }
        positionChanged?()
    }

    var editorPosition: EditorPosition {
        let origin = scrollView.contentView.bounds.origin
        return EditorPosition(selections: textView.selectedRanges.map {
            .init(location: $0.rangeValue.location, length: $0.rangeValue.length)
        }, scrollX: origin.x, scrollY: origin.y,
        hasActiveCaret: textView.window?.firstResponder === textView,
        fileModifiedAt: note.fileRevision?.modifiedAt,
        unsavedRevision: state.hasUnsavedEdits ? state.currentRevision : nil)
    }

    /// Called synchronously after the window has its final frame; no delayed work can
    /// overwrite a selection made after presentation.
    func restorePosition(_ position: EditorPosition) {
        let wasInstalling = installingPresentation
        installingPresentation = true
        defer { installingPresentation = wasInstalling }
        // Restore only onto the text the position was captured for: the file, or the same unsaved edit.
        let unsaved: EditRevision? = state.hasUnsavedEdits ? state.currentRevision : nil
        guard position.fileModifiedAt == note.fileRevision?.modifiedAt, position.unsavedRevision == unsaved,
              !textView.hasMarkedText(), !textView.isWritingToolsActive else { return }
        scrollView.superview?.layoutSubtreeIfNeeded()
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let length = (textView.string as NSString).length
        let ranges = position.selections.map { selection in
            let location = min(selection.location, length)
            return NSValue(range: NSRange(location: location, length: min(selection.length, length - location)))
        }
        textView.selectedRanges = ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: min(position.scrollX, max(0, textView.bounds.width - clip.bounds.width)),
                                y: position.scrollY <= 0 ? -scrollView.contentInsets.top
                                    : min(position.scrollY, max(0, textView.bounds.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
        textView.preventAutomaticFocus = !position.hasActiveCaret
        if !ranges.isEmpty { textView.scrollRangeToVisible(textView.selectedRange()) }
        if !position.hasActiveCaret, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    /// Availability and lock ownership can change at any `await`, independently.
    @discardableResult
    func beginEditingLock(_ token: UUID = UUID()) -> UUID {
        editingLocks.insert(token)
        updateEditability()
        return token
    }

    func endEditingLock(_ token: UUID) {
        editingLocks.remove(token)
        updateEditability()
    }

    private func updateEditability() {
        textView.isEditable = (sourceAvailable || hasRecoverableBuffer) && editingLocks.isEmpty
    }

    func apply(_ settings: AppSettings) {
        self.settings = EditorTypography.normalized(settings)
        var settings = self.settings
        if let fontSizeOverride {
            settings.fontSize = fontSizeOverride
            settings.lineHeight = self.settings.lineHeight * fontSizeOverride / self.settings.fontSize
        }
        let scrollOrigin = scrollView.contentView.bounds.origin
        let selected = textView.selectedRanges
        let font = EditorTypography.font(for: settings)
        textView.font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(settings.lineHeight, font.pointSize)
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]
        textView.textColor = .textColor
        applyBackground()
        textView.selectedRanges = selected
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func applyBackground() {
        let color = NoteTonePalette.surface(backgroundTone)
        textView.backgroundColor = color
        textView.textColor = NoteTonePalette.readable(.textColor, on: color)
        textView.insertionPointColor = NoteTonePalette.readable(.textColor, on: color)
        scrollView.backgroundColor = color
        scrollView.contentView.backgroundColor = color
    }

    func setFontSize(_ size: Double?) {
        fontSizeOverride = size.flatMap { $0.isFinite ? min(192, max(8, $0)) : nil }
        apply(settings)
        fontSizeChanged?(fontSizeOverride)
    }

    func adjustFontSize(by delta: Double) {
        setFontSize((fontSizeOverride ?? settings.fontSize) + delta)
    }

    func textDidChange(_ notification: Notification) { capture() }
    func textViewWritingToolsWillBegin(_ textView: NSTextView) { enqueue(.writing(true)) }
    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        if state.hasUnsavedEdits || textView.string != lastCapturedText { capture() }
        else {
            enqueue(.writing(false))
            if let reload = deferredReload { applyExternal(reload) }
        }
    }

    private func enqueue(_ item: Delivery) {
        if case .edit = item, case .edit = outbox.last {
            outbox[outbox.count - 1] = item
        }
        else { outbox.append(item) }
        guard delivery == nil else { return }
        delivery = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !outbox.isEmpty {
            await deliver(outbox.removeFirst())
        }
        // No `await` since the empty check, so the next enqueue starts a new drain.
        delivery = nil
    }

    private func deliver(_ item: Delivery) async {
        switch item {
        case let .writing(active):
            try? await store.setWriting(active, for: note.id)
        case let .edit(edit, composing: true):
            try? await store.setWriting(true, for: edit.id)
            let status = await store.submit(edit)
            statusChanged?(status)
        case let .edit(edit, composing: false):
            do { try await store.finishWriting(edit) }
            catch { statusChanged?(.failed(edit.revision, NoteFailureMapping.operationError(error), journaled: false)) }
        }
    }


    private func finishInteraction() {
        capture()
        if !state.hasUnsavedEdits, let reload = deferredReload { applyExternal(reload) }
    }
    func capture() {
        // Read once. Each NSTextView.string read copies all the text.
        let text = textView.string
        let changed = text != lastCapturedText
        guard changed || state.hasUnsavedEdits else { return }
        let revision = changed ? state.edited() : state.currentRevision
        lastCapturedText = text
        if changed {
            lastEditedAt = Date()
            localTextEdited?(revision)
            let current = NoteSnapshot(id: note.id, collectionToken: note.collectionToken,
                fileURL: note.fileURL, fileRevision: note.fileRevision, text: text,
                availability: note.availability, accessFailure: note.accessFailure, editRevision: revision, locationRevision: note.locationRevision, createdAt: note.createdAt)
            contentChanged?(current)
            titleChanged?(current.title)
            documentStateChanged?()
        }
        let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken,
            revision: revision, baseRevision: note.fileRevision, text: text, locationRevision: note.locationRevision)
        enqueue(.edit(edit, composing: textView.hasMarkedText() || textView.isWritingToolsActive))
    }

    func receive(_ status: StorageSaveStatus) {
        let completed: EditRevision?
        switch status {
        case let .saved(revision): completed = revision
        default: completed = nil
        }
        if let completed {
            state.completedSave(.saved(revision: completed, fileRevision: note.fileRevision ?? FileRevision(fingerprint: "", modifiedAt: .distantPast)))
        }
        statusChanged?(status)
        documentStateChanged?()
    }

    /// Adopts the store's verified snapshot after a save. Later external changes arrive
    /// through reconcile, so no re-read is needed.
    func adoptSaved(_ saved: NoteSnapshot) {
        guard saved.id == note.id, saved.collectionToken == note.collectionToken,
              saved.locationRevision.rawValue >= note.locationRevision.rawValue,
              !state.hasUnsavedEdits, saved.editRevision >= note.editRevision else { return }
        // Leave the text view alone, so newline or BOM fixes on disk don't clear Undo.
        note = saved
        documentStateChanged?()
    }

    /// The application has durably detached the old draft before publishing this binding.
    @discardableResult
    func applyRebinding(_ updated: NoteSnapshot) -> Bool {
        guard updated.id == note.id, updated.collectionToken == note.collectionToken,
              updated.locationRevision.rawValue > note.locationRevision.rawValue else { return false }
        let revision = max(state.currentRevision, updated.editRevision)
        state = NoteSaveState(savedRevision: revision)
        outbox.removeAll()
        deferredReload = nil
        textView.unmarkText()
        textView.string = updated.text
        textView.undoManager?.removeAllActions()
        lastCapturedText = updated.text
        note = updated
        hasRecoverableBuffer = false
        sourceAvailable = updated.availability == .available
        updateEditability()
        titleChanged?(updated.title)
        documentStateChanged?()
        return true
    }

    /// The editor keeps unsaved or composing text. Storage resolves conflicts on its own.
    @discardableResult
    func applyExternal(_ updated: NoteSnapshot) -> Bool {
        installingPresentation = true
        defer { installingPresentation = false }
        guard updated.id == note.id, updated.collectionToken == note.collectionToken,
              updated.locationRevision.rawValue >= note.locationRevision.rawValue,
              updated.editRevision >= state.savedRevision else { return false }
        let locationChanged = updated.fileURL != note.fileURL || updated.locationRevision != note.locationRevision
        if locationChanged {
            // A rename changes only the location, so adopt it even with unsaved text.
            note = NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: updated.fileURL,
                fileRevision: note.fileRevision, text: note.text, availability: updated.availability, accessFailure: updated.accessFailure, editRevision: note.editRevision, locationRevision: updated.locationRevision, createdAt: updated.createdAt)
            titleChanged?(NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
                fileRevision: nil, text: textView.string, availability: .available).title)
            documentStateChanged?()
        }
        if note.availability != updated.availability || note.accessFailure != updated.accessFailure {
            note = NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
                fileRevision: note.fileRevision, text: note.text, availability: updated.availability,
                accessFailure: updated.accessFailure, editRevision: note.editRevision, locationRevision: note.locationRevision, createdAt: updated.createdAt)
            documentStateChanged?()
        }
        let becameAvailable = !sourceAvailable && updated.availability == .available
        sourceAvailable = updated.availability == .available
        hasRecoverableBuffer = hasRecoverableBuffer || state.hasUnsavedEdits || textView.string != lastCapturedText
        updateEditability()
        // A capture sent earlier may have failed at the old location. Resend the text now.
        if locationChanged && state.hasUnsavedEdits { capture() }
        guard sourceAvailable else {
            deferredReload = nil
            statusChanged?(.failed(state.currentRevision, updated.accessFailure.map(NoteOperationError.accessFailure) ?? .unavailable, journaled: false))
            return false
        }
        guard !state.hasUnsavedEdits, !textView.hasMarkedText(), !textView.isWritingToolsActive else {
            deferredReload = updated
            return false
        }
        let resetsPosition = updated.fileObservation == .disk && note.fileRevision?.modifiedAt != nil
            && updated.fileRevision?.modifiedAt != note.fileRevision?.modifiedAt
        let selection = textView.selectedRanges
        let origin = scrollView.contentView.bounds.origin
        if textView.string != updated.text {
            textView.string = updated.text
            textView.undoManager?.removeAllActions()
            let length = (updated.text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        hasRecoverableBuffer = false
        updateEditability()
        lastCapturedText = updated.text
        note = updated
        deferredReload = nil
        // The unavailable warning came from this editor, not from a save, so clear it here.
        if becameAvailable { statusChanged?(.saved(state.savedRevision)) }
        if resetsPosition {
            textView.undoManager?.removeAllActions()
            restorePosition(EditorPosition(selections: [], scrollX: 0, scrollY: 0,
                hasActiveCaret: false, fileModifiedAt: updated.fileRevision?.modifiedAt))
            positionChanged?()
        }
        documentStateChanged?()
        return true
    }

    private var locations: LocationWorkflow {
        LocationWorkflow(notes: store)
    }
    func removeTracking() async throws { try await locations.removeTracking(note, editor: self) }
    func renewFileAccess(file: any FileGrant, expected: NoteSnapshot) async throws -> NoteSnapshot {
        try await locations.renewAccess(expected, file: file, editor: self)
    }
    func relink(file: any FileGrant) async throws -> NoteSnapshot {
        try await locations.relink(note, file: file, editor: self)
    }
    func prepareForTrackingRemoval() async throws {
        guard !textView.isWritingToolsActive else { throw NoteOperationError.inputOutput(LocalizedStringResource("Finish Writing Tools before removing tracking.", comment: "Error when Writing Tools is active and the user stops tracking a note")) }
        textView.unmarkText()
        if textView.string != lastCapturedText { capture() }
        await delivery?.value
    }

    func move(to url: URL) async throws -> NoteMoveResult {
        try await locations.move(note, to: url, editor: self)
    }
    func prepareForMove() async throws -> EditRevision {
        guard !textView.isWritingToolsActive else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Finish Writing Tools before moving the note.", comment: "Error when Writing Tools is active and the user moves a note"))
        }
        textView.unmarkText()
        if textView.string != lastCapturedText { capture() }
        await delivery?.value
        try Task.checkCancellation()
        try await flushNote()
        if let status = await store.status(note.id) { receive(status) }
        return state.savedRevision
    }
    func acceptLocation(_ note: NoteSnapshot) { _ = applyExternal(note) }

    func saveCopy(to url: URL) async throws -> NoteSnapshot {
        guard !textView.isWritingToolsActive else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Finish Writing Tools before saving a copy.", comment: "Error when Writing Tools is active and the user saves a copy"))
        }
        if textView.hasMarkedText() { textView.unmarkText() }
        if textView.string != lastCapturedText { capture() }
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        await delivery?.value
        try Task.checkCancellation()
        let destination = try await store.acquireDestinationFile(url)
        let copy = try await store.createCopy(from: note, editRevision: state.currentRevision, text: textView.string, to: destination)
        // A copy that holds the unsaved text releases this note, as Export does.
        if let status = await store.status(note.id) { receive(status) }
        return copy
    }

    /// Drops the text that could not be saved, after the user confirmed it.
    func discardUnsavedEdits() async throws {
        guard !textView.hasMarkedText(), !textView.isWritingToolsActive else { throw NoteOperationError.inputOutput(LocalizedStringResource("Finish text composition or Writing Tools before closing.", comment: "Error when text composition or Writing Tools is active and the user closes the note")) }
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        if textView.string != lastCapturedText { capture() }
        await delivery?.value
        try Task.checkCancellation()
        try await store.discardEdits(note.id, through: state.currentRevision)
    }

    func export(to url: URL) async throws {
        guard !textView.hasMarkedText(), !textView.isWritingToolsActive else { throw NoteOperationError.inputOutput(LocalizedStringResource("Finish text composition before exporting.", comment: "Error when text composition is in progress and the user exports")) }
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        await delivery?.value
        try Task.checkCancellation()
        try await store.exportText(note.id, text: textView.string, to: url)
        if let status = await store.status(note.id) { receive(status) }
    }

    /// Commits marked text before a default-folder change. Writing Tools must end its
    /// session before any move can commit.
    func flushForDefaultFolderChange() async throws {
        guard !textView.isWritingToolsActive else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Finish Writing Tools before changing the default folder.", comment: "Error when Writing Tools is active and the user changes the default folder"))
        }
        if textView.hasMarkedText() { textView.unmarkText() }
        if textView.string != lastCapturedText { capture() }
        try await flush()
    }

    func flushForDeletion() async throws {
        guard !textView.isWritingToolsActive else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Finish Writing Tools before deleting the note.", comment: "Error when Writing Tools is active and the user deletes a note"))
        }
        textView.unmarkText()
        if textView.string != lastCapturedText { capture() }
        try await flush()
    }

    func retainForExternalTrash() async throws {
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        await delivery?.value
        // Composition can own text that has never produced a delivery. Capture it
        // directly; neither saving nor ending composition is required for retention.
        repeat {
            let text = textView.string
            if text != lastCapturedText {
                _ = state.edited()
                lastCapturedText = text
            }
            let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken,
                revision: state.currentRevision, baseRevision: note.fileRevision,
                text: text, locationRevision: note.locationRevision)
            try await store.retainForExternalTrash(edit)
            if textView.string == text { return }
        } while true
    }

    /// Sends the buffer to the store without requiring a verified save.
    func deliverForQuit() async throws {
        guard !textView.hasMarkedText(), !textView.isWritingToolsActive else { throw NoteOperationError.inputOutput(LocalizedStringResource("Finish text composition or Writing Tools before closing.", comment: "Error when text composition or Writing Tools is active and the user closes the note")) }
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        await delivery?.value
        try Task.checkCancellation()
    }

    func flush() async throws {
        guard !textView.hasMarkedText(), !textView.isWritingToolsActive else { throw NoteOperationError.inputOutput(LocalizedStringResource("Finish text composition or Writing Tools before closing.", comment: "Error when text composition or Writing Tools is active and the user closes the note")) }
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        await delivery?.value
        try Task.checkCancellation()
        try await flushNote()
        try Task.checkCancellation()
        guard await store.canDispose(note.id) else { throw NoteOperationError.unavailable }
        if let status = await store.status(note.id) { receive(status) }
    }
}
