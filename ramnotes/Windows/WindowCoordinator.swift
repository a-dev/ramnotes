import ramnotesDomain
import AppKit
import CoreFoundation

@MainActor
final class WindowCoordinator: LifecycleEditors {
    private(set) var windows: [NoteID: NoteWindowController] = [:]
    enum Action { case reveal, hide, toggle, escape(transientActive: Bool) }
    /// Setting metadata only clears a flag. The O(N) seed runs once, on the next focus.
    var metadata = CollectionMetadata() { didSet { focusSeeded = false } }
    private var focusSeeded = false
    /// Shared with the app layer, so storage events reach reveal and tone inheritance directly.
    let folderState: FolderState
    var notes: [NoteID: NoteSnapshot] { folderState.notes }
    var defaultFolder: URL? {
        didSet { for controller in windows.values { controller.defaultFolder = defaultFolder } }
    }
    /// A one-shot handoff of `NoteStore.retainedEdits()`: an editor takes its buffer once, at
    /// creation, and later opens read the store. Replaced whole only through
    /// `adoptRetainedEdits(_:)` after every reload; never persisted. The store's journals stay
    /// the durable copy.
    private(set) var retainedEdits: [NoteID: EditSnapshot] = [:]
    /// The one entry point that replaces the handoff, always with the store's whole map.
    func adoptRetainedEdits(_ edits: [NoteID: EditSnapshot]) { retainedEdits = edits }
    var listVisible: () -> Bool = { false }
    var hideList: (() -> Void)?
    private(set) var requestedFocus: NoteID?
    private var editingLocks: Set<UUID> = []
    private var focusCounter: UInt64 = 0
    private var hidingGroup = false
    private var geometryTasks: [NoteID: Task<Void, Never>] = [:]
    private(set) var closing: Set<NoteID> = []
    var settings = AppSettings() {
        didSet {
            for controller in windows.values {
                controller.window?.level = settings.alwaysOnTop ? .floating : .normal
                controller.editor.apply(settings)
                controller.applyInterfaceScale(1.0)
            }
        }
    }
    var openStateChanged: (() -> Void)?
    var toneChanged: (() -> Void)?
    var changed: (() -> Void)?
    var showList: (() -> Void)?
    var showSettings: (() -> Void)?
    var createNote: (() -> Void)?
    var deleteNote: ((NoteID) -> Void)?
    var configureRecovery: ((NoteWindowController) -> Void)?
    let store: any EditorNotes

    init(store: any EditorNotes, folderState: FolderState = FolderState()) {
        self.store = store
        self.folderState = folderState
    }
    private var presentationGeneration = UUID()
    private var noticeEdits: [NoteID: (revision: EditRevision, token: CollectionToken, location: LocationRevision)] = [:]

    func acceptFileObservation(_ note: NoteSnapshot) {
        if note.availability == .trashed {
            guard let controller = windows[note.id],
                  controller.editor.state.hasUnsavedEdits || controller.editor.textView.hasMarkedText() ||
                    controller.editor.textView.isWritingToolsActive || controller.editor.textView.string != controller.editor.note.text else {
                closeTrashedWindow(note.id)
                return
            }
            guard closing.insert(note.id).inserted else { return }
            Task {
                defer { closing.remove(note.id) }
                do {
                    try await controller.editor.retainForExternalTrash()
                    guard windows[note.id] === controller, notes[note.id]?.availability == .trashed else { return }
                    closeTrashedWindow(note.id)
                } catch { controller.showBlocker(error) }
            }
            return
        }
        guard let provenance = note.fileObservation, note.availability == .available,
              let timestamp = note.fileRevision?.modifiedAt else { return }
        var value = metadata.notes[note.id] ?? NoteWindowMetadata(isOpen: false)
        if let baseline = value.acceptedFileModifiedAt, baseline != timestamp, provenance == .disk {
            value.editorPosition = EditorPosition(selections: [], scrollX: 0, scrollY: 0,
                hasActiveCaret: false, fileModifiedAt: timestamp)
            value.externalChangeNoticeAt = timestamp
            noticeEdits[note.id] = nil
        }
        if provenance == .ownWrite, let edit = noticeEdits[note.id],
           edit.token == note.collectionToken, edit.location == note.locationRevision,
           note.editRevision >= edit.revision {
            value.externalChangeNoticeAt = nil
            noticeEdits[note.id] = nil
        }
        value.acceptedFileModifiedAt = timestamp
        metadata.notes[note.id] = value
        windows[note.id]?.setExternalChangeNotice(value.externalChangeNoticeAt)
        changed?()
    }

