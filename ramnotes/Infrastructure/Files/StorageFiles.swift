import ramnotesDomain
import Foundation
import AppKit
import CryptoKit
import Darwin

/// Synchronous file operations. Call blocking operations outside the main actor.
enum StorageFiles {
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func childNames(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    /// The hard-link count, or nil when the file system does not report one.
    static func linkCount(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.referenceCount] as? NSNumber)?.intValue
    }

    static func startDownloading(_ url: URL) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }

    static func digest(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) { out.append(hex[Int(byte >> 4)]); out.append(hex[Int(byte & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func resourceID(_ url: URL) throws -> String {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try stableID(fresh) ?? "path:\(url.standardizedFileURL.path)"
    }

    /// Volume UUID plus file ID. Both stay the same when the volume is ejected and mounted again,
    /// unlike volumeIdentifier and fileResourceIdentifier, which change on every mount.
    /// Nil when the file system gives no volume UUID or file ID (for example, some FAT and network volumes).
    private static func stableID(_ url: URL) throws -> String? {
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        guard let volume = values.volumeUUIDString, let file = values.fileIdentifier else { return nil }
        return "vol:\(volume):\(file)"
    }

    /// Nil when there is no file ID. Note identities keep the nil. Folder keys can fall back to the path.
    static func fileResourceID(_ url: URL) throws -> String? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try stableID(fresh)
    }

    /// Cheap check that a file is unchanged. ctime catches a same-size rewrite that restores
    /// an old mtime. The resource ID catches atomic replacement.
    struct Stamp: Equatable {
        let resource: String
        let size: Int
        let modified: Date
        let changed: Date
        let downloading: URLUbiquitousItemDownloadingStatus?
        let created: Date?
        /// Whether the file has the filesystem's dataless flag.
        var dataless = false

        /// Eviction keeps the file ID, size, and content date, and changes only ctime and
        /// the dataless flag. A match means the evicted file holds the cached bytes.
        func isEvictedCopy(of downloaded: Stamp) -> Bool {
            dataless && !downloaded.dataless && resource == downloaded.resource
                && size == downloaded.size && modified == downloaded.modified
        }
    }

    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Nil when the file system can't give every field. The caller must then read the file.
    static func stamp(_ url: URL) throws -> Stamp? {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey,
                                                      .attributeModificationDateKey, .ubiquitousItemDownloadingStatusKey,
                                                      .creationDateKey])
        guard let resource = values.fileResourceIdentifier, let size = values.fileSize,
              let modified = values.contentModificationDate, let changed = values.attributeModificationDate else { return nil }
        return Stamp(resource: String(describing: resource), size: size, modified: modified, changed: changed,
                     downloading: values.ubiquitousItemDownloadingStatus, created: values.creationDate,
                     dataless: isDataless(url))
    }

    static func supported(_ url: URL) throws -> Bool {
        guard url.pathExtension.lowercased() == "txt" else { return false }
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        return values.isRegularFile == true && values.isSymbolicLink != true && values.isPackage != true
    }

    static func read(_ url: URL, readBody: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
                     startDownload: (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
                     isPlaceholder: (URL) throws -> Bool = {
                         try $0.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus == .notDownloaded
                     }) throws -> (text: String, revision: FileRevision) {
        guard try supported(url) else { throw NoteOperationError.unavailable }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard try !isPlaceholder(url) else {
            // File events and app activation reconcile availability after the request.
            throw cloudPlaceholderFailure(at: url, startDownload: startDownload)
        }
        let data = try coordinatedRead(url, readBody: readBody)
        let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        guard let text = String(data: body, encoding: .utf8) else { throw NoteOperationError.unsupportedEncoding }
        return (text, FileRevision(fingerprint: digest(data), modifiedAt: values.contentModificationDate ?? .distantPast))
    }

    private static func cloudPlaceholderFailure(at url: URL, startDownload: (URL) throws -> Void) -> NoteOperationError {
        do {
            try startDownload(url)
            return .accessFailure(NoteAccessFailure(reason: .cloudPlaceholder, domain: NSCocoaErrorDomain, code: 0,
                message: LocalizedStringResource("iCloud download requested…", comment: "Note unavailable: the iCloud download was started")))
        } catch {
            let failure = error as NSError, reason = error.localizedDescription
            return .accessFailure(NoteAccessFailure(reason: .cloudPlaceholder, domain: failure.domain, code: failure.code,
                message: LocalizedStringResource("Could not request the iCloud download: \(reason). Open the note again to retry.", comment: "Note unavailable; value is the system error")))
        }
    }

    static func creationDate(_ url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func coordinatedRead(_ url: URL, readBody: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var failure: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &failure) { safeURL in
            result = Result {
                guard try supported(safeURL) else { throw NoteOperationError.unavailable }
                return try readBody(safeURL)
            }
        }
        if let failure { throw failure }
        guard let result else { throw NoteOperationError.unavailable }
        return try result.get()
    }

    /// Export targets come from a Save panel. When the file exists, the user has already
    /// confirmed Replace, so overwrite it in place. The sandbox grants only that URL.
    static func export(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        else { try create(data, at: url) }
        guard try Data(contentsOf: url) == data else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Export verification failed", comment: "Error when an exported file does not match the text"))
        }
    }

    /// O_EXCL decides name clashes. An existence check first would race.
    static func create(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        // The file is ours (O_EXCL). A partial file would block every retry with EEXIST.
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    offset += count
                }
            }
            try barrier(descriptor)
        } catch {
            unlink(url.path)
            throw error
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    /// Prefix of our temporary files. Events for them are never external edits.
    static let temporaryPrefix = ".ramnotes-"

    /// Best effort. Removes regular `.ramnotes-*` files that a crash left behind and that nothing
    /// has written for `age` seconds. `lstat` means a symlink is never followed or removed.
    static func removeStaleTemporaries(among children: [URL], olderThan age: TimeInterval = 600, now: Date = Date()) {
        for url in children where url.lastPathComponent.hasPrefix(temporaryPrefix) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func atomic(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(temporaryPrefix + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try create(data, at: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func encoded(_ text: String, preserving original: Data) -> Data {
        let bom = original.starts(with: [0xef, 0xbb, 0xbf])
        // Take the newline style from the first line break in the bytes. No full decode.
        let newline: String
        if let cr = original.firstIndex(where: { $0 == 0x0d || $0 == 0x0a }), original[cr] == 0x0d {
            newline = original.index(after: cr) < original.endIndex && original[original.index(after: cr)] == 0x0a ? "\r\n" : "\r"
        } else { newline = "\n" }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var data = bom ? Data([0xef, 0xbb, 0xbf]) : Data()
        data.append(Data(normalized.replacingOccurrences(of: "\n", with: newline).utf8))
        return data
    }

    /// Checkpoint flush. `F_BARRIERFSYNC` orders this write before later ones on the drive,
    /// so checkpoint ordering survives power loss. It does not flush the drive cache
    /// (`F_FULLFSYNC` does, at a high cost). Falls back to `fsync` where unsupported.
    static func barrier(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_BARRIERFSYNC) == -1, fsync(descriptor) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        try barrier(descriptor)
    }

    /// A deleted ancestor also makes the selected folder missing. Stop at the
    /// volume boundary so an unmounted external disk is not treated as deletion.
    static func isFolderMissing(_ url: URL) -> Bool {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if candidate.deletingLastPathComponent().path == "/Volumes" { return false }
            do {
                _ = try FileManager.default.attributesOfItem(atPath: candidate.path)
                return false
            } catch {
                let error = error as NSError
                guard error.domain == NSCocoaErrorDomain,
                      error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError else { return false }
                if isMissing(candidate) { return true }
                candidate = candidate.deletingLastPathComponent()
            }
        }
        return false
    }

    static func isMissing(_ url: URL) -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return false }
        catch {
            let ns = error as NSError
            // Access denied or a lost volume is never a deletion.
            guard ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError ||
                    ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError else { return false }
            // If the parent is reachable, the volume is present. One stat, no folder listing.
            return (try? url.deletingLastPathComponent().checkResourceIsReachable()) == true
        }
    }

}

/// Explicit safe saving only. NoteStore owns coordination, journaling, and autosave scheduling.
/// Each instance is confined to one synchronous call on the storage actor.
private final class FileSaveDocument: NSDocument {
    nonisolated let bytes: Data
    nonisolated let afterStaging: @Sendable () throws -> Void
    init(bytes: Data, afterStaging: @escaping @Sendable () throws -> Void) {
        self.bytes = bytes
        self.afterStaging = afterStaging
        super.init()
    }
    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, originalContentsURL: URL?) throws {
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: originalContentsURL)
        try afterStaging()
    }
    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }
    nonisolated override func data(ofType typeName: String) throws -> Data { bytes }
}

extension StorageFiles {
    static func saveAuthorizedFile(_ data: Data, at url: URL, afterStaging: @escaping @Sendable () throws -> Void = {}) throws {
        let document = FileSaveDocument(bytes: data, afterStaging: afterStaging)
        document.fileURL = url
        document.fileType = "public.plain-text"
        defer { document.close() }
        try document.writeSafely(to: url, ofType: "public.plain-text", for: .saveOperation)
    }
}
