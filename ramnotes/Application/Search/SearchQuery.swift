import ramnotesDomain
import Foundation

enum NoteSort: Int, Sendable {
    case updated, created, alphabetical
}

/// What the user asked the search to match and how to order the results.
struct SearchQuery: Equatable, Sendable {
    var text: String
    var sort: NoteSort = .updated
    var ascending = false
}

/// One note as search sees it. The caller decides which text is searchable and which time sorts it.
struct SearchDocument: Equatable, Sendable {
    let id: NoteID
    let collectionToken: CollectionToken
    let fileURL: URL
    let text: String
    /// Search includes body text only for available notes.
    let availability: NoteAvailability
    let updatedAt: Date?
    let createdAt: Date?
}

extension SearchDocument {
    init(_ note: NoteSnapshot) {
        self.init(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL, text: note.text,
                  availability: note.availability, updatedAt: note.fileRevision?.modifiedAt, createdAt: note.createdAt)
    }
}

/// The excerpt for a match: body text, or the availability that hides the body. Presentation formats the latter.
enum SearchExcerpt: Equatable, Sendable {
    case text(String)
    case unavailable(NoteAvailability)
}

struct SearchMatch: Equatable, Sendable {
    /// The matched document's position in the search input.
    let offset: Int
    let id: NoteID
    let excerpt: SearchExcerpt
    let preview: String
}
