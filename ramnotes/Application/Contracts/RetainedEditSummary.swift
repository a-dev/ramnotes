import ramnotesDomain
import Foundation

/// Text the app kept because it couldn't reach the original file.
/// Recovery presentation uses this value. Bookmarks, promotion state, and journal encoding stay in infrastructure.
struct RetainedEditSummary: Equatable, Sendable, Identifiable {
    enum Reason: Sendable { case conflict, missingOriginal, saveFailure }
    let id: UUID
    let noteID: NoteID
    let originalURL: URL
    let text: String
    let editRevision: EditRevision
    let createdAt: Date
    let reason: Reason
}

extension RetainedEditSummary {
    /// The application boundary maps persisted recovery records to this value.
    init(_ record: RecoveryRecord) {
        let reason: Reason = switch record.reason {
        case .conflict: .conflict
        case .missingOriginal: .missingOriginal
        case .saveFailure: .saveFailure
        }
        self.init(id: record.id, noteID: record.noteID, originalURL: record.originalURL, text: record.text,
                  editRevision: record.editRevision, createdAt: record.createdAt, reason: reason)
    }
}
