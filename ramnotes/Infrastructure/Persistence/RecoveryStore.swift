import ramnotesDomain
import Foundation

enum StorageStage: Sendable, CaseIterable { case journal, beforeReplacement, destination, afterReplacement, promotion, promotionCreated, promotionCatalog, trash, folderAccess, movePrepared, moveFilesystem, moveAfterFilesystem, moveAfterSourceRemoval, moveVerified, moveSourceRemoval, moveSourceRemoved, moveCatalog, moveComplete, defaultPrepared, defaultCommit, defaultCommitted, defaultEntry, defaultAfterMove, defaultCheckpoint, defaultComplete, copyVerification, copyCatalog, accessMigrationCatalog }
typealias StorageFault = @Sendable (StorageStage) throws -> Void

/// NoteStore calls this synchronously, so a journal and its save never interleave.
struct RecoveryStore: Sendable {
    let root: URL
    let fault: StorageFault

    /// Checks the record on disk before replacing it. Returns false if the disk record is newer.
    @discardableResult
    func persist(_ record: RecoveryRecord) throws -> Bool {
        try fault(.journal)
        if FileManager.default.fileExists(atPath: url(record.noteID).path) {
            guard let previous = try Self.decode(Data(contentsOf: url(record.noteID))) else {
                throw NoteOperationError.inputOutput(LocalizedStringResource("Existing recovery record needs review", comment: "Error when a recovery journal conflicts with an existing record"))
            }
            guard previous.noteID == record.noteID else { throw NoteOperationError.inputOutput(LocalizedStringResource("Existing recovery identity mismatch", comment: "Error when a recovery journal belongs to a different note")) }
            guard previous.editRevision <= record.editRevision else { return false }
        }
        try store(record)
        return true
    }

    /// Replaces the record without reading it first. Use only if the caller wrote that record.
    func write(_ record: RecoveryRecord) throws {
        try fault(.journal)
        try store(record)
    }

    private func store(_ record: RecoveryRecord) throws {
        let data = try Self.encode(record)
        try StorageFiles.atomic(data, at: url(record.noteID))
    }

