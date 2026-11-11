import ramnotesDomain
import Foundation

enum AppearancePreference: String, Codable, Sendable { case system, light, dark }

struct AppSettings: Codable, Equatable, Sendable {
    var appearance: AppearancePreference = .system
    var alwaysOnTop = false
    var launchAtLogin = false
    var fontFamily = "System"
    var fontWeight = "Regular"
    var fontSize = 18.0
    var lineHeight = 27.0
    var menuBarGestureEnabled = false
    var menuBarHorizontalGestureEnabled = false
    var nextNoteShortcut: String? = nil
    var previousNoteShortcut: String? = nil
    var noteListShortcut: String? = nil
    var moveToTrashShortcut: String? = nil
    var increaseFontShortcut: String? = nil
    var decreaseFontShortcut: String? = nil
    var resetFontShortcut: String? = nil
    var shortcut: String? = ShortcutChord.default.storedValue
    var listGlobalShortcut = ShortcutChord.toggleWithList.storedValue
    var bringNotesForwardWhenInactive = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, alwaysOnTop, launchAtLogin, fontFamily, fontWeight, fontSize, lineHeight
        case menuBarGestureEnabled, menuBarHorizontalGestureEnabled, nextNoteShortcut, previousNoteShortcut, shortcut
        case noteListShortcut, moveToTrashShortcut, listGlobalShortcut, bringNotesForwardWhenInactive
        case increaseFontShortcut, decreaseFontShortcut, resetFontShortcut
    }

    // Only a missing key means an older schema. An invalid value blocks overwriting
    // the file. It never resets preferences quietly.
    init(from decoder: Decoder) throws {
        self.init()
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if fields.contains(.appearance) { appearance = try fields.decode(AppearancePreference.self, forKey: .appearance) }
        if fields.contains(.alwaysOnTop) { alwaysOnTop = try fields.decode(Bool.self, forKey: .alwaysOnTop) }
        if fields.contains(.launchAtLogin) { launchAtLogin = try fields.decode(Bool.self, forKey: .launchAtLogin) }
        if fields.contains(.fontFamily) { fontFamily = try fields.decode(String.self, forKey: .fontFamily) }
        if fields.contains(.fontWeight) { fontWeight = try fields.decode(String.self, forKey: .fontWeight) }
        if fields.contains(.fontSize) { fontSize = try fields.decode(Double.self, forKey: .fontSize) }
        if fields.contains(.lineHeight) { lineHeight = try fields.decode(Double.self, forKey: .lineHeight) }
        if fields.contains(.menuBarGestureEnabled) { menuBarGestureEnabled = try fields.decode(Bool.self, forKey: .menuBarGestureEnabled) }
        if fields.contains(.bringNotesForwardWhenInactive) { bringNotesForwardWhenInactive = try fields.decode(Bool.self, forKey: .bringNotesForwardWhenInactive) }
        if fields.contains(.menuBarHorizontalGestureEnabled) { menuBarHorizontalGestureEnabled = try fields.decode(Bool.self, forKey: .menuBarHorizontalGestureEnabled) }
        if fields.contains(.nextNoteShortcut) { nextNoteShortcut = try fields.decodeIfPresent(String.self, forKey: .nextNoteShortcut) }
        if fields.contains(.previousNoteShortcut) { previousNoteShortcut = try fields.decodeIfPresent(String.self, forKey: .previousNoteShortcut) }
        if fields.contains(.noteListShortcut) { noteListShortcut = try fields.decodeIfPresent(String.self, forKey: .noteListShortcut) }
        if fields.contains(.moveToTrashShortcut) { moveToTrashShortcut = try fields.decodeIfPresent(String.self, forKey: .moveToTrashShortcut) }
        increaseFontShortcut = try fields.decodeIfPresent(String.self, forKey: .increaseFontShortcut)
        decreaseFontShortcut = try fields.decodeIfPresent(String.self, forKey: .decreaseFontShortcut)
        resetFontShortcut = try fields.decodeIfPresent(String.self, forKey: .resetFontShortcut)
        if fields.contains(.shortcut) { shortcut = try fields.decodeIfPresent(String.self, forKey: .shortcut) }
        if fields.contains(.listGlobalShortcut) { listGlobalShortcut = try fields.decode(String.self, forKey: .listGlobalShortcut) }
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(appearance, forKey: .appearance)
        try fields.encode(alwaysOnTop, forKey: .alwaysOnTop)
        try fields.encode(launchAtLogin, forKey: .launchAtLogin)
        try fields.encode(fontFamily, forKey: .fontFamily)
        try fields.encode(fontWeight, forKey: .fontWeight)
        try fields.encode(fontSize, forKey: .fontSize)
        try fields.encode(lineHeight, forKey: .lineHeight)
        try fields.encode(menuBarGestureEnabled, forKey: .menuBarGestureEnabled)
        try fields.encode(menuBarHorizontalGestureEnabled, forKey: .menuBarHorizontalGestureEnabled)
        try fields.encode(nextNoteShortcut, forKey: .nextNoteShortcut)
        try fields.encode(previousNoteShortcut, forKey: .previousNoteShortcut)
        try fields.encode(noteListShortcut, forKey: .noteListShortcut)
        try fields.encode(moveToTrashShortcut, forKey: .moveToTrashShortcut)
        try fields.encode(increaseFontShortcut, forKey: .increaseFontShortcut)
        try fields.encode(decreaseFontShortcut, forKey: .decreaseFontShortcut)
        try fields.encode(resetFontShortcut, forKey: .resetFontShortcut)
        // Write nil explicitly. A missing key would restore the default on reload.
        try fields.encode(shortcut, forKey: .shortcut)
        try fields.encode(listGlobalShortcut, forKey: .listGlobalShortcut)
        try fields.encode(bringNotesForwardWhenInactive, forKey: .bringNotesForwardWhenInactive)
    }
}