    func openVerified(_ note: NoteSnapshot, focus: Bool = true) async {
        let generation = UUID()
        presentationGeneration = generation
        await verifyAndOpen(note, focus: focus, generation: generation)
    }

    /// One selection is one presentation operation; Hide or newer navigation cancels the remainder.
    func openBatchVerified(_ selected: [NoteSnapshot]) async {
        guard let last = selected.last else { return }
        let generation = UUID()
        presentationGeneration = generation
        for note in selected {
            guard presentationGeneration == generation else { return }
            await verifyAndOpen(note, focus: note.id == last.id, generation: generation)
        }
    }

    private func verifyAndOpen(_ note: NoteSnapshot, focus: Bool, generation: UUID) async {
        let editor = windows[note.id]?.editor
        // A journal restored at launch is a pending edit with no editor yet. Verification
        // refuses pending edits, so the editor takes the retained text first.
        if editor == nil, retainedEdits[note.id] != nil {
            guard presentationGeneration == generation else { return }
            present(note, focus: focus)
            return
        }
        let revision = editor?.state.currentRevision
        let positionRevision = editor?.positionRevision
        let result: Result<NoteSnapshot, Error>
        do {
            if editor?.state.hasUnsavedEdits == true { try await editor?.flush() }
            result = .success(try await store.verifyForPresentation(note))
        } catch { result = .failure(error) }
        presentVerified(note, result: result, focus: focus, generation: generation, revision: revision, positionRevision: positionRevision)
    }

    /// Applies one verified result only if the editor and location did not move during verification.
    @discardableResult private func presentVerified(_ note: NoteSnapshot, result: Result<NoteSnapshot, Error>, focus: Bool,
                                 generation: UUID, revision: EditRevision?, positionRevision: UInt64?) -> Bool {
        guard presentationGeneration == generation else { return false }
        let editor = windows[note.id]?.editor
        switch result {
        case .success(let verified):
            guard editor?.state.currentRevision == revision,
                  editor?.positionRevision == positionRevision,
                  verified.collectionToken == notes[note.id]?.collectionToken,
                  verified.locationRevision == notes[note.id]?.locationRevision else { return false }
            acceptFileObservation(verified)
            windows[note.id]?.editor.applyExternal(verified)
            present(verified, focus: focus)
            return true
        case .failure(let error):
            guard let controller = windows[note.id] else { showList?(); return false }
            // A hidden window still holds the unsaved text. Show it with the error, so a failed
            // flush (for example a locked file) never leaves the open request with no result.
            controller.showBlocker(error)
            metadata.notes[note.id]?.isOpen = true
            if focus {
                requestedFocus = note.id
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
                recordFocus(note.id)
            } else { controller.window?.orderFront(nil) }
            openStateChanged?()
            return false
        }
    }

    func revealVerified() async {
        let generation = UUID()
        presentationGeneration = generation
        let eligible = notes.values.filter { metadata.notes[$0.id]?.isOpen == true }.sorted {
            let lhs = metadata.notes[$0.id]?.focusOrder ?? 0
            let rhs = metadata.notes[$1.id]?.focusOrder ?? 0
            return lhs == rhs ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : lhs > rhs
        }
        guard let selected = eligible.first else { showList?(); return }
        let ordered = Array(eligible.reversed())
        let guards = ordered.map { note in
            let editor = windows[note.id]?.editor
            return (note, editor?.state.currentRevision, editor?.positionRevision)
        }
        var flushFailures: [NoteID: Error] = [:]
        for note in ordered {
            guard let editor = windows[note.id]?.editor, editor.state.hasUnsavedEdits else { continue }
            do { try await editor.flush() } catch { flushFailures[note.id] = error }
        }
        let results: [NoteID: Result<NoteSnapshot, Error>]
        do {
            results = try await store.verifyForPresentation(ordered.filter { flushFailures[$0.id] == nil })
        } catch {
            guard presentationGeneration == generation else { return }
            results = Dictionary(ordered.map { ($0.id, .failure(error)) }, uniquingKeysWith: { lhs, _ in lhs })
        }
        for (note, revision, positionRevision) in guards {
            guard presentationGeneration == generation else { return }
            let result = flushFailures[note.id].map { .failure($0) } ?? results[note.id]
            guard let result else { continue }
            presentVerified(note, result: result, focus: note.id == selected.id, generation: generation,
                            revision: revision, positionRevision: positionRevision)
        }
    }

