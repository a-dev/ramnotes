import Foundation

/// Version-one catalog codec and corruption-preserving atomic persistence.
enum CatalogPersistence {
    static func load(at url: URL) throws -> CollectionCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else { return CollectionCatalog() }
        let value = try JSONDecoder().decode(CollectionCatalog.self, from: Data(contentsOf: url))
        try validate(value)
        return value
    }
    static func validate(_ value: CollectionCatalog) throws {
        let version = value.version, notes = value.notes, operations = value.operations, defaultBatches = value.defaultBatches
        guard version == 1, notes.allSatisfy({ $0.key == $0.value.id }),
              Set(notes.values.map { [$0.parentResource ?? "", $0.path] }).count == notes.count,
              operations.allSatisfy({ $0.key == $0.value.id && $0.value.noteID == $0.value.source.id }),
              defaultBatches.allSatisfy({ $0.key == $0.value.id && Set($0.value.entries.map { $0.source.id }).count == $0.value.entries.count }) else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("The collection catalog is invalid or unsupported. Its original file was preserved.", comment: "Error when the catalog file of tracked notes cannot be read"))
        }
    }
    static func save(_ value: CollectionCatalog, at url: URL) throws {
        try validate(value)
        // Never overwrite a corrupt file, even one that became corrupt after startup.
        _ = try Self.load(at: url)
        try StorageFiles.atomic(JSONEncoder().encode(value), at: url)
    }
}
