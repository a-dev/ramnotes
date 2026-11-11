import AppKit
import ramnotesDomain

/// Uses production storage with production sandbox grants, without XCTest exceptions.
@MainActor final class FileMoveProbe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "Move a disposable note to Downloads, then move it again to test file-only source cleanup.")
    var store: NoteStore?
    var note: NoteSnapshot?
    let bytes = Data("Disposable file-only move fixture: 文 📝\n".utf8)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "File-only Move Probe"
        status.frame = NSRect(x: 20, y: 70, width: 700, height: 240)
        window.contentView!.addSubview(status)
        let button = NSButton(title: "Move Disposable Note…", target: self, action: #selector(move))
        button.frame = NSRect(x: 20, y: 20, width: 300, height: 35)
        window.contentView!.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let path = UserDefaults.standard.string(forKey: "support") {
            Task { await restore(URL(fileURLWithPath: path)) }
        }
    }

    func restore(_ support: URL) async {
        do {
            let restored = try await NoteStore.make(support: support)
            let selection = try await restored.openSelectedFolder()
            guard selection.recoveryDiagnostics.isEmpty, selection.notes.count == 1,
                  let id = UserDefaults.standard.string(forKey: "noteID"),
                  let found = selection.notes.first, found.id.rawValue.uuidString == id,
                  try Data(contentsOf: found.fileURL) == bytes,
                  await restored.unfinishedLocationOperations().isEmpty else {
                throw NoteOperationError.inputOutput("Restored note identity, bytes, or transaction state failed verification")
            }
            store = restored
            note = found
            status.stringValue = "PASS relaunch: file bookmark restored; identity and bytes preserved; no unfinished operation.\n\(found.fileURL.path)"
        } catch { status.stringValue = "FAIL relaunch: \(error)" }
    }

    @objc func move() {
        let picker = NSSavePanel()
        picker.nameFieldStringValue = "ramnotes-disposable-move-" + UUID().uuidString + ".txt"
        picker.beginSheetModal(for: window) { response in
            guard response == .OK, let target = picker.url else { return }
            Task { @MainActor in
                do {
                    let store: NoteStore
                    let source: NoteSnapshot
                    if let existing = self.store, let note = self.note {
                        store = existing
                        source = note
                    } else {
                        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Run-" + UUID().uuidString)
                        store = try await NoteStore.make(support: root)
                        let selection = try await store.openSelectedFolder()
                        let created = try await store.create(in: selection.url, collectionToken: selection.collectionToken)
                        let edit = EditSnapshot(id: created.id, collectionToken: created.collectionToken,
                            revision: EditRevision(rawValue: 1), baseRevision: created.fileRevision,
                            text: String(decoding: self.bytes, as: UTF8.self))
                        guard case .saved = await store.save(edit) else { throw NoteOperationError.unavailable }
                        source = try await store.read(created.id, collectionToken: created.collectionToken)
                        self.store = store
                        UserDefaults.standard.set(root.path, forKey: "support")
                        UserDefaults.standard.set(source.id.rawValue.uuidString, forKey: "noteID")
                    }
                    let grant = try await store.acquireDestinationFile(target)
                    defer { withExtendedLifetime(grant) {} }
                    let result = await store.moveNote(source.id, to: target, collectionToken: source.collectionToken,
                        locationRevision: source.locationRevision, editRevision: source.editRevision)
                    guard case .moved = result.outcome else {
                        let operations = await store.unfinishedLocationOperations()
                        throw NoteOperationError.inputOutput("\(result.outcome); \(String(describing: result.error)); stages=\(operations.map(\.stage)); source=\(FileManager.default.fileExists(atPath: source.fileURL.path)); destination=\(FileManager.default.fileExists(atPath: target.path))")
                    }
                    let moved = try await store.read(source.id, collectionToken: source.collectionToken)
                    guard moved.fileURL == target, moved.fileRevision == source.fileRevision,
                          moved.locationRevision == source.locationRevision.advanced(),
                          try Data(contentsOf: target) == self.bytes,
                          !FileManager.default.fileExists(atPath: source.fileURL.path),
                          await store.unfinishedLocationOperations().isEmpty else {
                        throw NoteOperationError.inputOutput("Move bytes, timestamp, identity, source removal, or completion failed verification")
                    }
                    self.note = moved
                    self.status.stringValue = "PASS move: identity, bytes and timestamp preserved; source removed; transaction complete. Move again to test a file-only source, or quit and relaunch to test bookmark restoration.\n\(target.path)"
                } catch { self.status.stringValue = "FAIL: \(error)" }
            }
        }
    }
}
let app = NSApplication.shared
let delegate = FileMoveProbe()
app.delegate = delegate
app.run()
