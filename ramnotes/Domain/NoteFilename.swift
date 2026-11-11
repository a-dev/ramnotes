import Foundation

public struct NoteFilenameGenerator: Sendable {
    private let randomIndex: @Sendable (Range<Int>) -> Int

    public init(randomIndex: @escaping @Sendable (Range<Int>) -> Int = { Int.random(in: $0) }) {
        self.randomIndex = randomIndex
    }

    public func next() -> String {
        let words = (0..<3).map { _ in Self.words[randomIndex(Self.words.indices)] }
        return "rn-" + words.joined(separator: "-") + ".txt"
    }
}

/// A user-supplied plain-text filename. Creation and collision handling are I/O.
public struct NoteFilename: Equatable, Sendable {
    public let rawValue: String

    public init?(_ name: String) {
        guard name.lowercased().hasSuffix(".txt"),
              !name.dropLast(4).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else { return nil }
        rawValue = name
    }
}