    func open(_ note: NoteSnapshot, new: Bool = false, focus: Bool = true) {
        presentationGeneration = UUID()
        present(note, new: new, focus: focus)
    }

    private func present(_ note: NoteSnapshot, new: Bool = false, focus: Bool = true) {
        guard note.availability != .trashed,
              note.availability == .available || retainedEdits[note.id] != nil else { showList?(); return }
        folderState.apply(.changed(note))
        if metadata.notes[note.id] == nil { metadata.notes[note.id] = NoteWindowMetadata(isOpen: new) }
        metadata.notes[note.id]?.isOpen = true
        let controller: NoteWindowController
        if let existing = windows[note.id] { controller = existing }
        else {
            // The editor takes a retained buffer once. Later opens read the store's snapshot.
            controller = NoteWindowController(editor: NoteEditorController(note: note, store: store, settings: settings, restoredEdit: retainedEdits.removeValue(forKey: note.id)))
            for token in editingLocks { controller.editor.beginEditingLock(token) }
            controller.setBackgroundTone(metadata.notes[note.id]?.backgroundTone)
            controller.backgroundToneChanged = { [weak self] tone in
                self?.metadata.notes[note.id]?.backgroundTone = tone
                self?.toneChanged?()
            }
            controller.editor.setFontSize(metadata.notes[note.id]?.fontSize)
            controller.editor.fontSizeChanged = { [weak self] size in
                self?.metadata.notes[note.id]?.fontSize = size
                self?.changed?()
            }
            if let window = controller.window {
                let saved = metadata.notes[note.id]
                let initial = saved?.frame ?? CGRect(x: 180 + windows.count * 24, y: 180 + windows.count * 24, width: 560, height: 460)
                window.setFrame(placement(initial, displayID: saved?.displayID), display: false)
                window.level = settings.alwaysOnTop ? .floating : .normal
            }
            if let position = metadata.notes[note.id]?.editorPosition {
                controller.editor.restorePosition(position)
            }
            windows[note.id] = controller
            controller.hideRequested = { [weak self] in self?.closeNote(note.id) }
            controller.deleteRequested = { [weak self] in self?.deleteNote?(note.id) }
            controller.newRequested = { [weak self] in self?.createNote?() }
            controller.listRequested = { [weak self] in self?.showList?() }
            controller.geometryChanged = { [weak self] in self?.scheduleGeometry(note.id) }
            controller.editor.localTextEdited = { [weak self, weak controller] revision in
                guard let self, let note = controller?.editor.note,
                      self.metadata.notes[note.id]?.externalChangeNoticeAt != nil else { return }
                if self.noticeEdits[note.id]?.token != note.collectionToken ||
                    self.noticeEdits[note.id]?.location != note.locationRevision {
                    self.noticeEdits[note.id] = (revision, note.collectionToken, note.locationRevision)
                }
            }
            controller.editor.positionChanged = { [weak self] in self?.scheduleGeometry(note.id) }
            controller.focusLost = { [weak self] in self?.captureGeometry(note.id) }
            controller.focused = { [weak self] in self?.recordFocus(note.id) }
            controller.editor.textView.escape = { [weak self] in self?.perform(.escape(transientActive: false)) }
            (controller.window as? GroupWindow)?.escape = { [weak self] in self?.perform(.escape(transientActive: false)) }
            configureRecovery?(controller)
        }
        if let window = controller.window {
            let reachable = placement(window.frame, displayID: displayID(window.screen))
            if window.frame != reachable { window.setFrame(reachable, display: true) }
        }
        controller.setExternalChangeNotice(metadata.notes[note.id]?.externalChangeNoticeAt)
        controller.defaultFolder = defaultFolder
        controller.applyInterfaceScale(1.0)
        if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
        if focus {
            requestedFocus = note.id
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            recordFocus(note.id)
        } else { controller.window?.orderFront(nil) }
        openStateChanged?()
        changed?()
    }
    func focusAdjacentNote(backward: Bool, from currentWindow: NSWindow?) {
        // Window number is creation order, which focus changes don't affect.
        let candidates = windows.values.compactMap(\.window)
            .filter { $0.isVisible && !$0.isMiniaturized }
            .sorted { $0.windowNumber < $1.windowNumber }
        guard !candidates.isEmpty, !candidates.contains(where: { $0.attachedSheet != nil }) else { return }
        let current = candidates.firstIndex { $0 === currentWindow }
        let target = current.map { ($0 + (backward ? candidates.count - 1 : 1)) % candidates.count }
            ?? (backward ? candidates.count - 1 : 0)
        let window = candidates[target]
        window.makeKeyAndOrderFront(nil)
        if let id = windows.first(where: { $0.value.window === window })?.key {
            requestedFocus = id
            recordFocus(id)
        }
    }
    func inheritRecoveryTone(_ notice: RecoveryNotice) {
        guard metadata.notes[notice.recoveryNoteID] == nil else { return }
        let source = notice.sourceNoteID
            ?? notes.values.first(where: { $0.fileURL == notice.originalURL })?.id
            ?? metadata.notes.first(where: { $0.value.lastKnownPath == notice.originalURL.path })?.key
        var value = NoteWindowMetadata(isOpen: true)
        value.backgroundTone = source.flatMap { metadata.notes[$0]?.backgroundTone }
        metadata.notes[notice.recoveryNoteID] = value
    }