    /// Detaches an old binding's text from the active per-note journal slot.
    func retain(_ record: RecoveryRecord) throws {
        let directory = root.appendingPathComponent("Retained", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encode(record)
        try StorageFiles.atomic(data, at: directory.appendingPathComponent(record.id.uuidString + ".json"))
        try StorageFiles.syncDirectory(root)
    }

    func load() -> (records: [RecoveryRecord], diagnostics: [String]) {
        var records: [RecoveryRecord] = []
        var diagnostics: [String] = []
        do {
            let retained = root.appendingPathComponent("Retained", isDirectory: true)
            let activeFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let retainedFiles = FileManager.default.fileExists(atPath: retained.path)
                ? try FileManager.default.contentsOfDirectory(at: retained, includingPropertiesForKeys: nil) : []
            for file in activeFiles + retainedFiles where file.pathExtension == "json" {
                do {
                    guard let record = try Self.decode(Data(contentsOf: file)) else {
                        throw NoteOperationError.inputOutput(LocalizedStringResource("Invalid recovery checksum or version", comment: "Error when a recovery journal file is damaged or from an unsupported version"))
                    }
                    guard file == url(record.noteID) || (record.trackingRemoved && file == retained.appendingPathComponent(record.id.uuidString + ".json")) else { throw NoteOperationError.inputOutput(LocalizedStringResource("Recovery identity mismatch", comment: "Error when a recovery journal file belongs to a different note")) }
                    if !records.contains(where: { $0.id == record.id }) { records.append(record) }
                } catch { diagnostics.append(String(localized: "Recovery record preserved at \(file.path): \(error.localizedDescription)", comment: "Diagnostic in the note list. The first value is a file path, the second is the system error")) }
            }
        } catch { diagnostics.append(String(localized: "Recovery directory unavailable: \(error.localizedDescription)", comment: "Diagnostic in the note list. The value is the system error")) }
        return (records, diagnostics)
    }

    func remove(_ id: NoteID, through revision: EditRevision) throws {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let record = try Self.decode(Data(contentsOf: file)) else { throw NoteOperationError.unavailable }
        guard record.editRevision <= revision else { return }
        try FileManager.default.removeItem(at: file)
        try StorageFiles.syncDirectory(root)
    }

    /// Deletes the active and every retained journal of the note.
    func forget(_ id: NoteID) throws {
        try forget([id]).first.map { throw $0.value }
    }

    /// Deletes the active and retained journals of each note, reading the journals once.
    /// Returns the failure of each note whose files could not be removed; the others are still cleaned.
    @discardableResult
    func forget(_ ids: Set<NoteID>) throws -> [NoteID: Error] {
        let retained = root.appendingPathComponent("Retained", isDirectory: true)
        var failures: [NoteID: Error] = [:]
        for record in load().records where ids.contains(record.noteID) && failures[record.noteID] == nil {
            for file in [url(record.noteID), retained.appendingPathComponent(record.id.uuidString + ".json")]
            where FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) } catch { failures[record.noteID] = error; break }
            }
        }
        try StorageFiles.syncDirectory(root)
        return failures
    }

    /// Version-two wire format: three header lines, then the raw UTF-8 note text.
    ///
    ///     RAMNOTES-JOURNAL 2\n
    ///     <record metadata as one-line JSON, without "text">\n
    ///     <SHA-256 hex of metadata line + "\n" + body>\n
    ///     <body>
    ///
    /// The body is never escaped or base64-encoded, so a journal costs about the note size.
    static let magic = Data("RAMNOTES-JOURNAL 2\n".utf8)

    static func encode(_ record: RecoveryRecord) throws -> Data {
        guard var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        fields["text"] = nil
        let metadata = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let body = Data(record.text.utf8)
        var data = magic
        data.reserveCapacity(magic.count + metadata.count + body.count + 66)
        data.append(metadata)
        data.append(0x0a)
        data.append(Data(StorageFiles.digest(metadata + [0x0a] + body).utf8))
        data.append(0x0a)
        data.append(body)
        return data
    }

    /// Returns nil for an unsupported version or a bad checksum. Each caller reports its own error.
    /// Malformed content still throws its decoding error. Reads the version-one JSON envelope too.
    static func decode(_ data: Data) throws -> RecoveryRecord? {
        guard data.starts(with: magic) else { return try decodeLegacy(data) }
        let rest = data.dropFirst(magic.count)
        guard let metadataEnd = rest.firstIndex(of: 0x0a),
              let checksumEnd = rest[(metadataEnd + 1)...].firstIndex(of: 0x0a) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let metadata = Data(rest[..<metadataEnd])
        let checksum = String(decoding: rest[(metadataEnd + 1)..<checksumEnd], as: UTF8.self)
        let body = Data(rest[(checksumEnd + 1)...])
        guard StorageFiles.digest(metadata + [0x0a] + body) == checksum else { return nil }
        guard var fields = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let text = String(data: body, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        fields["text"] = text
        return try JSONDecoder().decode(RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    /// Version one: a JSON envelope around the JSON record (base64) and its digest.
    struct LegacyEnvelope: Codable {
        let version: Int
        let payload: Data
        let checksum: String
    }

    private static func decodeLegacy(_ data: Data) throws -> RecoveryRecord? {
        let envelope = try JSONDecoder().decode(LegacyEnvelope.self, from: data)
        guard envelope.version == 1, StorageFiles.digest(envelope.payload) == envelope.checksum else { return nil }
        return try JSONDecoder().decode(RecoveryRecord.self, from: envelope.payload)
    }

    func url(_ id: NoteID) -> URL { root.appendingPathComponent(id.rawValue.uuidString + ".json") }
}


/// The only way to write journals. `journaled` holds the last record written per note, so a
/// known record needs no re-read and an unchanged one needs no write. After a failed write,
/// the entry is dropped and the next write checks the disk again.
struct JournalWriter: Sendable {
    let store: RecoveryStore
    private(set) var journaled: [NoteID: RecoveryRecord] = [:]

    init(store: RecoveryStore) { self.store = store }

    mutating func persist(_ record: RecoveryRecord) throws {
        let id = record.noteID
        do {
            if let last = journaled[id] {
                if last == record { return }
                guard last.editRevision <= record.editRevision else { return }
                try store.write(record)
            } else {
                guard try store.persist(record) else { return }
            }
            journaled[id] = record
        } catch {
            journaled[id] = nil
            throw error
        }
    }

    mutating func remove(_ id: NoteID, through revision: EditRevision) throws {
        journaled[id] = nil
        try store.remove(id, through: revision)
    }

    mutating func forget(_ id: NoteID) throws {
        journaled[id] = nil
        try store.forget(id)
    }

    /// Batch form of `forget`: one journal read for all notes. Returns per-note failures.
    mutating func forget(_ ids: Set<NoteID>) throws -> [NoteID: Error] {
        for id in ids { journaled[id] = nil }
        return try store.forget(ids)
    }
}
