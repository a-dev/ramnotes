import AppKit
import Carbon

struct ShortcutChord: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let nextNote = ShortcutChord(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: UInt32(cmdKey))
    static let previousNote = ShortcutChord(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: UInt32(cmdKey))
    static let noteList = ShortcutChord(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey))
    static let openLink = ShortcutChord(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | optionKey))
    static let moveToTrash = ShortcutChord(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey))
    static let increaseFont = ShortcutChord(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey))
    static let decreaseFont = ShortcutChord(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(cmdKey))
    static let resetFont = ShortcutChord(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey))
    // AppKit menus or the note window handle these.
    var isReservedAppCommand: Bool {
        let command = UInt32(cmdKey)
        let shiftCommand = UInt32(cmdKey | shiftKey)
        let fixedKeys: Set<UInt32> = [0, 3, 4, 5, 6, 7, 8, 9, 14, 45, 12, 13, 43, 50]
        return (modifiers == command && fixedKeys.contains(keyCode))
            || (modifiers == shiftCommand && [3, 5, 6, 44, 50].contains(keyCode))
            || (modifiers == UInt32(cmdKey | optionKey) && keyCode == UInt32(kVK_ANSI_H))
    }
    static let toggleWithList = ShortcutChord(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(controlKey | cmdKey))
    static let `default` = ShortcutChord(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(controlKey))
    var storedValue: String { "\(keyCode):\(modifiers)" }
    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    init?(storedValue: String?) {
        if storedValue == "command+option+control+n" {
            self.init(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey | controlKey))
            return
        }
        guard let parts = storedValue?.split(separator: ":"), parts.count == 2,
              let code = UInt32(parts[0]), let flags = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: flags)
        guard isValid else { return nil }
    }
    var isValid: Bool {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return keyCode <= 127 && modifiers & ~allowed == 0 && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 && ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }
    var modifierSymbols: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
    }
    var title: String { modifierSymbols + keyTitle }
    /// Menu items handle single-character keys only. The key monitor handles every chord.
    var menuKeyEquivalent: String {
        if keyCode == UInt32(kVK_Delete) { return "\u{8}" }
        if keyCode == UInt32(kVK_ANSI_Minus) { return "-" }
        let key = keyTitle.lowercased()
        return key.count == 1 && key.first?.isASCII == true ? key : ""
    }
    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
    var keyTitle: String { keyTitle(translator: KeyLayoutTranslator.current) }
    /// Printable keys come from the keyboard layout. Everything else, and any failed translation, uses the fixed table.
    func keyTitle(translator: (UInt32) -> String?) -> String {
        if KeyLayoutTranslator.isPrintable(keyCode), let character = translator(keyCode) { return character.uppercased() }
        return fallbackKeyTitle
    }
    private var fallbackKeyTitle: String {
        let keys: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
            17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 33: "[",
            39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`", 36: "↩",
            48: "⇥", 49: String(localized: "Space", comment: "Name of the Space key on the keyboard, shown in shortcut labels such as ⌃⌥Space"), 51: "⌫", 53: "⎋", 64: "F17", 65: ".", 67: "*", 69: "+",
            71: String(localized: "Clear", comment: "Name of the Clear key on the numeric keypad"), 75: "/", 76: "⌤", 78: "−", 79: "F18", 80: "F19", 81: "=", 82: "0",
            83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 90: "F20",
            91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: String(localized: "Help", comment: "Name of the Help key on the keyboard"),
            115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑", 10: "§", 93: "¥", 94: "_", 95: ",",
        ]
        return keys[keyCode] ?? "?"
    }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        modifiers = (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0) | (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }
}

/// Maps printable key codes to the character the active keyboard layout produces.
enum KeyLayoutTranslator {
    /// Key codes that produce characters. Return, Tab, Space, and the keys above 50 keep fixed titles.
    static func isPrintable(_ keyCode: UInt32) -> Bool {
        keyCode <= 50 && ![UInt32(kVK_Return), UInt32(kVK_Tab), UInt32(kVK_Space)].contains(keyCode)
    }

    /// Uses the current layout, or the ASCII-capable layout when the current one is not ASCII (for example Russian).
    /// Returns nil when no layout can translate the key.
    static func character<Source>(
        for keyCode: UInt32,
        current: () -> Source?,
        asciiCapable: () -> Source?,
        isASCIICapable: (Source) -> Bool,
        translate: (Source, UInt32) -> String?
    ) -> String? {
        var source = current()
        if let candidate = source, !isASCIICapable(candidate) { source = asciiCapable() ?? candidate }
        guard let source else { return nil }
        guard let result = translate(source, keyCode), result.count == 1, result.first?.isWhitespace == false else { return nil }
        return result
    }

    static func current(_ keyCode: UInt32) -> String? {
        character(
            for: keyCode,
            current: { TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() },
            asciiCapable: { TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() },
            isASCIICapable: { source in
                guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
                return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
            },
            translate: translate
        )
    }

    private static func translate(_ source: TISInputSource, _ keyCode: UInt32) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
