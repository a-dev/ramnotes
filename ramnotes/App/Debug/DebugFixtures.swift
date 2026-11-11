import ramnotesDomain
import AppKit
import Synchronization

#if DEBUG
/// Pause storage at the selected stage until force quit. The session marker records which stage the store reached.
enum StoragePauseFixture {
    static func fault(stage name: String, support: URL) -> StorageFault {
        guard let target = StorageStage.allCases.first(where: { String(describing: $0) == name }) else {
            NSLog("--test-pause-at: unknown stage %@", name)
            return { _ in }
        }
        let reached = Mutex(false)
        return { stage in
            guard stage == target, reached.withLock({ old in defer { old = true }; return !old }) else { return }
            let marker = support.appendingPathComponent("paused-at-\(name)")
            FileManager.default.createFile(atPath: marker.path, contents: Data(Date().description.utf8))
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Paused at storage stage “\(name)”"
                alert.informativeText = "Test fixture. Force quit RAMnotes now."
                alert.runModal()
            }
            while true { sleep(60) }
        }
    }
}

/// Pause the first Finder export before verification. Reconciliation continues while the sheet waits for Continue.
@MainActor
final class ExportPauseFixture {
    private var used = false

    func wait() async {
        guard !used, let window = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet == nil && $0.canBecomeKey }) else { return }
        used = true
        let alert = NSAlert()
        alert.messageText = "Export paused (test fixture)"
        alert.informativeText = "Move the note or revoke its access, wait for Note list to update, then click Continue."
        alert.addButton(withTitle: "Continue")
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { _ in continuation.resume() }
        }
    }
}
#endif

#if DEBUG
/// UI fixture A04: seeds a note with a long save failure and a recovery notice in a narrow
/// window. It only writes inside the isolated test-session Notes folder.
@MainActor
enum RecoveryLayoutFixture {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--test-recovery-layout-fixture") }

    /// Seeds the fixture and returns the isolated support folder to delete at quit.
    static func seed(support: URL, supportAlreadyExisted: Bool, selection: FolderSelection, store: NoteStore,
                     folderState: FolderState, recovery: RecoveryController, windows: WindowCoordinator) async throws -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        guard let sessionIndex = arguments.firstIndex(of: "--test-session"),
              arguments.indices.contains(sessionIndex + 1),
              let session = UUID(uuidString: arguments[sessionIndex + 1]) else {
            throw NoteOperationError.inputOutput(message("The recovery layout fixture requires --test-session with a UUID."))
        }
        let isolatedSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramnotes-ui-" + session.uuidString, isDirectory: true).standardizedFileURL
        guard !supportAlreadyExisted,
              support.standardizedFileURL == isolatedSupport,
              selection.url.standardizedFileURL == isolatedSupport.appendingPathComponent("Notes", isDirectory: true).standardizedFileURL else {
            throw NoteOperationError.inputOutput(message("The recovery layout fixture only writes inside its isolated test-session Notes folder."))
        }
        let originalURL = selection.url.appendingPathComponent("A04 long filename for recovery layout with long errors.txt")
        try Data("Disposable recovery layout fixture".utf8).write(to: originalURL, options: .withoutOverwriting)
        let original = try await store.adopt(originalURL)
        let recoveryNote = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
        folderState.apply(.changed(original))
        folderState.apply(.changed(recoveryNote))
        try await store.seedRecoveryNoticeForFixture(original: original, recovery: recoveryNote)
        recovery.project(await store.recoveryNotices())
        windows.open(original)
        try await Task.sleep(for: .milliseconds(100))
        guard let controller = windows.windows[original.id] else { return isolatedSupport }
        controller.display(.failed(original.editRevision, .inputOutput(
            message("Disposable A04 save failure with a deliberately long explanation to exercise the narrow recovery layout.")), journaled: false))
        controller.window?.setFrame(NSRect(x: 180, y: 180, width: 375, height: 260), display: true)
        return isolatedSupport
    }

    /// Debug fixture text stays out of the string catalog: a non-literal value is not extracted.
    private static func message(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }
}
#endif
