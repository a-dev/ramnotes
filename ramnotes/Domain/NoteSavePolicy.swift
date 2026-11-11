import Foundation

public struct NoteSaveState: Sendable {
    public private(set) var currentRevision = EditRevision(rawValue: 0)
    public private(set) var savedRevision = EditRevision(rawValue: 0)

    public init(savedRevision: EditRevision = EditRevision(rawValue: 0), currentRevision: EditRevision? = nil) {
        self.savedRevision = savedRevision
        self.currentRevision = currentRevision ?? savedRevision
    }

    public mutating func edited() -> EditRevision {
        currentRevision = EditRevision(rawValue: currentRevision.rawValue + 1)
        return currentRevision
    }

    public mutating func completedSave(revision: EditRevision) {
        if revision <= currentRevision, revision > savedRevision {
            savedRevision = revision
        }
    }

    public var hasUnsavedEdits: Bool { savedRevision < currentRevision }
}

/// Inputs describe bytes and identities already observed under file coordination.
public enum NoteSavePolicy {
    public enum Decision: Equatable { case unchanged, replace, conflict, unsupportedEncoding }

    public static func decide(equalContent: Bool, diskFingerprint: String, baseFingerprint: String?,
                       lastWrittenFingerprint: String?, ownBaseFingerprints: Set<String>,
                       validEncoding: Bool) -> Decision {
        let ownAdvance = lastWrittenFingerprint == diskFingerprint &&
            baseFingerprint.map { ownBaseFingerprints.contains($0) } == true
        guard equalContent || diskFingerprint == baseFingerprint || ownAdvance else { return .conflict }
        guard validEncoding else { return .unsupportedEncoding }
        return equalContent ? .unchanged : .replace
    }
}

/// A journal alone is not proof that an editor's only copy can be discarded.
public struct RetainedEditPolicy {
    public init(writing: Bool, pendingRevision: EditRevision?, recoverableRevision: EditRevision?) {
        self.writing = writing
        self.pendingRevision = pendingRevision
        self.recoverableRevision = recoverableRevision
    }

    private let writing: Bool
    private let pendingRevision: EditRevision?
    private let recoverableRevision: EditRevision?

    public var canDispose: Bool {
        !writing && (pendingRevision == nil || pendingRevision == recoverableRevision)
    }

    public static func acceptsLocation(current: LocationRevision?, requested: LocationRevision,
                                hasKnownLocation: Bool, recovered: Bool) -> Bool {
        if let current { return current.matches(requested) }
        return hasKnownLocation && recovered
    }
}
