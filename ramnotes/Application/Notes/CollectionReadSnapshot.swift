import ramnotesDomain
import Foundation

/// Note facts, retained edits, and recovery results from one store read, so a load, reconnect,
/// or default-folder change publishes a consistent view. Window metadata is not part of it.
struct CollectionReadSnapshot: Sendable {
    let notes: [NoteID: NoteSnapshot]
    let registeredNoteIDs: Set<NoteID>
    let retainedEdits: [NoteID: EditSnapshot]
    let retainedRecovery: [RetainedEditSummary]
    let recoveryNotices: [RecoveryNotice]
}

extension NoteStore {
    func collectionReadSnapshot() -> CollectionReadSnapshot {
        CollectionReadSnapshot(notes: records, registeredNoteIDs: registeredNoteIDs(), retainedEdits: retainedEdits(),
                               retainedRecovery: retainedRecovery().edits, recoveryNotices: recoveryNotices())
    }
}
