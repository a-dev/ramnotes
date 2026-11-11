import ramnotesDomain
import AppKit
import Darwin

/// Presents location actions. The storage and editor owners check and apply every change.
@MainActor
final class NoteLocationController: NSWindowController, NSWindowDelegate {
    let basename = NSTextField()
    let folderLabel = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    private(set) var destinationFolder: URL
    private let available: Bool
    private let original: URL
    private let defaultFolder: URL
    private let isCustomPath: Bool
    private let submit: (URL) async throws -> Void
    private let dismissed: () -> Void
    private var busy = false
    private var finished = false
    private var controls: [NSControl] = []

    init(file: URL, defaultFolder: URL, isCustomPath: Bool? = nil, available: Bool = true, removable: Bool = false, accessFailure: NoteAccessFailure? = nil, allowAccess: @escaping () -> Void = {}, showInFinder: (() -> Void)? = nil, saveCopy: @escaping () -> Void = {}, submit: @escaping (URL) async throws -> Void,
         locate: @escaping () -> Void = {}, remove: @escaping () -> Void = {},
         dismissed: @escaping () -> Void) {
        self.available = available
        original = file
        destinationFolder = file.deletingLastPathComponent()
        self.defaultFolder = defaultFolder
        self.isCustomPath = isCustomPath ?? !NoteLocationPresentation.isDefault(file, folder: defaultFolder)
        self.submit = submit
        self.dismissed = dismissed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = String(localized: "Note location", comment: "Title of the panel that shows or changes where a note file is stored")
        window.isReleasedWhenClosed = false
        window.delegate = self
        basename.stringValue = file.deletingPathExtension().lastPathComponent
        basename.setAccessibilityLabel(String(localized: "Filename without .txt extension", comment: "Accessibility label of the filename field. Keep .txt unchanged"))
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateFolder()
        let name = NSStackView(views: [basename, NSTextField(labelWithString: ".txt")])
        let folder = NSStackView(views: [folderLabel])
        folder.distribution = .fill
        let cancel = ActionButton(String(localized: "Cancel", comment: "Button that dismisses a dialog without acting")) { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        let save = ActionButton(String(localized: "Save", comment: "Button in the Note location panel that renames the note file")) { [weak self] in self?.save() }
        save.keyEquivalent = "\r"
        let moveDefault = ActionButton(String(localized: "Move to default", comment: "Button in the Note location panel that moves the note into the default notes folder")) { [weak self] in self?.save(toDefault: true) }
        moveDefault.isEnabled = !NoteLocationPresentation.isDefault(file, folder: defaultFolder)
        let buttons = NSStackView(views: [moveDefault, NSView(), cancel, save])
        let customActions = NSStackView(views: [
            ActionButton(String(localized: "Show in Finder", comment: "Button that reveals the note file in Finder. Use the system term for Finder")) {
                if let showInFinder { showInFinder() }
                else { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            },
            ActionButton(String(localized: "Save a Copy…", comment: "Button that saves the text to a new file")) { [weak self] in self?.close(); saveCopy() }
        ])
        let recovery = NSStackView(views: [
            ActionButton(String(localized: "Locate File…", comment: "Button that lets the user pick the file for an unavailable note")) { [weak self] in self?.close(); locate() }
        ])
        if removable {
            recovery.addArrangedSubview(ActionButton(String(localized: "Remove from List", comment: "Button that removes an unavailable note from the list without deleting files")) { [weak self] in self?.close(); remove() })
        }
        if let failure = accessFailure {
            if failure.reason != .missingFile {
                recovery.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Locate File…", comment: "Button that lets the user pick the file for an unavailable note") }?.isHidden = true
            }
            switch failure.reason {
            case .folderAuthorization, .staleBookmark:
                recovery.insertArrangedSubview(ActionButton(String(localized: "Restore File Access…", comment: "Button that asks the user to grant access to the notes folder again")) { [weak self] in self?.close(); allowAccess() }, at: 0)
            case .missingFile:
                break
            case .unavailableVolume, .cloudPlaceholder, .permission, .unsupportedEncoding, .unknown:
                break
            }
        }
        recovery.spacing = 8
        recovery.isHidden = available
        message.textColor = .systemRed
        message.setAccessibilityLabel(String(localized: "Location error", comment: "Accessibility label of the error message in the Note location panel"))
        message.isHidden = true
        let folderHeading = NSTextField(labelWithString: String(localized: "Folder", comment: "Heading above the folder path in the Note location panel"))
        let filenameHeading = NSTextField(labelWithString: String(localized: "Filename", comment: "Heading above the filename field in the Note location panel"))
        for heading in [folderHeading, filenameHeading] {
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.textColor = .labelColor
        }
        folderLabel.textColor = .secondaryLabelColor
        let content = NSStackView(views: self.isCustomPath
            ? [folderHeading, folderLabel, customActions, message, recovery, cancel]
            : [folderHeading, folder, filenameHeading, name, message, recovery, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.setCustomSpacing(6, after: folderHeading)
        if !self.isCustomPath { content.setCustomSpacing(6, after: filenameHeading) }
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        window.contentView = content
        if self.isCustomPath {
            folderLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
            customActions.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        } else {
            for row in [folder, name, buttons] { row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true }
        }
        message.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        controls = self.isCustomPath ? [cancel] : [basename, cancel, save, moveDefault]
        if self.isCustomPath { filenameHeading.isHidden = true; name.isHidden = true; buttons.isHidden = true }
        if !available {
            for control in [basename, save, moveDefault] { control.isEnabled = false }
            save.isHidden = true
            moveDefault.isHidden = true
            cancel.title = String(localized: "Close", comment: "Button that closes the panel (verb)")
            showMessage(removable ? String(localized: "RAMnotes cannot find this file. Removing this entry does not delete any files.", comment: "Message in the Note location panel for a missing file. Keep the product name RAMnotes unchanged.") : accessFailure.map { String(localized: $0.message) } ?? String(localized: "This note is unavailable. Locate the file, or wait for it to become available.", comment: "Message in the Note location panel when no more specific reason is known"))
        }
        if self.isCustomPath {
            folderLabel.stringValue = NoteLocationPresentation.path(file)
            folderLabel.setAccessibilityLabel(String(localized: "Current file path: \(PathIsolation.isolate(NoteLocationPresentation.path(file)))", comment: "Accessibility label of the file path in the Note location panel. The value is a file path"))
            folderLabel.toolTip = NoteLocationPresentation.path(file)
        }
        fitContent()
        window.initialFirstResponder = available && !self.isCustomPath ? basename : cancel
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    private func updateFolder() {
        folderLabel.stringValue = NoteLocationPresentation.path(destinationFolder)
        folderLabel.toolTip = NoteLocationPresentation.path(destinationFolder)
        folderLabel.setAccessibilityLabel(String(localized: "Destination folder: \(PathIsolation.isolate(NoteLocationPresentation.path(destinationFolder)))", comment: "Accessibility label of the destination folder in the Note location panel. The value is a folder path"))
    }
    private func fitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: content.fittingSize.height))
    }
    private func showMessage(_ text: String) {
        message.stringValue = text
        message.isHidden = text.isEmpty
        fitContent()
    }
    func save(toDefault: Bool = false) {
        guard !busy, available else { return }
        let filename = Self.filename(draft: basename.stringValue, original: original)
        if !toDefault {
            guard NoteFilename(filename) != nil else {
                showMessage(NoteOperationError.invalidFilename.localizedDescription)
                return
            }
        }
        let target = toDefault ? defaultFolder.appendingPathComponent(original.lastPathComponent)
            : destinationFolder.appendingPathComponent(filename)
        guard isCustomPath == false else { return }
        busy = true
        controls.forEach { $0.isEnabled = false }
        showMessage(String(localized: "Saving location…", comment: "Status in the Note location panel while the file is being renamed or moved"))
        Task { [self] in
            do { try await submit(target); busy = false; close() }
            catch {
                busy = false
                controls.forEach { $0.isEnabled = true }
                // The default note remains in its authorized folder after a failed rename.
                showMessage(error.localizedDescription)
                window?.makeFirstResponder(basename)
            }
        }
    }
    static func filename(draft: String, original: URL) -> String {
        if draft == original.deletingPathExtension().lastPathComponent { return original.lastPathComponent }
        // Accept a pasted full filename without duplicating the fixed extension.
        return draft.lowercased().hasSuffix(".txt") ? draft : draft + ".txt"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        dismissed()
    }
}

@MainActor
enum DefaultFolderConfirmation {
    static func make(destination: URL) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Change default notes folder?", comment: "Confirmation title before changing the default notes folder")
        alert.informativeText = String(localized: "\(PathIsolation.isolate(NoteLocationPresentation.path(destination)))\nNotes with custom paths won’t be moved.", comment: "Confirmation text for changing the default folder. The first line is the new folder path, then a line break, then the note about custom-path notes")
        alert.addButton(withTitle: String(localized: "Change Folder", comment: "Confirmation button that changes the default notes folder"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button that dismisses a dialog without acting"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Move existing notes to the new location", comment: "Checkbox in the default folder confirmation")
        alert.suppressionButton?.state = .on
        return alert
    }
}
