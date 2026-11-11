import AppKit

@MainActor
enum EditorTypography {
    /// Localized display name for a stored font family. Only "System" is ours to translate.
    static func familyTitle(_ family: String) -> String {
        family == "System" ? String(localized: "System", comment: "Settings font family choice that uses the macOS system font") : family
    }
    /// Localized display name for a stored weight of the system font. Other families keep the names their fonts report.
    static func weightTitle(_ weight: String, family: String) -> String {
        guard family == "System" else { return weight }
        switch weight {
        case "Regular": return String(localized: "Regular", comment: "Font weight name of the system font")
        case "Medium": return String(localized: "Medium", comment: "Font weight name of the system font")
        case "Semibold": return String(localized: "Semibold", comment: "Font weight name of the system font")
        case "Bold": return String(localized: "Bold", comment: "Font weight name of the system font")
        default: return weight
        }
    }
    static func weights(for family: String) -> [String] {
        if family == "System" { return ["Regular", "Medium", "Semibold", "Bold"] }
        let faces = NSFontManager.shared.availableMembers(ofFontFamily: family)?.compactMap { $0.count > 1 ? $0[1] as? String : nil } ?? []
        return Array(Set(faces)).sorted()
    }
    static func normalized(_ input: AppSettings) -> AppSettings {
        var value = input
        value.fontSize = value.fontSize.isFinite ? min(192, max(8, value.fontSize)) : 20
        value.lineHeight = value.lineHeight.isFinite ? min(384, max(value.fontSize, value.lineHeight)) : value.fontSize
        if value.fontFamily != "System", !NSFontManager.shared.availableFontFamilies.contains(value.fontFamily) { value.fontFamily = "System" }
        let faces = weights(for: value.fontFamily)
        if !faces.contains(value.fontWeight) { value.fontWeight = faces.contains("Regular") ? "Regular" : (faces.first ?? "Regular") }
        return value
    }
    static func font(for input: AppSettings) -> NSFont {
        let settings = normalized(input)
        if settings.fontFamily != "System",
           let member = NSFontManager.shared.availableMembers(ofFontFamily: settings.fontFamily)?.first(where: { $0.count > 1 && ($0[1] as? String) == settings.fontWeight }),
           let name = member.first as? String, let font = NSFont(name: name, size: settings.fontSize) { return font }
        let weights: [String: NSFont.Weight] = ["Regular": .regular, "Medium": .medium, "Semibold": .semibold, "Bold": .bold]
        return .systemFont(ofSize: settings.fontSize, weight: weights[settings.fontWeight] ?? .regular)
    }
}
