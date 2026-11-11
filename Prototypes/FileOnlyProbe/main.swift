import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin

// No folder picker or parent bookmark exists in this process.
@MainActor final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let output = DropTextView()
    var selected: URL?
    var scope = false
    var faultStage: String?
    let defaults = UserDefaults.standard
    func log(_ message: String) {
        output.string += message + "\n"
        let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let report = destination.appendingPathComponent("results-\(ProcessInfo.processInfo.processIdentifier).txt")
        try? output.string.write(to: report, atomically: true, encoding: .utf8)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "File-only sandbox probe — drop file in blank strip below buttons"
        let root = DropView(frame: window.contentView!.bounds); root.probe = self
        root.registerForDraggedTypes([.fileURL]); window.contentView = root
        let actions: [(String, Selector)] = [("Select File…", #selector(pick)), ("Foundation Save ×3", #selector(save)), ("NSDocument Save ×3", #selector(documentSave)), ("Trash File", #selector(trash))]
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.0, target: self, action: action.1)
            button.frame = NSRect(x: 12 + index * 185, y: 490, width: 180, height: 32); root.addSubview(button)
        }
        let faults: [(String, Selector)] = [("Document: Fail Before", #selector(failBefore)), ("Document: Fail After", #selector(failAfter)), ("Document: Exit Before", #selector(exitBefore)), ("Document: Exit After", #selector(exitAfter))]
        for (index, action) in faults.enumerated() {
            let button = NSButton(title: action.0, target: self, action: action.1)
            button.frame = NSRect(x: 12 + index * 185, y: 445, width: 180, height: 32); root.addSubview(button)
        }
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 736, height: 405))
        scroll.hasVerticalScroller = true; scroll.documentView = output
        output.probe = self; output.registerForDraggedTypes([.fileURL])
        output.frame = scroll.bounds; output.isEditable = false; output.isVerticallyResizable = true
        root.addSubview(scroll)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrame(NSRect(x: frame.maxX - 780, y: frame.midY - 290, width: 760, height: 580), display: false)
        }
        window.level = .floating
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        log("window=\(window.frame) screen=\(String(describing: NSScreen.main?.visibleFrame))")
        log("pid=\(ProcessInfo.processInfo.processIdentifier) OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--baseline-file"), arguments.indices.contains(index + 1) {
            let candidate = URL(fileURLWithPath: arguments[index + 1])
            guard candidate.lastPathComponent == "probe-target.txt", candidate.deletingLastPathComponent().lastPathComponent.hasPrefix("ramnotes-file-only-") else { return }
            log("BASELINE before picker or bookmark resolution")
            do { _ = try Data(contentsOf: candidate); log("BASELINE file read allowed") }
            catch { log("BASELINE file read denied: \(error)") }
            do { try isolation(candidate) } catch { log("BASELINE isolation failed: \(error)") }
        }
        if let bookmark = defaults.data(forKey: "file") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                try accept(url, source: "relaunch stale=\(stale)")
                if let expected = defaults.data(forKey: "interruptedExpected") {
                    log(try Data(contentsOf: url) == expected ? "PASS interrupted save exact bytes" : "FAIL interrupted save bytes differ")
                    defaults.removeObject(forKey: "interruptedExpected")
                }
            } catch { log("RELAUNCH FAIL \(error)") }
        } else { log("Fresh session. Select or Finder-drop probe-target.txt in a new ramnotes-file-only-* directory.") }
    }
    @objc func pick() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try accept(url, source: "NSOpenPanel") } catch { log("SELECT FAIL \(error)") }
    }
    func accept(_ url: URL, source: String) throws {
        guard url.lastPathComponent == "probe-target.txt", url.deletingLastPathComponent().lastPathComponent.hasPrefix("ramnotes-file-only-"),
              try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.invalidFixture }
        if scope, let selected { selected.stopAccessingSecurityScopedResource() }
        selected = url; scope = url.startAccessingSecurityScopedResource()
        let values = try url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        log("Filesystem=\(values.volumeLocalizedFormatDescription ?? "unknown") iCloud=\(values.isUbiquitousItem == true) download=\(String(describing: values.ubiquitousItemDownloadingStatus))")
        let bytes = try Data(contentsOf: url)
        try checkpoint(url)
        log("ACCESS \(source) scope=\(scope) bytes=\(bytes.count) path=\(url.path)")
        try isolation(url)
    }
    func checkpoint(_ url: URL) throws {
        defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "file")
        guard defaults.synchronize() else { throw Failure.checkpoint }
    }
    func denied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if scope, let selected { selected.stopAccessingSecurityScopedResource(); scope = false }
    }
    func isolation(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var leaked = false
        do { _ = try FileManager.default.contentsOfDirectory(atPath: parent.path); log("OBSERVED parent enumeration allowed (diagnostic only)") }
        catch { guard denied(error) else { throw error }; log("PASS parent enumeration denied: \(error)") }
        let sentinel = parent.appendingPathComponent("sibling-sentinel.txt")
        do { _ = try Data(contentsOf: sentinel); log("FAIL sibling contents readable"); leaked = true }
        catch { guard denied(error) else { throw error }; log("PASS sibling contents denied") }
        let sibling = parent.appendingPathComponent("unauthorized-\(UUID().uuidString)")
        do { try Data("test".utf8).write(to: sibling, options: .withoutOverwriting); try? FileManager.default.removeItem(at: sibling); log("FAIL sibling creation allowed"); leaked = true }
        catch { guard denied(error) else { throw error }; log("PASS sibling creation denied: \(error)") }
        if leaked { throw Failure.broadAccess }
    }
    func runSaves(document: Bool) {
        guard let url = selected else { return }
        do {
            try isolation(url)
            let original = try Data(contentsOf: url)
            // Retain intended and base bytes even when replacement or bookmark renewal fails.
            defaults.set(original, forKey: "journalBase")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            log("Initial POSIX permissions=\(permissions?.stringValue ?? "unknown")")
            for iteration in 1...3 {
                // Exercise BOM, CRLF, Unicode and exact bytes on every replacement.
                var expected = Data([0xef, 0xbb, 0xbf]); expected.append(Data("save \(iteration) \(UUID())\r\nქართული 😀\r\n".utf8))
                defaults.set(expected, forKey: "journalIntended")
                guard defaults.synchronize() else { throw Failure.checkpoint }
                let before = try Data(contentsOf: url)
                if document {
                    let selectedFault = faultStage
                    let doc = ProbeDocument(afterStaging: {
                        if selectedFault == "before" { throw Failure.injected }
                        if selectedFault == "exit-before" {
                            UserDefaults.standard.set(before, forKey: "interruptedExpected")
                            guard UserDefaults.standard.synchronize() else { throw Failure.checkpoint }
                            Darwin._exit(86)
                        }
                    })
                    doc.bytes = expected; doc.fileURL = url; doc.fileType = "public.plain-text"
                    defer { doc.close() }
                    try doc.writeSafely(to: url, ofType: "public.plain-text", for: .saveOperation)
                    if faultStage == "after" { throw Failure.injected }
                    if faultStage == "exit-after" { interrupt(expected: expected) }
                } else {
                    let coordinator = NSFileCoordinator(); var coordinationError: NSError?; var writeError: Error?
                    coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                        do {
                            let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                            let payload = temporary.appendingPathComponent("payload.txt")
                            try expected.write(to: payload)
                            if let mode = attributes[.posixPermissions] {
                                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: payload.path)
                            }
                            let handle = try FileHandle(forWritingTo: payload); defer { try? handle.close() }; try handle.synchronize()
                            if self.faultStage == "before" { throw Failure.injected }
                            if self.faultStage == "exit-before" { self.interrupt(expected: before) }
                            _ = try FileManager.default.replaceItemAt(target, withItemAt: payload)
                            if let mode = attributes[.posixPermissions] {
                                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
                            }
                            if self.faultStage == "after" { throw Failure.injected }
                            if self.faultStage == "exit-after" { self.interrupt(expected: expected) }
                        } catch { writeError = error }
                    }
                    if let coordinationError { throw coordinationError }; if let writeError { throw writeError }
                }
                guard try Data(contentsOf: url) == expected else { throw Failure.bytes }
                let after = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                guard permissions == after else { throw Failure.permissions }
                try checkpoint(url)
                log("SHA256=\(SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())")
                log("PASS \(document ? "NSDocument" : "Foundation") replacement \(iteration): exact bytes, permissions, renewed bookmark")
            }
            log("Initial bytes=\(original.count); final bytes=\(try Data(contentsOf: url).count)")
            try isolation(url)
        } catch {
            log("SAVE FAIL \(error); readable bytes=\((try? Data(contentsOf: url).count) ?? -1)")
            if error is Failure, faultStage == "before" || faultStage == "after" {
                let key = faultStage == "before" ? "journalBase" : "journalIntended"
                log((try? Data(contentsOf: url)) == defaults.data(forKey: key) ? "PASS injected failure exact bytes (\(key))" : "FAIL injected failure bytes differ")
            }
        }
        faultStage = nil
    }
    func interrupt(expected: Data) -> Never {
        defaults.set(expected, forKey: "interruptedExpected")
        guard defaults.synchronize() else { fatalError("Checkpoint failed") }
        Darwin._exit(86)
    }
    @objc func failBefore() { faultStage = "before"; runSaves(document: true) }
    @objc func failAfter() { faultStage = "after"; runSaves(document: true) }
    @objc func exitBefore() { faultStage = "exit-before"; runSaves(document: true) }
    @objc func exitAfter() { faultStage = "exit-after"; runSaves(document: true) }
    @objc func save() { runSaves(document: false) }
    @objc func documentSave() { runSaves(document: true) }
    @objc func trash() {
        guard let url = selected else { return }
        do {
            try isolation(url)
            let alert = NSAlert(); alert.messageText = "Move disposable probe-target.txt to Trash?"; alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let coordinator = NSFileCoordinator(); var failure: NSError?; var operationError: Error?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &failure) { target in
                do { try FileManager.default.trashItem(at: target, resultingItemURL: nil) } catch { operationError = error }
            }
            if let failure { throw failure }; if let operationError { throw operationError }
            log("PASS Trash API succeeded; original reachable=\((try? url.checkResourceIsReachable()) == true). No Trash destination retained.")
            defaults.removeObject(forKey: "file")
            if scope { url.stopAccessingSecurityScopedResource(); scope = false }
            selected = nil
        } catch { log("TRASH FAIL \(error)") }
    }
}
@MainActor final class DropTextView: NSTextView {
    weak var probe: Probe?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { probe?.log("DRAG ENTER"); return .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], urls.count == 1 else { return false }
        do { try probe?.accept(urls[0], source: "Finder drop"); return true } catch { probe?.log("DROP FAIL \(error)"); return false }
    }
}
@MainActor final class DropView: NSView {
    weak var probe: Probe?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { probe?.log("DRAG ENTER"); return .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], urls.count == 1 else { return false }
        do { try probe?.accept(urls[0], source: "Finder drop"); return true } catch { probe?.log("DROP FAIL \(error)"); return false }
    }
}
final class ProbeDocument: NSDocument {
    var bytes = Data()
    nonisolated let afterStaging: @Sendable () throws -> Void
    init(afterStaging: @escaping @Sendable () throws -> Void = {}) {
        self.afterStaging = afterStaging
        super.init()
    }
    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: originalContentsURL)
        try afterStaging()
    }
    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }
    override func data(ofType typeName: String) throws -> Data { bytes }
}
enum Failure: Error { case invalidFixture, broadAccess, checkpoint, bytes, permissions, injected }
MainActor.assumeIsolated {
    let app = NSApplication.shared; let delegate = Probe(); app.delegate = delegate; app.run()
}
