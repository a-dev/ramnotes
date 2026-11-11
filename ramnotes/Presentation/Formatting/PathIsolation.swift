import Foundation

/// Wraps a path or filename in Unicode first-strong isolates so it keeps its
/// own direction inside a localized sentence (for example in Arabic).
enum PathIsolation {
    static func isolate(_ text: String) -> String { "\u{2068}" + text + "\u{2069}" }
}
