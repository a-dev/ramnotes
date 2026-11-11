import AppKit

@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var status: NSTextField?
    private var cloudStatus: NSTextField?
    private var cloudURL: URL?
    private let bookmarkKey = "disposableFolderBookmark"
    private let fileBookmarkKey = "disposableFileBookmark"
    private let selectedFileKey = "disposableFilePath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit StorageAccessProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sandbox Folder Probe"
        window.center()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 510, height: 390))
        let status = NSTextField(wrappingLabelWithString: "Choose a disposable folder, then select a test file inside it.")
        status.frame = NSRect(x: 20, y: 315, width: 470, height: 55)
        status.maximumNumberOfLines = 3
        content.addSubview(status)
        self.status = status
        let button = NSButton(title: "Choose Disposable Folder", target: self, action: #selector(chooseFolder(_:)))
        button.frame = NSRect(x: 20, y: 265, width: 210, height: 34)
        content.addSubview(button)
        let fileButton = NSButton(title: "Select Test File Bookmark", target: self, action: #selector(chooseTestFile(_:)))
        fileButton.frame = NSRect(x: 250, y: 265, width: 240, height: 34)
        content.addSubview(fileButton)
        let replaceButton = NSButton(title: "Atomic Replace Selected File", target: self, action: #selector(atomicReplace(_:)))
        replaceButton.frame = NSRect(x: 20, y: 220, width: 230, height: 34)
        content.addSubview(replaceButton)
        let moveButton = NSButton(title: "Move Selected File", target: self, action: #selector(moveSelectedFile(_:)))
        moveButton.frame = NSRect(x: 260, y: 220, width: 230, height: 34)
        content.addSubview(moveButton)
        let cloudStatus = NSTextField(labelWithString: "iCloud test file not selected")
        cloudStatus.frame = NSRect(x: 20, y: 145, width: 470, height: 55)
        cloudStatus.maximumNumberOfLines = 3
        content.addSubview(cloudStatus)
        self.cloudStatus = cloudStatus
        let cloudButton = NSButton(title: "Inspect iCloud Test File", target: self, action: #selector(chooseCloudFile(_:)))
        cloudButton.frame = NSRect(x: 250, y: 75, width: 220, height: 34)
        content.addSubview(cloudButton)
        let evictButton = NSButton(title: "Remove Local Test Copy", target: self, action: #selector(evictCloudFile(_:)))
        evictButton.frame = NSRect(x: 250, y: 30, width: 220, height: 34)
        content.addSubview(evictButton)
        let downloadButton = NSButton(title: "Download Test File", target: self, action: #selector(downloadCloudFile(_:)))
        downloadButton.frame = NSRect(x: 20, y: 30, width: 210, height: 34)
        content.addSubview(downloadButton)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            access(data: data, marker: "probe-relaunch.txt")
        }
        if let data = UserDefaults.standard.data(forKey: fileBookmarkKey) { verifyFileBookmark(data, label: "relaunch") }
    }

    @objc private func chooseTestFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bookmark Test File"
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            guard self.isDisposable(url), url.lastPathComponent == "probe-target.txt" else {
                self.status?.stringValue = "Rejected: select probe-target.txt inside the disposable probe folder."
                return
            }
            do {
                let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: self.fileBookmarkKey)
                UserDefaults.standard.set(url.path, forKey: self.selectedFileKey)
                self.verifyFileBookmark(data, label: "selected")
            } catch { self.status?.stringValue = "File bookmark failed: \(error.localizedDescription)" }
        }
    }

    private func resolvedFileBookmark() throws -> (URL, Bool) {
        guard let data = UserDefaults.standard.data(forKey: fileBookmarkKey) else { throw ProbeError.noFileBookmark }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard isDisposable(url) else { throw ProbeError.outsideDisposableRoot }
        return (url, stale)
    }

    private func verifyFileBookmark(_ data: Data, label: String) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard isDisposable(url) else { throw ProbeError.outsideDisposableRoot }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            guard started else { throw ProbeError.scopeDenied }
            let bytes = try Data(contentsOf: url)
            if stale {
                let renewedBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(renewedBookmark, forKey: fileBookmarkKey)
            }
            status?.stringValue = "File bookmark \(label) restored; bytes=\(bytes.count), stale=\(stale), scope=true, renewed=\(stale)"
            NSLog("StorageAccessProbe file bookmark %@ path=%@ bytes=%ld stale=%@ scope=true renewed=%@", label, url.path, bytes.count, String(stale), String(stale))
        } catch { status?.stringValue = "File bookmark \(label) failed: \(error.localizedDescription)" }
    }

    @objc private func atomicReplace(_ sender: Any?) {
        do {
            let (url, stale) = try resolvedFileBookmark()
            let folderURL = try resolvedFolderBookmark()
            let folderStarted = folderURL.startAccessingSecurityScopedResource()
            defer { if folderStarted { folderURL.stopAccessingSecurityScopedResource() } }
            let fileStarted = url.startAccessingSecurityScopedResource()
            defer { if fileStarted { url.stopAccessingSecurityScopedResource() } }
            guard folderStarted, fileStarted else { throw ProbeError.scopeDenied }
            let replacement = Data("atomic replacement at \(Date().timeIntervalSince1970)\n".utf8)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var writeError: Error?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do { try StorageFiles.atomic(replacement, at: coordinatedURL) }
                catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
            let actual = try Data(contentsOf: url)
            guard actual == replacement else { throw ProbeError.replacementMismatch }
            let refreshedBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(refreshedBookmark, forKey: fileBookmarkKey)
            UserDefaults.standard.set(url.path, forKey: selectedFileKey)
            status?.stringValue = "StorageFiles.atomic verified; bookmark refreshed; bytes=\(actual.count), stale=\(stale), folderScope=true, fileScope=true"
            NSLog("StorageAccessProbe StorageFiles.atomic verified and bookmark refreshed path=%@ bytes=%ld bookmarkBytes=%ld folderScope=true fileScope=true", url.path, actual.count, refreshedBookmark.count)
        } catch { status?.stringValue = "Atomic replacement failed: \(error.localizedDescription)" }
    }

    private func resolvedFolderBookmark() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { throw ProbeError.noFileBookmark }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard isDisposable(url) else { throw ProbeError.outsideDisposableRoot }
        return url
    }

    @objc private func moveSelectedFile(_ sender: Any?) {
        do {
            let (source, stale) = try resolvedFileBookmark()
            let root = try resolvedFolderBookmark()
            let started = root.startAccessingSecurityScopedResource()
            defer { if started { root.stopAccessingSecurityScopedResource() } }
            let fileStarted = source.startAccessingSecurityScopedResource()
            defer { if fileStarted { source.stopAccessingSecurityScopedResource() } }
            guard started, fileStarted else { throw ProbeError.scopeDenied }
            let destination = root.appendingPathComponent("probe-moved", isDirectory: true).appendingPathComponent("probe-target.txt")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProbeError.destinationExists }
            let expected = try Data(contentsOf: source)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var moveError: Error?
            coordinator.coordinate(writingItemAt: source, options: .forMoving, error: &coordinationError) { coordinatedSource in
                do {
                    try FileManager.default.moveItem(at: coordinatedSource, to: destination)
                    coordinator.item(at: source, didMoveTo: destination)
                } catch {
                    moveError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let moveError { throw moveError }
            let movedBytes = try Data(contentsOf: destination)
            guard movedBytes == expected else { throw ProbeError.replacementMismatch }
            do {
                let (resolved, resolveStale) = try resolvedFileBookmark()
                let bookmarkBytes = try Data(contentsOf: resolved)
                if bookmarkBytes == expected {
                    status?.stringValue = "Move verified; file bookmark followed move to \(resolved.lastPathComponent), stale=\(resolveStale)"
                } else {
                    status?.stringValue = "Move verified; bookmark resolves elsewhere with different bytes, stale=\(resolveStale)"
                }
                NSLog("StorageAccessProbe move verified destination=%@ bookmark=%@ stale=%@ originalStale=%@", destination.path, resolved.path, String(resolveStale), String(stale))
            } catch {
                status?.stringValue = "Move verified; file bookmark did not follow move: \(error.localizedDescription)"
                NSLog("StorageAccessProbe move verified destination=%@ bookmarkResolutionError=%@", destination.path, error.localizedDescription)
            }
        } catch { status?.stringValue = "Move/bookmark check failed: \(error.localizedDescription)" }
    }

    @objc private func chooseCloudFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect Test File"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.inspectCloudFile(url)
        }
    }

    private func inspectCloudFile(_ url: URL) {
        guard url.lastPathComponent == "ramnotes-unavailable-test.txt",
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("ramnotes-icloud-probe-") else {
            cloudStatus?.stringValue = "Rejected non-test file: \(url.lastPathComponent)"
            return
        }
        cloudURL = url
        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
            ])
            let state: String
            switch values.ubiquitousItemDownloadingStatus {
            case .notDownloaded: state = "notDownloaded"
            case .downloaded: state = "downloaded"
            case .current: state = "current"
            case .none: state = "unknown"
            case .some(_): state = "other"
            }
            let report = "iCloud=\(values.isUbiquitousItem == true) status=\(state) downloading=\(values.ubiquitousItemIsDownloading == true)"
            NSLog("StorageAccessProbe cloud %@", report)
            cloudStatus?.stringValue = report
        } catch {
            cloudStatus?.stringValue = "iCloud status failed: \(error.localizedDescription)"
        }
    }

    @objc private func evictCloudFile(_ sender: Any?) {
        guard let url = cloudURL else {
            cloudStatus?.stringValue = "Inspect the disposable iCloud file first."
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            inspectCloudFile(url)
        } catch {
            cloudStatus?.stringValue = "Remove local copy failed: \(error.localizedDescription)"
        }
    }

    @objc private func downloadCloudFile(_ sender: Any?) {
        guard let url = cloudURL else {
            cloudStatus?.stringValue = "Inspect the disposable iCloud file first."
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            cloudStatus?.stringValue = "Download requested; inspect the file again after it finishes."
        } catch {
            cloudStatus?.stringValue = "Download failed: \(error.localizedDescription)"
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Test Folder"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.select(url)
        }
    }

    private func select(_ url: URL) {
        NSLog("StorageAccessProbe selected path %@ resolved path %@", url.path, url.resolvingSymlinksInPath().path)
        guard isDisposable(url) else {
            status?.stringValue = "Rejected test folder: \(url.path)"
            return
        }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            NSLog("StorageAccessProbe bookmark created: %ld bytes", data.count)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            access(data: data, marker: "probe-initial.txt")
        } catch { NSLog("StorageAccessProbe bookmark failed: %@", String(describing: error)); status?.stringValue = "Bookmark failed: \(error.localizedDescription)" }
    }

    private func access(data: Data, marker: String) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard isDisposable(url) else {
                status?.stringValue = "Stored bookmark does not point to a disposable folder."
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                status?.stringValue = "Security-scoped access denied."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            try Data("sandbox access verified\n".utf8).write(to: url.appendingPathComponent(marker), options: .atomic)
            if marker == "probe-initial.txt" {
                try Data("initial disposable test content\n".utf8).write(to: url.appendingPathComponent("probe-target.txt"), options: .atomic)
            }
            NSLog("StorageAccessProbe wrote %@", marker)
            status?.stringValue = "Access worked: \(marker), bookmark stale: \(stale)"
        } catch { status?.stringValue = "Access failed: \(error.localizedDescription)" }
    }

    private func isDisposable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let tempRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let components = resolved.pathComponents
        guard let index = components.firstIndex(of: tempRoot.lastPathComponent), index + 1 < components.count else { return false }
        return components[index + 1].hasPrefix("ramnotes-storage-probe-")
    }
}

private enum ProbeError: LocalizedError {
        case noFileBookmark, outsideDisposableRoot, scopeDenied, replacementMismatch, destinationExists
    var errorDescription: String? {
        switch self {
        case .noFileBookmark: return "No test-file bookmark is stored."
        case .outsideDisposableRoot: return "Resolved URL is outside the disposable probe folder."
        case .scopeDenied: return "Security-scoped access was denied."
        case .replacementMismatch: return "The expected replacement bytes were not present."
        case .destinationExists: return "The disposable move destination already exists."
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ProbeDelegate()
    app.delegate = delegate
    app.run()
}
