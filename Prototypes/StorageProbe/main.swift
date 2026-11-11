import Foundation
import CryptoKit
import Darwin

struct Journal: Codable {
    let id: UUID
    let baseDigest: String?
    let originalName: String
    let text: String
    let revision: UInt64
}

enum ProbeError: Error { case usage, coordination, unsupportedEncoding }

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func coordinatedRead(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var result: Result<Data, Error>?
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { safeURL in
        result = Result { try Data(contentsOf: safeURL) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw ProbeError.coordination }
    return try result.get()
}

func coordinatedWrite(_ data: Data, to url: URL) throws {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { safeURL in
        result = Result { try data.write(to: safeURL, options: .atomic) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw ProbeError.coordination }
    try result.get()
}

func readJournal(_ url: URL) throws -> Journal {
    try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
}

func writeJournal(_ journal: Journal, to url: URL) throws {
    try JSONEncoder().encode(journal).write(to: url, options: .atomic)
}

func recoveryURL(_ root: URL, id: UUID) -> URL {
    root.appendingPathComponent("Recovery \(id.uuidString).txt")
}

func safeRecoveryURL(_ root: URL, id: UUID, text: Data) throws -> URL {
    let primary = recoveryURL(root, id: id)
    if !FileManager.default.fileExists(atPath: primary.path) { return primary }
    if try coordinatedRead(primary) == text {
        return primary
    }
    for suffix in 2...100 {
        let candidate = root.appendingPathComponent("Recovery \(id.uuidString)-\(suffix).txt")
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        if try coordinatedRead(candidate) == text {
            return candidate
        }
    }
    throw ProbeError.coordination
}

func reconcile(_ root: URL) throws -> String {
    let journalURL = root.appendingPathComponent("journal.json")
    let journal = try readJournal(journalURL)
    let originalURL = root.appendingPathComponent(journal.originalName)
    let disk = try coordinatedRead(originalURL)
    let diskDigest = disk.map(digest)
    if diskDigest == digest(Data(journal.text.utf8)) {
        try FileManager.default.removeItem(at: journalURL)
        return "saved-before-crash"
    }
    if diskDigest == journal.baseDigest {
        try coordinatedWrite(Data(journal.text.utf8), to: originalURL)
        try FileManager.default.removeItem(at: journalURL)
        return "saved-now"
    }
    let recoveryText = Data(journal.text.utf8)
    let recovery = try safeRecoveryURL(root, id: journal.id, text: recoveryText)
    if !FileManager.default.fileExists(atPath: recovery.path) {
        try recoveryText.write(to: recovery, options: .atomic)
    }
    guard try coordinatedRead(recovery) == recoveryText else { throw ProbeError.coordination }
    try FileManager.default.removeItem(at: journalURL)
    return disk == nil ? "missing-original-recovered" : "conflict-recovered"
}

func run() throws {
    guard CommandLine.arguments.count >= 3 else { throw ProbeError.usage }
    let operation = CommandLine.arguments[1]
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let original = root.appendingPathComponent("Note.txt")
    let journal = root.appendingPathComponent("journal.json")
    switch operation {
    case "setup":
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: original, options: .atomic)
        print("base=\(digest(try Data(contentsOf: original)))")
    case "journal":
        let base = try coordinatedRead(original).map(digest)
        try writeJournal(Journal(id: UUID(), baseDigest: base, originalName: "Note.txt", text: "local edit\n", revision: 1), to: journal)
        print("journaled")
    case "external-edit":
        try Data("external edit\n".utf8).write(to: original, options: .atomic)
        print("externally-edited")
    case "external-delete":
        try FileManager.default.removeItem(at: original)
        print("externally-deleted")
    case "occupy-recovery":
        let entry = try readJournal(journal)
        try Data("unrelated note\n".utf8).write(to: recoveryURL(root, id: entry.id), options: .atomic)
        print("recovery-name-occupied")
    case "replace":
        let entry = try readJournal(journal)
        try coordinatedWrite(Data(entry.text.utf8), to: original)
        print("replaced-before-journal-cleanup")
    case "recover":
        print(try reconcile(root))
    case "promotion-crash":
        let entry = try readJournal(journal)
        let recoveryText = Data(entry.text.utf8)
        let recovery = try safeRecoveryURL(root, id: entry.id, text: recoveryText)
        if !FileManager.default.fileExists(atPath: recovery.path) {
            try recoveryText.write(to: recovery, options: .atomic)
        }
        guard try coordinatedRead(recovery) == recoveryText else { throw ProbeError.coordination }
        print("recovery-written-before-journal-cleanup")
        fflush(stdout)
        Darwin._exit(99)
    case "journal-loop":
        let base = try coordinatedRead(original).map(digest)
        let id = UUID()
        let start = ProcessInfo.processInfo.systemUptime
        var lastJournal = start
        for revision in 1...100 {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = Int((now - start) * 1000)
            print("edit=\(revision) elapsedMs=\(elapsed)")
            fflush(stdout)
            if now - lastJournal >= 0.25 {
                try writeJournal(Journal(id: id, baseDigest: base, originalName: "Note.txt", text: "edit \(revision)\n", revision: UInt64(revision)), to: journal)
                print("journal=\(revision) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
                fflush(stdout)
                lastJournal = ProcessInfo.processInfo.systemUptime
            }
            usleep(10_000)
        }
    case "identity":
        let before = try original.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let renamed = root.appendingPathComponent("Renamed.txt")
        try FileManager.default.moveItem(at: original, to: renamed)
        let afterRename = try renamed.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        try Data("replacement\n".utf8).write(to: renamed, options: .atomic)
        let afterReplace = try renamed.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        print("rename-preserved=\(String(describing: before) == String(describing: afterRename)) atomic-replace-preserved=\(String(describing: afterRename) == String(describing: afterReplace))")
    case "trash":
        var trashed: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        guard let trashedURL = trashed as URL? else { throw ProbeError.coordination }
        print("trashed=\(trashedURL.path)")
        if !FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.moveItem(at: trashedURL, to: original)
            print("restored")
        }
    case "trash-collision":
        var trashed: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        guard let trashedURL = trashed as URL? else { throw ProbeError.coordination }
        try Data("new occupant\n".utf8).write(to: original, options: .atomic)
        var restored = root.appendingPathComponent("Note (restored).txt")
        var suffix = 2
        while FileManager.default.fileExists(atPath: restored.path) {
            restored = root.appendingPathComponent("Note (restored \(suffix)).txt")
            suffix += 1
        }
        try FileManager.default.moveItem(at: trashedURL, to: restored)
        guard try Data(contentsOf: original) == Data("new occupant\n".utf8),
              try Data(contentsOf: restored) == Data("base\n".utf8) else { throw ProbeError.coordination }
        print("restored-as=\(restored.lastPathComponent) occupant-preserved=true")
    default:
        throw ProbeError.usage
    }
}

do { try run() } catch { fputs("StorageProbe: \(error)\n", stderr); exit(1) }
