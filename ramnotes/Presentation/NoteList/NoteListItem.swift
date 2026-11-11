import ramnotesDomain
import Foundation

/// Unsaved editor text and when it last changed, as the list shows it.
struct NoteListEditCapture: Equatable, Sendable {
    let text: String
    let editedAt: Date?
}

/// One row's display facts. `note` stays the verified snapshot, so actions keep its revision guards.
struct NoteListItem: Equatable, Sendable {
    let note: NoteSnapshot
    /// The editor's unsaved text, or the snapshot text.
    let searchableText: String
    /// Whether `searchableText` is readable. Unsaved editor text always is.
    let textAvailability: NoteAvailability
    /// The time the list sorts and shows: the last unsaved edit, or the file's modification time.
    let updatedAt: Date?
    /// The original file's availability.
    let sourceAvailability: NoteAvailability

    init(note: NoteSnapshot, capture: NoteListEditCapture? = nil, sourceAvailability: NoteAvailability? = nil) {
        self.note = note
        searchableText = capture?.text ?? note.text
        textAvailability = capture == nil ? note.availability : .available
        updatedAt = capture?.editedAt ?? note.fileRevision?.modifiedAt
        self.sourceAvailability = sourceAvailability ?? note.availability
    }

    var searchDocument: SearchDocument {
        SearchDocument(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL, text: searchableText,
                       availability: textAvailability, updatedAt: updatedAt, createdAt: note.createdAt)
    }
}

/// A listed row: its display facts and how the current query matched it.
struct NoteListResult: Equatable, Sendable {
    let item: NoteListItem
    let match: SearchMatch
    var note: NoteSnapshot { item.note }
}
