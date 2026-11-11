import ramnotesDomain
import Foundation

/// Documents share String storage with the store. The folded search copy changes only when the text changes.
actor SearchIndex {
    private struct Entry {
        let source: String
        let preview: String
        let collectionToken: CollectionToken
        let filename: Data
        let url: URL
        let lastPathComponent: String
        let body: Data
        let availability: NoteAvailability
    }
    private var entries: [NoteID: Entry] = [:]
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
    private func normalized(_ text: String) -> Data { Data(text.folding(options: .caseInsensitive, locale: Self.foldingLocale).precomposedStringWithCanonicalMapping.utf8) }

    func search(_ notes: [SearchDocument], query: SearchQuery) -> [SearchMatch] {
        let sort = query.sort, ascending = query.ascending
        let rawTokens = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens = rawTokens.map(normalized)
        let current = Set(notes.map(\.id))
        entries = entries.filter { current.contains($0.key) }
        for note in notes {
            guard !Task.isCancelled else { return [] }
            let old = entries[note.id].flatMap { $0.collectionToken == note.collectionToken ? $0 : nil }
            // Skip a note whose text, URL, and availability are unchanged.
            if let old, old.source == note.text, old.url == note.fileURL, old.availability == note.availability { continue }
            let name = note.fileURL.lastPathComponent
            let filename = old.flatMap { $0.url == note.fileURL ? $0.filename : nil } ?? normalized(name)
            // Previews don't depend on locale. Queries apply the current locale.
            // A rename or availability change rebuilds match data but keeps the preview.
            let preview = old.flatMap { $0.source == note.text ? $0.preview : nil } ?? NoteText.preview(note.text)
            entries[note.id] = Entry(source: note.text, preview: preview, collectionToken: note.collectionToken, filename: filename, url: note.fileURL, lastPathComponent: name, body: note.availability == .available ? normalized(note.text) : Data(), availability: note.availability)
        }
        return notes.enumerated().compactMap { offset, note -> (SearchDocument, SearchMatch)? in
            guard !Task.isCancelled else { return nil }
            guard let entry = entries[note.id] else { return nil }
            let body = note.availability == .available ? note.text : ""
            guard tokens.allSatisfy({ token in
                entry.filename.range(of: token) != nil || entry.body.range(of: token) != nil
            }) else { return nil }
            let firstMatch = rawTokens.compactMap { body.range(of: $0, options: .caseInsensitive) }.min { $0.lowerBound < $1.lowerBound }
            let start = firstMatch.map { body.index($0.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex } ?? body.startIndex
            let excerpt: SearchExcerpt = note.availability == .available
                ? .text(String(body[start...].prefix(160)).replacingOccurrences(of: "\n", with: " "))
                : .unavailable(note.availability)
            return (note, SearchMatch(offset: offset, id: note.id, excerpt: excerpt, preview: entry.preview))
        }.sorted {
            let comparison: ComparisonResult
            switch sort {
            case .updated, .created:
                let l = $0.0, r = $1.0
                let lhs = (sort == .updated ? l.updatedAt : l.createdAt) ?? .distantPast
                let rhs = (sort == .updated ? r.updatedAt : r.createdAt) ?? .distantPast
                comparison = lhs.compare(rhs)
            case .alphabetical:
                comparison = $0.1.preview.localizedStandardCompare($1.1.preview)
            }
            if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            let a = entries[$0.1.id]?.lastPathComponent ?? ""
            let b = entries[$1.1.id]?.lastPathComponent ?? ""
            return a == b ? $0.1.id.rawValue.uuidString < $1.1.id.rawValue.uuidString : a < b
        }.map(\.1)
    }
}
