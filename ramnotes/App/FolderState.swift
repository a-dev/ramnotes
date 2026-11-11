import ramnotesDomain
import Foundation

/// Note snapshots for the main actor. `AppCoordinator`, `WindowCoordinator`, and
/// `RecoveryController` share one instance, so a storage event updates one dictionary.
/// `apply(_:)` and `replace(with:)` are the only mutators of `notes`.
@MainActor
final class FolderState {
    private(set) var notes: [NoteID: NoteSnapshot] = [:]

    /// Applies the note-view effect of an event. Callers check the collection token first.
    func apply(_ event: NoteEvent) {
        switch event {
        case let .saved(note), let .discovered(note), let .changed(note), let .rebound(note):
            notes[note.id] = note
        case let .removed(id, _):
            notes[id] = nil
        case .saveStatus, .notice, .failed:
            break
        }
    }

    /// Replaces the whole view after a folder load or a reload from the store.
    func replace(with records: [NoteID: NoteSnapshot]) {
        notes = records
    }
}
