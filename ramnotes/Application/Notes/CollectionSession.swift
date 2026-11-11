import ramnotesDomain
import Foundation

/// Per-note state for one collection token. Moves and default-folder changes keep
/// the highest edit revisions.
struct CollectionSession {
    var saveTasks: [NoteID: Task<Void, Never>] = [:]
    var writing: Set<NoteID> = []
    var lastWritten: [NoteID: FileRevision] = [:]
    var ownBases: [NoteID: Set<String>] = [:]
    struct Completion {
        let revision: EditRevision
        let result: SaveResult
    }
    private(set) var completions: [NoteID: Completion] = [:]

    mutating func complete(_ id: NoteID, revision: EditRevision, result: SaveResult) {
        completions[id] = Completion(revision: revision, result: result)
    }
    var retryCounts: [NoteID: Int] = [:]
    var journalRecords: [NoteID: RecoveryRecord] = [:]
    /// Typing journals not yet on disk (see `StoreTiming.journalDebounce`), with their timers.
    var deferredJournals: [NoteID: RecoveryRecord] = [:]
    var journalTasks: [NoteID: Task<Void, Never>] = [:]
    /// When each note's journal was last written, by the store clock.
    var journaledAt: [NoteID: Date] = [:]
    var knownLocations: [NoteID: URL] = [:]
    /// The open conflict window of each source note: later edits on the same stale base
    /// update this recovery note instead of creating another one.
    var conflictRecoveries: [NoteID: ConflictRecovery] = [:]

    /// Drops every per-note entry of `id`, including conflict windows where it is the source or the recovery note.
    mutating func forget(_ id: NoteID) {
        saveTasks.removeValue(forKey: id)?.cancel()
        writing.remove(id)
        lastWritten[id] = nil
        ownBases[id] = nil
        completions[id] = nil
        retryCounts[id] = nil
        journalRecords[id] = nil
        deferredJournals[id] = nil
        journalTasks.removeValue(forKey: id)?.cancel()
        journaledAt[id] = nil
        knownLocations[id] = nil
        conflictRecoveries[id] = nil
        conflictRecoveries = conflictRecoveries.filter { $0.value.recoveryNoteID != id }
    }

    func cancelSaves() { for task in Array(saveTasks.values) + Array(journalTasks.values) { task.cancel() } }
}
