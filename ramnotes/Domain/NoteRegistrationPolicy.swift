import Foundation

public enum NoteAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case missingOriginal
    case trashed
}

/// Registration uniqueness is independent of the catalog's serialized shape.
public struct CollectionRegistration: Equatable, Sendable {
    public init(id: NoteID, parentResource: String?, path: String) {
        self.id = id
        self.parentResource = parentResource
        self.path = path
    }

    private let id: NoteID
    private let parentResource: String?
    private let path: String

    public func conflicts(with other: Self) -> Bool {
        id != other.id && parentResource == other.parentResource && path == other.path
    }
}

/// Authorization and matching text do not establish identity for access renewal.
public enum NoteFileIdentityPolicy {
    public static func permitsRenewal(tracked: String?, selected: String?) -> Bool {
        guard let tracked, let selected else { return false }
        return tracked == selected
    }
}

/// Controls removal from tracking without deleting the note file.
public enum NoteTrackingRemovalPolicy {
    /// Removing an unavailable note leaves its file on disk.
    /// A missing original stays only when a recheck finds it again.
    public static func permitsRemoval(availability: NoteAvailability, confirmedMissing: Bool) -> Bool {
        switch availability {
        case .available: false
        case .missingOriginal: confirmedMissing
        case .unavailable, .trashed: true
        }
    }
}
