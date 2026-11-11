import ramnotesDomain
import Foundation

/// In-app commands whose shortcuts can be changed in Settings.
enum AppShortcut: CaseIterable, Sendable {
    case noteList, nextNote, previousNote, moveToTrash, increaseFont, decreaseFont, resetFont
    var title: String {
        switch self {
        case .noteList: String(localized: "Show note list", comment: "Settings: name of the shortcut that shows the note list")
        case .nextNote: String(localized: "Next note", comment: "Settings: name of the shortcut that moves to the next note")
        case .previousNote: String(localized: "Previous note", comment: "Settings: name of the shortcut that moves to the previous note")
        case .moveToTrash: String(localized: "Move note to Trash", comment: "Settings: name of the shortcut that moves the note to the Trash")
        case .increaseFont: String(localized: "Increase note font size", comment: "Settings: name of the shortcut that makes the active note's text larger")
        case .decreaseFont: String(localized: "Decrease note font size", comment: "Settings: name of the shortcut that makes the active note's text smaller")
        case .resetFont: String(localized: "Reset note font size", comment: "Settings: name of the shortcut that restores the active note's default font size")
        }
    }
    var defaultChord: ShortcutChord {
        switch self {
        case .noteList: .noteList
        case .nextNote: .nextNote
        case .previousNote: .previousNote
        case .moveToTrash: .moveToTrash
        case .increaseFont: .increaseFont
        case .decreaseFont: .decreaseFont
        case .resetFont: .resetFont
        }
    }
    fileprivate var storage: WritableKeyPath<AppSettings, String?> {
        switch self {
        case .noteList: \.noteListShortcut
        case .nextNote: \.nextNoteShortcut
        case .previousNote: \.previousNoteShortcut
        case .moveToTrash: \.moveToTrashShortcut
        case .increaseFont: \.increaseFontShortcut
        case .decreaseFont: \.decreaseFontShortcut
        case .resetFont: \.resetFontShortcut
        }
    }
}

extension AppSettings {
    var openLinkChord: ShortcutChord? {
        let candidate = ShortcutChord.openLink
        guard ShortcutChord(storedValue: shortcut) != candidate,
              ShortcutChord(storedValue: listGlobalShortcut) != candidate,
              !AppShortcut.allCases.contains(where: { chord(for: $0) == candidate }) else { return nil }
        return candidate
    }

    func chord(for shortcut: AppShortcut) -> ShortcutChord { ShortcutChord(storedValue: self[keyPath: shortcut.storage]) ?? shortcut.defaultChord }
    mutating func setChord(_ chord: ShortcutChord, for shortcut: AppShortcut) { self[keyPath: shortcut.storage] = chord.storedValue }
    var nextNoteChord: ShortcutChord { chord(for: .nextNote) }
    var previousNoteChord: ShortcutChord { chord(for: .previousNote) }
    /// True when another in-app command or AppKit already uses the chord.
    func isTaken(_ chord: ShortcutChord, except skipped: AppShortcut? = nil) -> Bool {
        chord.isReservedAppCommand || AppShortcut.allCases.contains { $0 != skipped && self.chord(for: $0) == chord }
    }
}
