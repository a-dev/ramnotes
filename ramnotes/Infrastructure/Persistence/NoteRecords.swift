import ramnotesDomain
import Foundation

struct RecoveryRecord: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case conflict, missingOriginal, saveFailure }
    let id: UUID
    let noteID: NoteID
    let collectionToken: CollectionToken
    let originalURL: URL
    var folderIdentity: String? = nil
    var originalResourceIdentity: String? = nil
    let baseRevision: FileRevision?
    let editRevision: EditRevision
    let text: String
    let createdAt: Date
    let reason: Reason
    var trackingRemoved = false
    var promotionURL: URL? = nil
    var promotionAccess: NoteAccessDescriptor? = nil
    var promotionParentResource: String? = nil
    var promotionResource: String? = nil
    var promotedNoteID: NoteID?
}

struct NoteAccessDescriptor: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case appContainer, folder, file }
    var url: URL
    var bookmark: Data?
    var scope: Scope
}

struct NoteLocationRecord: Codable, Equatable, Sendable {
    let id: NoteID
    var resource: String?
    var path: String
    var parentResource: String? = nil
    var access: NoteAccessDescriptor? = nil
    var fileAccess: NoteAccessDescriptor? = nil
    var availability: NoteAvailability = .available
    var revision = LocationRevision()
}

struct LocationOperation: Codable, Equatable, Sendable {
    // Save the intent before touching files. After a copy, the source still needs a recheck
    // and delete. After a move, the catalog still needs the new location.
    typealias Stage = LocationOperationStage
    let id: UUID
    let noteID: NoteID
    let source: NoteLocationRecord
    var destination: NoteAccessDescriptor
    let expectedEditRevision: EditRevision
    var stage: Stage
    var expectedFileRevision: FileRevision? = nil
    var destinationResource: String? = nil
    var destinationParentResource: String? = nil
    var crossVolume = false
    var destinationName: String? = nil


}

/// One saved default-folder change. Each entry's destination is saved before its move.
/// A finished entry never runs again, even after a later change.
struct DefaultFolderBatch: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case running, paused, settled }
    struct Entry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case pending, moved, failed }
        let source: NoteLocationRecord
        var destination: URL
        var state: State = .pending
        var operationID: UUID? = nil
        var message: String? = nil
    }
    let id: UUID
    let decision: UUID
    let sourceFolder: URL
    let sourceResource: String?
    var destination: NoteAccessDescriptor
    let destinationResource: String
    let moveExisting: Bool
    var state: State
    var entries: [Entry]
}

struct CollectionCatalog: Codable, Equatable, Sendable {
    var version = 1
    var defaultFolder: NoteAccessDescriptor? = nil
    var notes: [NoteID: NoteLocationRecord] = [:]
    var operations: [UUID: LocationOperation] = [:]
    var recoveryLinks: [UUID: RecoveryNotice] = [:]
    var defaultDecision = UUID()
    var defaultBatches: [UUID: DefaultFolderBatch] = [:]

    /// The one place that knows every catalog field holding a NoteID. Forgetting a note
    /// drops its registration, unfinished move, default-folder batch entry, and recovery
    /// links. Add any new NoteID-keyed field here.
    func forgetting(_ ids: Set<NoteID>) -> CollectionCatalog {
        guard !ids.isEmpty else { return self }
        var copy = self
        for id in ids { copy.notes[id] = nil }
        copy.operations = operations.filter { !ids.contains($0.value.noteID) }
        copy.defaultBatches = defaultBatches.compactMapValues { batch in
            var batch = batch
            batch.entries.removeAll { ids.contains($0.source.id) }
            return batch.entries.isEmpty ? nil : batch
        }
        copy.recoveryLinks = recoveryLinks.filter { _, link in
            !ids.contains(link.recoveryNoteID) && !(link.sourceNoteID.map(ids.contains) ?? false)
        }
        return copy
    }

    /// Drops catalog data that points at unregistered notes: recovery links whose source and
    /// recovery notes are both gone, and default-folder batch entries whose note is gone.
    /// Catalogs saved before `forgetting` pruned batches can hold such entries; they would
    /// fail with a stale location on every retry.
    func pruningOrphans() -> CollectionCatalog {
        var copy = self
        copy.defaultBatches = defaultBatches.compactMapValues { batch in
            var batch = batch
            batch.entries.removeAll { notes[$0.source.id] == nil }
            return batch.entries.isEmpty ? nil : batch
        }
        copy.recoveryLinks = recoveryLinks.filter { _, link in
            notes[link.recoveryNoteID] != nil || (link.sourceNoteID.map { notes[$0] != nil } ?? false)
        }
        return copy
    }

    /// Drops settled batches whose entries all moved, then finished operations that no remaining
    /// batch entry refers to. Unfinished operations and batches stay for recovery and Retry.
    func pruningFinished() -> CollectionCatalog {
        var copy = self
        copy.defaultBatches = defaultBatches.filter { _, batch in
            !CatalogRetention.canDropBatch(settled: batch.state == .settled, allEntriesMoved: batch.entries.allSatisfy { $0.state == .moved })
        }
        let referenced = Set(copy.defaultBatches.values.flatMap { $0.entries.map(\.source.id) })
        copy.operations = operations.filter { _, operation in
            !CatalogRetention.canDropOperation(stage: operation.stage, referencedByRetainedBatch: referenced.contains(operation.noteID))
        }
        return copy
    }
}
