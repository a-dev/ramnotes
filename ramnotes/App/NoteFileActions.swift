import ramnotesDomain
import AppKit

/// What file actions need from the app. Read at each step, so actions see a folder switch
/// or reload that happens mid-action.
@MainActor
protocol NoteFileActionsHost: AnyObject {
    var store: NoteStore? { get }
    var locationWorkflow: LocationWorkflow? { get }
    var folder: FolderSelection? { get }
    var windows: WindowCoordinator? { get }
    var folderState: FolderState { get }
    /// Hosts the Add Existing Files results sheet, for both the menu command and a drop.
    var noteListWindow: NSWindow? { get }
    /// Quitting or a folder transaction is in progress.
    var fileActionsBlocked: Bool { get }
    func refreshList()
    /// Refreshes before returning, so a following list selection sees the new rows.
    func refreshListNow()
    func adoptRetainedRecovery(_ edits: [RetainedEditSummary])
}

/// Presents file actions: location, access renewal, relinking, removal, registration, Move To,
/// and Save a Copy. Panels, focus return, and error rendering live here; transaction sequencing
/// stays in `LocationWorkflow` and `NoteStore`.
@MainActor
final class NoteFileActions {
    weak var host: NoteFileActionsHost?
    private let discovery: NoteListController
    private var store: NoteStore? { host?.store }
    private var locations: LocationWorkflow? { host?.locationWorkflow }
    private var folder: FolderSelection? { host?.folder }
    private var windows: WindowCoordinator? { host?.windows }
    private var blocked: Bool { host?.fileActionsBlocked ?? true }
    private var notes: [NoteID: NoteSnapshot] { host?.folderState.notes ?? [:] }

    init(discovery: NoteListController) {
        self.discovery = discovery
    }

