import ramnotesDomain
import Foundation
import os
import AppKit
import Synchronization

struct FolderAccessHooks: Sendable {
    var bookmark: @Sendable (URL) throws -> Data = { url in
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    var resolve: @Sendable (Data) throws -> (url: URL, stale: Bool) = { data in
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: FolderAccessHooks.resolveOptions,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        } catch {
            if let volume = FolderAccessHooks.unmountedVolume(of: data) {
                throw NoteOperationError.accessFailure(NoteAccessFailure(reason: .unavailableVolume, domain: NSPOSIXErrorDomain,
                    code: Int(ENODEV), message: "The disk “\(volume.lastPathComponent)” is not connected."))
            }
            throw error
        }
    }

    /// Resolution mounts an ejected volume again, so a note on it becomes available without user action.
    /// Debug builds launched with `--no-volume-mount` keep the volume ejected for disconnected-volume checks.
    static let resolveOptions: URL.BookmarkResolutionOptions = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--no-volume-mount") { return [.withSecurityScope, .withoutMounting, .withoutUI] }
        #endif
        return .withSecurityScope
    }()

    /// Read the unmounted volume from the bookmark without resolving it.
    static func unmountedVolume(of data: Data) -> URL? {
        guard let values = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: data),
              let volume = values.volume else { return nil }
        return FileManager.default.fileExists(atPath: volume.path) ? nil : volume
    }
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
}

/// Holds one security-scoped access. Each start has exactly one matching stop.
final class FolderLease: FolderGrant {
    let url: URL
    private let stop: @Sendable (URL) -> Void
    init(url: URL, stop: @escaping @Sendable (URL) -> Void) { self.url = url; self.stop = stop }
    deinit { stop(url) }
}

private final class WeakLease: @unchecked Sendable {
    weak var value: FolderLease?
    init(_ value: FolderLease) { self.value = value }
}

final class FolderAccess: Sendable {
    private let leases = Mutex<[String: WeakLease]>([:])
    let support: URL
    let hooks: FolderAccessHooks
    var defaultURL: URL { support.appendingPathComponent("Notes", isDirectory: true) }
    var selectionURL: URL { support.appendingPathComponent("collection.json") }

    init(support: URL, hooks: FolderAccessHooks = FolderAccessHooks()) { self.support = support; self.hooks = hooks }

