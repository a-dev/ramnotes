import Foundation

/// Parses the font size and line spacing fields. The fields display `.formatted(...)` output, so
/// parsing accepts the digits the locale shows (Arabic-Indic in `ar`) and plain ASCII digits.
enum TypographyNumber {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? Double(trimmed, format: .number.locale(locale)) { return value }
        return Double(trimmed)
    }
}
