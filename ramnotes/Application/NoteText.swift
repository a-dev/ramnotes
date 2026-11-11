import ramnotesDomain
import Foundation

/// Display text derived from a note's contents.
enum NoteText {
    /// Shown in place of an excerpt when a note has no visible text.
    static let emptyPreview = String(localized: "Empty note", comment: "Note list preview for a note that has no visible text")

    /// The first nonblank line, or the filename without its extension.
    static func title(_ text: String, fileURL: URL) -> String {
        // Titles update while typing. Stop at the first useful line instead of
        // splitting a large note into every line.
        var title: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, _, stop in
            if let line, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                title = line
                stop = true
            }
        }
        return title ?? fileURL.deletingPathExtension().lastPathComponent
    }

    static func preview(_ text: String) -> String {
        let beginning = text.drop(while: \.isWhitespace).prefix(512).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return beginning.isEmpty ? emptyPreview : beginning
    }
}

extension NoteSnapshot {
    static var emptyPreview: String { NoteText.emptyPreview }
    var title: String { NoteText.title(text, fileURL: fileURL) }
    var listPreview: String { NoteText.preview(text) }
}