    func acquire(_ url: URL) throws -> FolderLease {
        let canonical = url.standardizedFileURL
        let recoveryPath = support.appendingPathComponent("Recovery").resolvingSymlinksInPath().path
        let selectedPath = canonical.resolvingSymlinksInPath().path
        guard selectedPath != recoveryPath,
              !recoveryPath.hasPrefix(selectedPath.hasSuffix("/") ? selectedPath : selectedPath + "/"),
              !selectedPath.hasPrefix(recoveryPath + "/") else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("The recovery journal directory cannot be the notes folder", comment: "Error when the user picks the recovery journal folder as the notes folder"))
        }
        let lease = try sharedLease(canonical)
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { throw NoteOperationError.unavailable }
        // Open the directory to check access. The scanner lists its contents.
        guard let directory = opendir(canonical.path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        closedir(directory)
        return lease
    }

    private func sharedLease(_ url: URL) throws -> FolderLease {
        try leases.withLock { (entries: inout [String: WeakLease]) throws -> FolderLease in
            if let existing = entries[url.path]?.value { return existing }
            let container = defaultURL.standardizedFileURL.path + "/"
            let local = url == defaultURL.standardizedFileURL || url.path.hasPrefix(container)
            guard local || hooks.start(url) else { throw NoteOperationError.permissionDenied }
            let release: @Sendable (URL) -> Void
            if local { release = { _ in } } else { release = hooks.stop }
            let lease = FolderLease(url: url, stop: release)
            entries[url.path] = WeakLease(lease)
            return lease
        }
    }

    func descriptor(for lease: FolderLease, scope: NoteAccessDescriptor.Scope = .folder) throws -> NoteAccessDescriptor {
        let local = lease.url == defaultURL.standardizedFileURL || lease.url.path.hasPrefix(defaultURL.standardizedFileURL.path + "/")
        return NoteAccessDescriptor(url: lease.url, bookmark: local && scope != .file ? nil : try hooks.bookmark(lease.url),
                                    scope: local && scope != .file ? .appContainer : scope)
    }

    /// Resolves the bookmark, starts access, then renews a stale bookmark. The caller saves the result.
    func restore(_ descriptor: NoteAccessDescriptor) throws -> (FolderLease, NoteAccessDescriptor) {
        let resolved: (url: URL, stale: Bool)?
        do { resolved = try descriptor.bookmark.map(hooks.resolve) }
        catch {
            let failure = NoteFailureMapping.accessFailure(error, bookmark: true)
            Log.access.error("bookmark resolve failed scope=\(String(describing: descriptor.scope), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            let reason = failure.reason == .unavailableVolume ? .unavailableVolume : descriptor.scope == .file ? .staleBookmark : failure.reason
            throw NoteOperationError.accessFailure(NoteAccessFailure(reason: reason,
                domain: failure.domain, code: failure.code, message: failure.message))
        }
        let url = (resolved?.url ?? descriptor.url).standardizedFileURL
        let lease: FolderLease
        do { lease = try sharedLease(url) }
        catch {
            Log.access.error("access start failed path=\(url.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)")
            throw NoteOperationError.accessFailure(NoteFailureMapping.accessFailure(error, bookmark: true))
        }
        var updated = descriptor
        updated.url = url
        if resolved?.stale == true { updated.bookmark = try hooks.bookmark(url) }
        return (lease, updated)
    }

    /// Retains the URL grant returned by NSSavePanel, including for a not-yet-created file.
    func acquireDestinationFile(_ url: URL) throws -> FolderLease {
        let canonical = url.standardizedFileURL
        let recovery = support.appendingPathComponent("Recovery").resolvingSymlinksInPath().path
        guard canonical.isFileURL, canonical.pathExtension.lowercased() == "txt",
              !canonical.resolvingSymlinksInPath().path.hasPrefix(recovery + "/") else {
            throw NoteOperationError.invalidFilename
        }
        return try sharedLease(canonical)
    }

    func acquireFile(_ url: URL) throws -> FolderLease {
        let lease: FolderLease
        do { lease = try sharedLease(url.standardizedFileURL) }
        catch NoteOperationError.permissionDenied {
            // A dropped URL can have a sandbox grant without a security scope. Resolve its bookmark to obtain the scope.
            guard let scoped = try? hooks.resolve(hooks.bookmark(url)).url else { throw NoteOperationError.permissionDenied }
            lease = try sharedLease(scoped.standardizedFileURL)
        }
        let canonical = lease.url
        let recovery = support.appendingPathComponent("Recovery").resolvingSymlinksInPath().path
        guard !canonical.resolvingSymlinksInPath().path.hasPrefix(recovery + "/"),
              try StorageFiles.supported(canonical) else { throw NoteOperationError.unavailable }
        // Scope remains active through validation, bookmark creation, and all later file work.
        _ = try hooks.bookmark(canonical)
        return lease
    }

    func restore() throws -> FolderLease {
        try restore(from: CatalogPersistence.load(at: selectionURL)).lease
    }

    /// Resolves the default folder from an already-loaded catalog. `current` is true when the
    /// stored descriptor still names this folder with a fresh bookmark, so no rewrite is needed.
    func restore(from catalog: CollectionCatalog) throws -> (lease: FolderLease, current: Bool) {
        guard let stored = catalog.defaultFolder, let bookmark = stored.bookmark else {
            let lease = try acquire(defaultURL)
            return (lease, catalog.defaultFolder == NoteAccessDescriptor(url: lease.url, bookmark: nil, scope: .appContainer))
        }
        let resolved = try hooks.resolve(bookmark)
        let lease = try acquire(resolved.url)
        return (lease, !resolved.stale && stored.url == lease.url && lease.url != defaultURL.standardizedFileURL)
    }

    func commit(_ lease: FolderLease) throws {
        var catalog = try CatalogPersistence.load(at: selectionURL)
        try commit(lease, into: &catalog)
    }

    /// Saves the descriptor into `catalog`, which the caller loaded during this actor turn.
    func commit(_ lease: FolderLease, into catalog: inout CollectionCatalog) throws {
        let bookmark = lease.url == defaultURL.standardizedFileURL ? nil : try hooks.bookmark(lease.url)
        let descriptor = NoteAccessDescriptor(url: lease.url, bookmark: bookmark,
            scope: bookmark == nil ? .appContainer : .folder)
        guard catalog.defaultFolder != descriptor else { return }
        catalog.defaultFolder = descriptor
        try CatalogPersistence.save(catalog, at: selectionURL)
    }

    @MainActor static func chooseFolder() -> URL? {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = String(localized: "Choose Notes Folder", comment: "Button of the folder panel that selects the default notes folder")
        return picker.runModal() == .OK ? picker.url : nil
    }
}
