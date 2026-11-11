import ramnotesDomain
import Foundation

/// Presentation only: offsets use NSTextView's UTF-16 coordinate space.
struct EditorPosition: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        let location: Int
        let length: Int
    }
    let selections: [Selection]
    let scrollX: Double
    let scrollY: Double
    let hasActiveCaret: Bool
    let fileModifiedAt: Date?
    /// The unsaved edit this position belongs to, or nil when the editor matched the file.
    /// A journal restored at launch reopens that edit, so its position can be restored too.
    let unsavedRevision: EditRevision?

    init(selections: [Selection], scrollX: Double, scrollY: Double,
         hasActiveCaret: Bool, fileModifiedAt: Date?, unsavedRevision: EditRevision? = nil) {
        self.selections = selections.filter {
            $0.location >= 0 && $0.location != NSNotFound && $0.length >= 0 && $0.length <= Int.max - $0.location
        }
        self.scrollX = scrollX.isFinite ? max(0, scrollX) : 0
        self.scrollY = scrollY.isFinite ? max(0, scrollY) : 0
        self.hasActiveCaret = hasActiveCaret
        self.fileModifiedAt = fileModifiedAt
        self.unsavedRevision = unsavedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case selections, scrollX, scrollY, hasActiveCaret, fileModifiedAt, unsavedRevision
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(selections: try fields.decode([Selection].self, forKey: .selections),
                  scrollX: try fields.decode(Double.self, forKey: .scrollX),
                  scrollY: try fields.decode(Double.self, forKey: .scrollY),
                  hasActiveCaret: try fields.decode(Bool.self, forKey: .hasActiveCaret),
                  fileModifiedAt: try fields.decodeIfPresent(Date.self, forKey: .fileModifiedAt),
                  unsavedRevision: try fields.decodeIfPresent(EditRevision.self, forKey: .unsavedRevision))
    }
}

struct NoteWindowMetadata: Codable, Equatable, Sendable {
    // New presentation fields are optional so existing records keep their defaults.
    enum CodingKeys: String, CodingKey {
        case isOpen, frame, displayID, focusOrder, fileResourceID, lastKnownPath, fontSize, backgroundTone
        case editorPosition, acceptedFileModifiedAt, externalChangeNoticeAt
    }
    var editorPosition: EditorPosition? = nil
    var acceptedFileModifiedAt: Date? = nil
    var externalChangeNoticeAt: Date? = nil
    var isOpen: Bool
    var frame: CGRect?
    var displayID: UInt32?
    var focusOrder: UInt64 = 0
    var fileResourceID: String?
    var lastKnownPath: String?
    var fontSize: Double?
    @OptionalBackgroundTone var backgroundTone: NoteBackgroundTone? = nil
}

struct CollectionMetadata: Codable, Equatable, Sendable {
    var notes: [NoteID: NoteWindowMetadata] = [:]
}

/// The store owns note existence. Every load path prunes window state through this one function.
enum WindowStatePruning {
    /// Window state only for notes the store still registers, or `nil` when nothing changed.
    static func prune(_ metadata: CollectionMetadata, registered: Set<NoteID>) -> CollectionMetadata? {
        let kept = metadata.notes.filter { registered.contains($0.key) }
        return kept.count == metadata.notes.count ? nil : CollectionMetadata(notes: kept)
    }
}
