import Foundation

/// Forward progress requires each preceding durable checkpoint. Abandoning an
/// untouched prepared intent is a separate application decision.
public enum LocationOperationStage: String, Codable, CaseIterable, Sendable {
    case prepared, destinationVerified, sourceRemoved, catalogCommitted, complete

    public func canAdvance(to next: Self) -> Bool {
        switch (self, next) {
        case (.prepared, .destinationVerified), (.destinationVerified, .sourceRemoved),
             (.sourceRemoved, .catalogCommitted), (.catalogCommitted, .complete): true
        default: false
        }
    }
}

/// Evidence captured by the application before a location effect. Optional fields
/// preserve interrupted legacy records without granting permission to execute them.
public struct LocationOperationState: Equatable, Sendable {
    public enum Failure: Error, Equatable { case missingEvidence, invalidTransition }

    public let noteID: NoteID
    public let sourceID: NoteID
    public let sourceResource: String?
    public let sourceParentResource: String?
    public let expectedFileRevision: FileRevision?
    public let destinationParentResource: String?
    public let destinationName: String?
    public private(set) var stage: LocationOperationStage
    public private(set) var destinationResource: String?

    public init(noteID: NoteID, sourceID: NoteID, sourceResource: String?, sourceParentResource: String?,
                expectedFileRevision: FileRevision?, destinationParentResource: String?, destinationName: String?,
                stage: LocationOperationStage, destinationResource: String?) {
        self.noteID = noteID
        self.sourceID = sourceID
        self.sourceResource = sourceResource
        self.sourceParentResource = sourceParentResource
        self.expectedFileRevision = expectedFileRevision
        self.destinationParentResource = destinationParentResource
        self.destinationName = destinationName
        self.stage = stage
        self.destinationResource = destinationResource
    }

    public func validateForExecution() throws {
        guard noteID == sourceID, sourceResource != nil, sourceParentResource != nil,
              expectedFileRevision != nil, destinationParentResource != nil,
              let destinationName, NoteFilename(destinationName) != nil,
              stage == .prepared || destinationResource != nil else { throw Failure.missingEvidence }
    }

    public mutating func verifyDestination(_ resource: String) throws {
        try validateForExecution()
        guard stage == .prepared, !resource.isEmpty else { throw Failure.invalidTransition }
        destinationResource = resource
        stage = .destinationVerified
    }

    public mutating func advance(to next: LocationOperationStage) throws {
        try validateForExecution()
        guard stage.canAdvance(to: next), next != .destinationVerified else { throw Failure.invalidTransition }
        stage = next
    }

    /// The application must verify the original before abandoning a prepared intent.
    public mutating func abandonPrepared() throws {
        guard stage == .prepared, destinationResource == nil else { throw Failure.invalidTransition }
        stage = .complete
    }
}

/// What the catalog may forget once work is done. A finished operation is evidence only while
/// an unsettled default-folder batch can still look for it. A batch is history once it has settled
/// and every entry moved; a failed entry keeps its batch because Retry reads it.
public enum CatalogRetention {
    public static func canDropOperation(stage: LocationOperationStage, referencedByRetainedBatch: Bool) -> Bool {
        stage == .complete && !referencedByRetainedBatch
    }

    public static func canDropBatch(settled: Bool, allEntriesMoved: Bool) -> Bool {
        settled && allEntriesMoved
    }
}