    private(set) var locationController: NoteLocationController?
    private var unavailableActions: Set<NoteID> = []
    private var locationRetry: [NoteID: UUID] = [:]
    private var locationDismissedCallback: (() -> Void)?
    func showLocation(_ note: NoteSnapshot, onDismiss: (() -> Void)? = nil) {
        guard !blocked, let store, let folder else { return }
        if notes[note.id]?.availability == .available {
            moveNote(note, onDismiss: onDismiss)
            return
        }
        if let locationController {
            locationDismissedCallback = onDismiss
            locationController.showWindow(nil)
            return
        }
        locationDismissedCallback = onDismiss
        let controller = NoteLocationController(file: note.fileURL, defaultFolder: folder.url, available: notes[note.id]?.availability == .available, removable: notes[note.id]?.availability == .missingOriginal,
            accessFailure: notes[note.id]?.accessFailure, allowAccess: { [weak self] in self?.allowFolderAccess(note) }, saveCopy: { [weak self] in self?.saveCopy(note) },
            submit: { [weak self] target in
                guard let self, !self.blocked else { throw NoteOperationError.unavailable }
                guard let locations = self.locations else { throw NoteOperationError.unavailable }
                let result = try await locations.move(note, to: target, retry: self.locationRetry[note.id],
                    editor: self.windows?.windows[note.id]?.editor)
                switch result.outcome {
                case .moved, .unchanged: self.locationRetry[note.id] = nil
                case .failed(let error): throw error
                case .interrupted(let id):
                    self.locationRetry[note.id] = id
                    throw NoteOperationError.locationChangeInterrupted(underlying: result.error?.localizedDescription)
                }
                self.host?.folderState.replace(with: await store.records)
                self.host?.refreshList()
            },
            locate: { [weak self] in self?.locateNote(note) },
            remove: { [weak self] in self?.removeUnavailable(note) },
            dismissed: { [weak self] in
                self?.locationController = nil
                self?.discovery.returnFocus(to: note.id)
                let callback = self?.locationDismissedCallback
                self?.locationDismissedCallback = nil
                callback?()
            })
        locationController = controller
        controller.showWindow(nil)
    }
    func allowFolderAccess(_ note: NoteSnapshot) {
        guard !blocked, let store, unavailableActions.insert(note.id).inserted else { return }
        let origin = NSApp.keyWindow
        let returnFocus = { [weak self, weak origin] in
            if let origin, origin.isVisible { origin.makeKeyAndOrderFront(nil) }
            else { self?.discovery.returnFocus(to: note.id) }
        }
        let picker = NSOpenPanel()
        picker.title = String(localized: "Restore File Access", comment: "Title of the file panel that asks the user to select a note file again")
        picker.message = String(localized: "Select \(PathIsolation.isolate(note.fileURL.lastPathComponent)) to let RAMnotes read and save this note.", comment: "Message in a file panel. The value is a file name. Keep the product name RAMnotes unchanged.")
        picker.prompt = String(localized: "Allow Access", comment: "Button of the file panel that grants access to the selected note file")
        picker.directoryURL = note.fileURL.deletingLastPathComponent()
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else {
            unavailableActions.remove(note.id)
            returnFocus()
            return
        }
        Task {
            defer { unavailableActions.remove(note.id); returnFocus() }
            do {
                guard let locations else { throw NoteOperationError.unavailable }
                _ = try await locations.renewAccess(note, at: url, editor: windows?.windows[note.id]?.editor)
                // The repair saves or promotes retained text, so reload records like Locate File does.
                host?.adoptRetainedRecovery(await store.retainedRecovery().edits)
                host?.folderState.replace(with: await store.records)
                host?.refreshList()
            } catch { showLocationError(error, title: String(localized: "Cannot restore file access", comment: "Title of the alert shown when Restore File Access fails")) }
        }
    }
    func locateNote(_ note: NoteSnapshot) {
        guard !blocked, let store else { return }
        guard unavailableActions.insert(note.id).inserted else { return }
        let origin = NSApp.keyWindow
        let returnFocus = { [weak self, weak origin] in
            if let origin, origin.isVisible { origin.makeKeyAndOrderFront(nil) }
            else { self?.discovery.returnFocus(to: note.id) }
        }
        var locateStarted = false
        defer { if !locateStarted { unavailableActions.remove(note.id); returnFocus() } }
        let picker = NSOpenPanel()
        picker.title = String(localized: "Locate file", comment: "Title of the file panel for choosing the file of an unavailable note")
        picker.message = String(localized: "Select the note’s .txt file. Selecting a different file links this note to that file. Retained edits remain available in recovery.", comment: "Message in the Locate file panel. Keep .txt unchanged")
        picker.prompt = String(localized: "Locate", comment: "Button of the Locate file panel that links the note to the selected file (verb)")
        picker.directoryURL = note.fileURL.deletingLastPathComponent()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        locateStarted = true
        Task {
            defer { unavailableActions.remove(note.id); returnFocus() }
            do {
                guard let locations else { throw NoteOperationError.unavailable }
                _ = try await locations.relink(note, to: url, editor: windows?.windows[note.id]?.editor)
                host?.adoptRetainedRecovery(await store.retainedRecovery().edits)
                host?.folderState.replace(with: await store.records)
                host?.refreshList()
            } catch { showLocationError(error) }
        }
    }
    func removeUnavailable(_ note: NoteSnapshot) {
        guard !blocked, let store, unavailableActions.insert(note.id).inserted else { return }
        Task {
            defer { unavailableActions.remove(note.id) }
            do {
                guard let locations else { throw NoteOperationError.unavailable }
                try await locations.removeTracking(note, editor: windows?.windows[note.id]?.editor)
                host?.adoptRetainedRecovery(await store.retainedRecovery().edits)
                host?.folderState.replace(with: await store.records)
                host?.refreshList()
            } catch {
                showLocationError(error, title: String(localized: "Cannot remove from list", comment: "Title of the alert shown when Remove from List fails"))
            }
        }
    }
    /// Removes each note in turn and reports every failure in one alert.
    func removeUnavailable(_ batch: [NoteSnapshot]) {
        guard !blocked, let store else { return }
        let claimed = batch.filter { unavailableActions.insert($0.id).inserted }
        guard !claimed.isEmpty else { return }
        Task {
            defer { claimed.forEach { unavailableActions.remove($0.id) } }
            var failures: [String] = []
            for note in claimed {
                do {
                    guard let locations else { throw NoteOperationError.unavailable }
                    try await locations.removeTracking(note, editor: windows?.windows[note.id]?.editor)
                } catch {
                    failures.append(String(localized: "\(PathIsolation.isolate(note.fileURL.lastPathComponent)): \(error.localizedDescription)", comment: "Line in the Remove from List results. First value is a file name, second is the error"))
                }
            }
            host?.adoptRetainedRecovery(await store.retainedRecovery().edits)
            host?.folderState.replace(with: await store.records)
            host?.refreshList()
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.messageText = String(localized: "Cannot remove from list", comment: "Title of the alert shown when Remove from List fails")
                alert.informativeText = failures.joined(separator: "\n")
                alert.runModal()
            }
        }
    }
    private func showLocationError(_ error: Error, title: String = String(localized: "Cannot change note location", comment: "Title of the alert shown when moving or relinking a note fails")) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func addExistingFiles() {
        guard discovery.actionsAllowed() else { return }
        let picker = NSOpenPanel()
        picker.title = String(localized: "Add Existing Files", comment: "Title of the file panel for adding text files")
        picker.message = String(localized: "Add .txt files in place.", comment: "Message in the Add Existing Files panel: files stay where they are. Keep .txt unchanged")
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = [.plainText]
        guard picker.runModal() == .OK else { return }
        registerExistingFiles(picker.urls)
    }

    func registerExistingFiles(_ urls: [URL]) {
        guard discovery.actionsAllowed(), let store, let folder else { return }
        Task {
            let results = await store.registerFiles(urls, collectionToken: folder.collectionToken)
            host?.folderState.replace(with: await store.records)
            host?.refreshListNow()
            let added = results.compactMap { result -> NoteID? in
                guard !result.alreadyRegistered, case let .success(note) = result.outcome else { return nil }
                return note.id
            }
            discovery.selectRegisteredFiles(ids: added)
            let failures = results.compactMap { result -> String? in
                if case let .failure(error) = result.outcome { return String(localized: "\(PathIsolation.isolate(result.url.lastPathComponent)): \(error.localizedDescription)", comment: "Line in the Add Existing Files results. First value is a file name, second is the system error") }
                return nil
            }
            let duplicates = results.filter(\.alreadyRegistered).map { String(localized: "\(PathIsolation.isolate($0.url.lastPathComponent)): Already registered.", comment: "Line in the Add Existing Files results. The value is a file name") }
            if !failures.isEmpty || !duplicates.isEmpty {
                let alert = NSAlert()
                alert.messageText = String(localized: "Add Existing Files Results", comment: "Title of the alert that lists files that could not be added")
                alert.informativeText = (failures + duplicates).joined(separator: "\n")
                alert.alertStyle = .informational
                if let window = host?.noteListWindow {
                    if !window.isVisible { window.makeKeyAndOrderFront(nil) }
                    await alert.beginSheetModal(for: window)
                } else { alert.runModal() }
            }
        }
    }

    func moveNote(_ note: NoteSnapshot, onDismiss: (() -> Void)? = nil) {
        guard discovery.actionsAllowed(), let store, let locations,
              unavailableActions.insert(note.id).inserted else { return }
        Task { @MainActor in
            let pending = await store.unfinishedLocationOperations().first { $0.noteID == note.id }
            let destination: URL
            if let pending, let name = pending.destinationName {
                destination = pending.destination.scope == .file ? pending.destination.url
                    : pending.destination.url.appendingPathComponent(name)
            } else { destination = note.fileURL }
            let noteWindow = windows?.windows[note.id]?.window
            let origin = NSApp.keyWindow ?? noteWindow
            let picker = NSSavePanel()
            picker.title = String(localized: "Move To", comment: "Title of the save panel for moving a note")
            picker.prompt = String(localized: "Move", comment: "Button of the Move To panel that moves the note file (verb)")
            let explanation = NSTextField(wrappingLabelWithString:
                String(localized: "Choose a name and location for this note. The original file will be moved, and the note will stay open.", comment: "Explanation shown in the Move To panel"))
            explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            explanation.textColor = .secondaryLabelColor
            explanation.alignment = .natural
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 54))
            accessory.autoresizingMask = [.width]
            explanation.translatesAutoresizingMaskIntoConstraints = false
            accessory.addSubview(explanation)
            NSLayoutConstraint.activate([
                explanation.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 20),
                explanation.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -20),
                explanation.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 12),
                explanation.bottomAnchor.constraint(equalTo: accessory.bottomAnchor, constant: -12)
            ])
            picker.accessoryView = accessory
            picker.nameFieldStringValue = destination.lastPathComponent
            picker.directoryURL = destination.deletingLastPathComponent()
            picker.allowedContentTypes = [.plainText]
            picker.canCreateDirectories = true
            let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                Task { @MainActor in
                    defer {
                        self.unavailableActions.remove(note.id)
                        if let origin, origin.isVisible { origin.makeKeyAndOrderFront(nil) }
                        else { self.discovery.returnFocus(to: note.id) }
                        onDismiss?()
                    }
                    guard response == .OK, let target = picker.url else { return }
                    do {
                        if pending != nil, target.standardizedFileURL != destination.standardizedFileURL {
                            throw NoteOperationError.unfinishedMove(destination: destination)
                        }
                        let destinationGrant = try await store.acquireDestinationFile(target)
                        defer { withExtendedLifetime(destinationGrant) {} }
                        let result = try await locations.move(note, to: target, retry: pending?.id,
                            editor: self.windows?.windows[note.id]?.editor)
                        switch result.outcome {
                        case .moved, .unchanged: self.locationRetry[note.id] = nil
                        case .failed(let error): throw error
                        case .interrupted(let id):
                            self.locationRetry[note.id] = id
                            throw NoteOperationError.moveInterrupted(underlying: result.error?.localizedDescription)
                        }
                        self.host?.folderState.replace(with: await store.records)
                        self.host?.refreshList()
                    } catch { self.showLocationError(error) }
                }
            }
            if let origin {
                origin.makeKeyAndOrderFront(nil)
                picker.beginSheetModal(for: origin, completionHandler: complete)
            }
            else { picker.begin(completionHandler: complete) }
        }
    }

    func saveCopy(_ note: NoteSnapshot) {
        guard discovery.actionsAllowed(), let store, unavailableActions.insert(note.id).inserted else { return }
        let origin = NSApp.keyWindow
        let picker = NSSavePanel()
        picker.title = String(localized: "Save a Copy", comment: "Title of the save panel for saving a copy of a note")
        let base = note.fileURL.deletingPathExtension().lastPathComponent
        picker.nameFieldStringValue = String(localized: "\(base) copy", comment: "Suggested filename for Save a Copy; value is the original name without extension") + ".txt"
        picker.allowedContentTypes = [.plainText]
        let finish = { [weak self, weak origin] (refocus: Bool) in
            self?.unavailableActions.remove(note.id)
            guard refocus else { return }
            if let origin, origin.isVisible { origin.makeKeyAndOrderFront(nil) }
            else { self?.discovery.returnFocus(to: note.id) }
        }
        guard picker.runModal() == .OK, let url = picker.url else { finish(true); return }
        Task {
            var opened = false
            defer { finish(!opened) }
            do {
                let copy: NoteSnapshot
                if let editor = windows?.windows[note.id]?.editor {
                    copy = try await editor.saveCopy(to: url)
                } else {
                    let retained = try await store.copySource(note.id, collectionToken: note.collectionToken)
                    guard retained.note.locationRevision == note.locationRevision else { throw NoteOperationError.staleLocation }
                    let grant = try await store.acquireDestinationFile(url)
                    copy = try await store.createCopy(from: retained.note, editRevision: retained.editRevision,
                        text: retained.text, to: grant)
                }
                host?.folderState.replace(with: await store.records)
                host?.refreshListNow()
                discovery.selectRegisteredFiles(ids: [copy.id])
                // Continue in the copy, which now holds the text.
                windows?.open(copy)
                opened = true
            } catch { showLocationError(error) }
        }
    }
}
