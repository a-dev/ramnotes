import ramnotesDomain
import Foundation

struct MetadataDiagnostic: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct MetadataLoad<Value: Sendable>: Sendable {
    let value: Value
    let diagnostic: MetadataDiagnostic?
}

actor MetadataStore {
    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let value: Value
    }

    private struct VersionHeader: Decodable { let version: Int }

    private let root: URL
    private let fileManager: FileManager
    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func loadSettings() -> MetadataLoad<AppSettings> {
        load(AppSettings.self, from: root.appendingPathComponent("settings.json"), fallback: AppSettings())
    }

    func saveSettings(_ settings: AppSettings) throws {
        try save(settings, to: root.appendingPathComponent("settings.json"))
    }


    func loadCollection() -> MetadataLoad<CollectionMetadata> {
        load(CollectionMetadata.self, from: root.appendingPathComponent("collection-metadata.json"), fallback: CollectionMetadata())
    }

    func saveCollection(_ metadata: CollectionMetadata) throws {
        try save(metadata, to: root.appendingPathComponent("collection-metadata.json"))
    }

    private func load<Value: Codable & Sendable>(_ type: Value.Type, from url: URL, fallback: Value) -> MetadataLoad<Value> {
        guard fileManager.fileExists(atPath: url.path) else { return .init(value: fallback, diagnostic: nil) }
        do {
            let value = try decode(type, from: Data(contentsOf: url))
            return .init(value: value, diagnostic: nil)
        } catch {
            return .init(value: fallback, diagnostic: .init(message: String(localized: "Unreadable metadata at \(url.path). The original file was preserved: \(error.localizedDescription)", comment: "Diagnostic in the note list. The first value is a file path, the second is the system error")))
        }
    }

    // Loading and the overwrite check must accept exactly the same schemas.
    private func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        let header = try decoder.decode(VersionHeader.self, from: data)
        guard header.version == 1 else {
            throw MetadataDiagnostic(message: String(localized: "Unsupported metadata version \(header.version).", comment: "Shown when the metadata file comes from a newer app version. The value is the version number"))
        }
        return try decoder.decode(Envelope<Value>.self, from: data).value
    }

    private func save<Value: Codable>(_ value: Value, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            // A corrupt or newer-version file is the only copy. Never overwrite it silently.
            let raw = try Data(contentsOf: url)
            do { _ = try decode(Value.self, from: raw) }
            catch {
                throw MetadataDiagnostic(message: String(localized: "Metadata at \(url.path) needs review before saving. The original file was preserved: \(error.localizedDescription)", comment: "Error when saving is blocked. The first value is a file path, the second is the system error"))
            }
        }
        try JSONEncoder().encode(Envelope(version: 1, value: value)).write(to: url, options: .atomic)
    }
}