    /// Undoes `inheritRecoveryTone` for a notice the store no longer holds.
    func releaseRecoveryTone(_ notice: RecoveryNotice) {
        metadata.notes[notice.recoveryNoteID]?.backgroundTone = nil
    }

    private func displayID(_ screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func placement(_ frame: CGRect?, displayID: UInt32?) -> CGRect {
        let displays = NSScreen.screens.compactMap { screen -> WindowDisplay? in
            guard let id = self.displayID(screen) else { return nil }
            return WindowDisplay(id: id, visibleFrame: screen.visibleFrame)
        }
        return WindowPlacement.restore(frame: frame, displayID: displayID, displays: displays, currentDisplayID: self.displayID(NSScreen.main))
    }
    private func scheduleGeometry(_ id: NoteID) {
        geometryTasks[id]?.cancel()
        geometryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.captureGeometry(id)
        }
    }
    func captureGeometry(_ id: NoteID) {
        // A window kept for unsaved edits after `.removed` must not write its entry back.
        guard notes[id] != nil, let window = windows[id]?.window else { return }
        if let position = windows[id]?.editor.editorPosition,
           metadata.notes[id]?.acceptedFileModifiedAt == nil || position.fileModifiedAt == metadata.notes[id]?.acceptedFileModifiedAt {
            metadata.notes[id]?.editorPosition = position
        }
        metadata.notes[id]?.frame = window.frame
        metadata.notes[id]?.displayID = displayID(window.screen)
        changed?()
    }
    func captureAllGeometry() { for id in windows.keys { geometryTasks[id]?.cancel(); captureGeometry(id) } }
    func displaysChanged() {
        for (id, controller) in windows {
            guard let window = controller.window else { continue }
            let frame = placement(window.frame, displayID: metadata.notes[id]?.displayID)
            if window.frame != frame { window.setFrame(frame, display: true) }
            captureGeometry(id)
        }
    }
    var anyGroupVisible: Bool {
        listVisible() || windows.values.contains { $0.window?.isVisible == true }
    }
    func perform(_ action: Action) {
        switch action {
        case .toggle: perform(anyGroupVisible ? .hide : .reveal)
        case .hide:
            presentationGeneration = UUID()
            captureAllGeometry()
            // Ordering out the key window can briefly make another note key.
            // That platform handoff must not replace the user’s last focused note.
            hidingGroup = true
            defer { hidingGroup = false }
            for controller in windows.values { controller.window?.orderOut(nil) }
            hideList?()
        case let .escape(transientActive):
            guard !transientActive, NSApp.modalWindow == nil,
                  !windows.values.contains(where: { $0.window?.attachedSheet != nil }) else { return }
            perform(.hide)
        case .reveal:
            let eligible = notes.values.filter { metadata.notes[$0.id]?.isOpen == true }.sorted {
                let lhs = metadata.notes[$0.id]?.focusOrder ?? 0
                let rhs = metadata.notes[$1.id]?.focusOrder ?? 0
                return lhs == rhs ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : lhs > rhs
            }
            guard let selected = eligible.first else { showList?(); return }
            for note in eligible { open(note, focus: false) }
            open(selected)
        }
    }
    private func recordFocus(_ id: NoteID) {
        guard !hidingGroup else { return }
        presentationGeneration = UUID()
        captureGeometry(id)
        if !focusSeeded { focusCounter = max(focusCounter, metadata.notes.values.map(\.focusOrder).max() ?? 0) }
        focusCounter += 1
        metadata.notes[id]?.focusOrder = focusCounter
        focusSeeded = true
        changed?()
    }
    func closeNote(_ id: NoteID) {
        presentationGeneration = UUID()
        // A repeated ⌘W, Escape, or click must not start a second flush.
        guard let controller = windows[id], closing.insert(id).inserted else { return }
        Task {
            defer { closing.remove(id) }
            do {
                try await controller.editor.flush()
                await finishClose(id, controller)
            } catch { controller.showBlocker(error) }
        }
    }
    /// The user confirmed losing the text that could not be saved.
    func closeWithoutSaving(_ id: NoteID) {
        presentationGeneration = UUID()
        guard let controller = windows[id], closing.insert(id).inserted else { return }
        Task {
            defer { closing.remove(id) }
            do {
                try await controller.editor.discardUnsavedEdits()
                retainedEdits[id] = nil
                await finishClose(id, controller)
            } catch { controller.showBlocker(error) }
        }
    }
    private func finishClose(_ id: NoteID, _ controller: NoteWindowController) async {
        captureGeometry(id)
        metadata.notes[id]?.isOpen = false
        controller.window?.close()
        windows[id] = nil
        await store.pruneStatus(id)
        geometryTasks[id]?.cancel()
        geometryTasks[id] = nil
        openStateChanged?()
        changed?()
    }
    private func closeTrashedWindow(_ id: NoteID) {
        captureGeometry(id)
        geometryTasks[id]?.cancel()
        geometryTasks[id] = nil
        windows[id]?.window?.orderOut(nil)
        windows[id] = nil
        metadata.notes[id]?.isOpen = false
        retainedEdits[id] = nil
        noticeEdits[id] = nil
        openStateChanged?()
        changed?()
    }

