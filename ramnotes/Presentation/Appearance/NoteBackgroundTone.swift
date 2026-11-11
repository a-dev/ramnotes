import ramnotesDomain
import Foundation

// A tone from a newer version must not break the rest of the folder's metadata.
enum NoteBackgroundTone: String, Codable, CaseIterable, Sendable {
    case gray, blue, green, yellow, red, purple
}

extension NoteBackgroundTone {
    /// Display name only. `rawValue` stays the stored value.
    var localizedName: String {
        switch self {
        case .gray: String(localized: "Gray", comment: "Background tint color name")
        case .blue: String(localized: "Blue", comment: "Background tint color name")
        case .green: String(localized: "Green", comment: "Background tint color name")
        case .yellow: String(localized: "Yellow", comment: "Background tint color name")
        case .red: String(localized: "Red", comment: "Background tint color name")
        case .purple: String(localized: "Purple", comment: "Background tint color name")
        }
    }
    static var noColorName: String { String(localized: "No color", comment: "Background tint menu: no tint") }
    static func localizedName(_ tone: NoteBackgroundTone?) -> String { tone?.localizedName ?? noColorName }
}

@propertyWrapper
struct OptionalBackgroundTone: Codable, Equatable, Sendable {
    var wrappedValue: NoteBackgroundTone?
    init(wrappedValue: NoteBackgroundTone?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        wrappedValue = raw.flatMap(NoteBackgroundTone.init(rawValue:))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue?.rawValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: OptionalBackgroundTone.Type, forKey key: Key) throws -> OptionalBackgroundTone {
        try decodeIfPresent(type, forKey: key) ?? .init(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: OptionalBackgroundTone, forKey key: Key) throws {
        if value.wrappedValue != nil { try encodeIfPresent(value, forKey: key) }
    }
}
