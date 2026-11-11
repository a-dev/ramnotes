import ramnotesDomain
import Foundation

protocol NoteTrashing: Sendable {
    func moveToTrash(_ id: NoteID, collectionToken: CollectionToken) async throws
}

/// A presentation-owned editor grants one lock and completes composition before flushing.
@MainActor
struct DeletionEditor {
    let flush: () async throws -> Void
    let release: () -> Void
}

/// Serializes guarded deletion batches while leaving file effects to NoteStore.
@MainActor
final class DeletionWorkflow {
    private var deleting: Set<NoteID> = []

    struct BatchResult {
        var succeeded = 0
        var failures: [(NoteSnapshot, Error)] = []
    }

    func delete(_ notes: [NoteSnapshot], in token: CollectionToken, using storage: any NoteTrashing,
                isCurrent: () -> Bool, canProceed: () -> Bool, editor: (NoteID) -> DeletionEditor?,
                didDelete: (NoteID) -> Void) async -> BatchResult {
        guard notes.allSatisfy({ !deleting.contains($0.id) }) else { return BatchResult() }
        let ids = Set(notes.map(\.id))
        deleting.formUnion(ids)
        defer { deleting.subtract(ids) }
        var result = BatchResult()
        for note in notes {
            guard canProceed(), isCurrent(), note.collectionToken == token else { break }
            let editing = editor(note.id)
            defer { editing?.release() }
            do {
                try await editing?.flush()
                try await storage.moveToTrash(note.id, collectionToken: token)
                guard isCurrent() else { break }
                didDelete(note.id)
                result.succeeded += 1
            } catch { result.failures.append((note, error)) }
        }
        return result
    }
}
