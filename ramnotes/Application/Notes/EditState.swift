import ramnotesDomain
import Foundation

/// Per-note edit bookkeeping: edits waiting for a save and buffers kept for the editor.
/// `completeSaved` and `completeRecovered` are the one place that decides what a finished
/// edit clears. Durable journal removal stays on `NoteStore` (`finishEdit`).
struct EditState {
    var pending: [NoteID: EditSnapshot] = [:]
    var preservedBuffers: [NoteID: EditSnapshot] = [:]

    /// The edit is written and verified at `fileRevision`.
    mutating func completeSaved(_ edit: EditSnapshot, fileRevision: FileRevision, session: inout CollectionSession) {
        session.complete(edit.id, revision: edit.revision, result: .saved(revision: edit.revision, fileRevision: fileRevision))
        session.lastWritten[edit.id] = fileRevision
        if let base = edit.baseRevision { session.ownBases[edit.id, default: []].insert(base.fingerprint) }
        session.retryCounts[edit.id] = nil
        clear(edit.id)
    }

    /// The edit is kept in a recovery note instead of its file.
    mutating func completeRecovered(_ edit: EditSnapshot, summary: RetainedEditSummary, session: inout CollectionSession) {
        session.complete(edit.id, revision: edit.revision, result: .recovered(summary))
        clear(edit.id)
        session.saveTasks[edit.id]?.cancel()
    }

    private mutating func clear(_ id: NoteID) {
        pending[id] = nil
        preservedBuffers[id] = nil
    }
}
