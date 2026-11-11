import ramnotesDomain
import AppKit

@MainActor final class LocationProbe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "Choose the disposable CP-03 mounted destination folder.")
    var store: NoteStore?
    var runRoot: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CP-03 Location Operation Probe"
        let content = NSView(frame: window.contentView!.bounds)
        status.frame = NSRect(x: 20, y: 80, width: 600, height: 130)
        content.addSubview(status)
        let choose = NSButton(title: "Choose Disposable Destination", target: self, action: #selector(chooseDestination))
        choose.frame = NSRect(x: 20, y: 25, width: 300, height: 35)
        content.addSubview(choose)
        let resume = NSButton(title: "Resume Persisted Operation", target: self, action: #selector(resumeOperation))
        resume.frame = NSRect(x: 325, y: 25, width: 295, height: 35)
        content.addSubview(resume)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let path = UserDefaults.standard.string(forKey: "runRoot") {
            runRoot = URL(fileURLWithPath: path)
            status.stringValue = "Persisted disposable run available. Resume to reconcile after relaunch.\n\(path)"
        }
    }
    func report(_ text: String) {
        status.stringValue = text
        NSLog("CP03-PROBE %@", text)
        if let runRoot { try? Data((text + "\n").utf8).write(to: runRoot.appendingPathComponent("probe-result.txt")) }
    }
    @objc func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Authorize Disposable Destination"
        panel.begin { [weak self] response in
            guard let self else { return }
            self.acceptDestination(response == .OK ? panel.url : nil)
        }
    }
    func acceptDestination(_ selected: URL?) {
        guard let destination = selected,
              destination.resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: "/tmp/ramnotes-cp03-volume/probe-destination", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL else {
            report("Rejected: select only /tmp/ramnotes-cp03-volume/probe-destination")
            return
        }
        Task {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("CP03-" + UUID().uuidString, isDirectory: true)
                runRoot = support
                UserDefaults.standard.set(support.path, forKey: "runRoot")
                let store = try await NoteStore.make(support: support, fault: { if $0 == .moveVerified || $0 == .moveSourceRemoval { throw NoteOperationError.cancelled } })
                self.store = store
                let selected = try await store.openSelectedFolder()
                let note = try await store.create(in: selected.url, collectionToken: selected.collectionToken)
                let edit = EditSnapshot(id: note.id, collectionToken: note.collectionToken, revision: EditRevision(rawValue: 1), baseRevision: note.fileRevision, text: "CP-03 disposable cross-volume bytes\n")
                guard case .saved = await store.save(edit) else { throw NoteOperationError.unavailable }
                let saved = try await store.read(note.id, collectionToken: note.collectionToken)
                let target = destination.appendingPathComponent("probe-" + UUID().uuidString + ".txt")
                let result = await store.moveNote(saved.id, to: target, collectionToken: saved.collectionToken, locationRevision: saved.locationRevision, editRevision: saved.editRevision)
                guard case let .interrupted(id) = result.outcome else { throw NoteOperationError.inputOutput("Expected verified-copy interruption: \(result.outcome), \(String(describing: result.error))") }
                let catalog = try CatalogPersistence.load(at: support.appendingPathComponent("collection.json"))
                guard let operation = catalog.operations[id], operation.crossVolume, operation.stage == .destinationVerified,
                      FileManager.default.fileExists(atPath: saved.fileURL.path),
                      try StorageFiles.read(target).revision == saved.fileRevision else {
                    throw NoteOperationError.inputOutput("Cross-volume copy checkpoint not verified: \(String(describing: result.error))")
                }
                report("PASS: signed sandbox cross-volume copy verified; source retained; destination checkpoint durable. Quit and relaunch, then Resume.\n\(support.path)\n\(target.path)")
            } catch { report("FAIL: \(error)") }
        }
    }
    @objc func resumeOperation() {
        guard let runRoot else { return }
        Task {
            do {
                let before = try CatalogPersistence.load(at: runRoot.appendingPathComponent("collection.json"))
                guard let operation = before.operations.values.first else { throw NoteOperationError.unavailable }
                let store = try await NoteStore.make(support: runRoot)
                self.store = store
                let selected = try await store.openSelectedFolder()
                let after = try CatalogPersistence.load(at: runRoot.appendingPathComponent("collection.json"))
                guard let note = selected.notes.first(where: { $0.id == operation.noteID }),
                      note.fileRevision == operation.expectedFileRevision,
                      note.locationRevision.rawValue == operation.source.revision.rawValue + 1,
                      after.operations[operation.id]?.stage == .complete,
                      !FileManager.default.fileExists(atPath: operation.source.path),
                      selected.recoveryDiagnostics.isEmpty else { throw NoteOperationError.inputOutput("Resume verification failed: \(selected.recoveryDiagnostics)") }
                report("PASS: signed sandbox relaunch restored grants, verified destination, removed unchanged source, retained NoteID/mtime and completed catalog.\n\(runRoot.path)\n\(note.fileURL.path)")
            } catch { report("FAIL resume: \(error)") }
        }
    }
}
let app = NSApplication.shared
let delegate = LocationProbe()
app.delegate = delegate
app.run()