    /// Handles the store's `.removed`. Window state always goes; a window with unsaved edits
    /// stays open until recovery finishes.
    func noteRemoved(_ id: NoteID) {
        guard windows[id]?.editor.state.hasUnsavedEdits == true else { remove(id); return }
        metadata.notes[id] = nil
        changed?()
    }
    func remove(_ id: NoteID) { geometryTasks[id]?.cancel(); geometryTasks[id] = nil; windows[id]?.window?.orderOut(nil); windows[id] = nil; if let token = notes[id]?.collectionToken { folderState.apply(.removed(id, token)) }; metadata.notes[id] = nil; retainedEdits[id] = nil; noticeEdits[id] = nil; openStateChanged?(); changed?() }
    func reset() {
        presentationGeneration = UUID()
        for task in geometryTasks.values { task.cancel() }
        geometryTasks.removeAll()
        for controller in windows.values { controller.window?.orderOut(nil) }
        windows.removeAll()
        folderState.replace(with: [:])
        retainedEdits.removeAll()
        noticeEdits.removeAll()
        metadata = CollectionMetadata()
    }
    /// Locks outlive reset, so editors opened during a folder change get them too.
    @discardableResult
    func beginEditingLock() -> UUID {
        let token = UUID()
        editingLocks.insert(token)
        for controller in windows.values { controller.editor.beginEditingLock(token) }
        return token
    }
    func endEditingLock(_ token: UUID) {
        editingLocks.remove(token)
        for controller in windows.values { controller.editor.endEditingLock(token) }
    }
    func flushForDefaultFolderChange() async throws {
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        for editor in windows.values.map(\.editor) { try await editor.flushForDefaultFolderChange() }
        try await store.flush()
    }
    func flush() async throws {
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        let editors = windows.values.map(\.editor)
        for editor in editors { try await editor.flush() }
        try await store.flush()
    }

    /// Delivers every editor buffer, then saves. A journaled edit that cannot be saved does not block Quit.
    func flushForQuit() async throws {
        let lock = beginEditingLock()
        defer { endEditingLock(lock) }
        for editor in windows.values.map(\.editor) { try await editor.deliverForQuit() }
        try await store.flushForQuit()
    }
}
