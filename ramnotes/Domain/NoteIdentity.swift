import Foundation

public struct NoteID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct CollectionToken: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct FileRevision: Hashable, Codable, Sendable {
    public init(fingerprint: String, modifiedAt: Date) {
        self.fingerprint = fingerprint
        self.modifiedAt = modifiedAt
    }

    public let fingerprint: String
    public let modifiedAt: Date
}

public struct EditRevision: Hashable, Comparable, Codable, Sendable {
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public let rawValue: UInt64
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LocationRevision: Hashable, Codable, Sendable {
    public init(rawValue: UInt64 = 0) { self.rawValue = rawValue }

    public private(set) var rawValue: UInt64 = 0

    public func matches(_ requested: Self) -> Bool { self == requested }
    public func advanced() -> Self { Self(rawValue: rawValue + 1) }
    public mutating func advance() { self = advanced() }
}
