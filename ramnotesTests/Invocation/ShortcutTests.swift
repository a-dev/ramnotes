import XCTest
import Carbon
import ramnotesDomain
@testable import ramnotes

@MainActor
final class ShortcutTests: XCTestCase {
    func testDeliveryFiltersRepeatsAndShutdownReleasesChord() throws {
        let service = ShortcutService()
        defer { service.stop() }
        XCTAssertEqual(service.start(), noErr)
        var count = 0
        service.toggle = { count += 1 }
        func deliver(_ kind: UInt32, signature: OSType = 0x4E325348) throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event), noErr)
            let value = try XCTUnwrap(event)
            defer { ReleaseEvent(value) }
            var identifier = EventHotKeyID(signature: signature, id: 1)
            XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
            _ = SendEventToEventTarget(value, GetApplicationEventTarget())
        }
        try deliver(UInt32(kEventHotKeyPressed), signature: 0)
        XCTAssertEqual(count, 0)
        try deliver(UInt32(kEventHotKeyPressed))
        try deliver(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(count, 1)
        try deliver(UInt32(kEventHotKeyReleased))
        try deliver(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(count, 2)
        service.stop()
        try deliver(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(count, 2)
        var registered: EventHotKeyRef?
        let chord = ShortcutChord.default
        let registrationStatus = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 2),
            GetApplicationEventTarget(),
            0,
            &registered
        )
        XCTAssertEqual(registrationStatus, noErr, "Shutdown should release the registered chord.")
        if let registered { UnregisterEventHotKey(registered) }
    }

    func testStandardMenuCommandsCannotBeAssignedToCustomActions() {
        let settings = AppSettings()
        for chord in [ShortcutChord(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)),
                      ShortcutChord(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey)),
                      ShortcutChord(keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(cmdKey | shiftKey))] {
            XCTAssertTrue(settings.isTaken(chord))
        }
    }

    func testOpenLinkShortcutYieldsToEveryConfiguredCommandAndGlobalShortcut() {
        var settings = AppSettings()
        XCTAssertEqual(settings.openLinkChord, .openLink)
        for command in AppShortcut.allCases {
            settings = AppSettings()
            settings.setChord(.openLink, for: command)
            XCTAssertNil(settings.openLinkChord)
        }
        settings = AppSettings()
        settings.shortcut = ShortcutChord.openLink.storedValue
        XCTAssertNil(settings.openLinkChord)
    }

    func testDefaultAndStoredChordRoundTrip() {
        let chord = ShortcutChord.default

        XCTAssertEqual(chord.keyCode, UInt32(kVK_ANSI_Backslash))
        XCTAssertEqual(chord.modifiers, UInt32(controlKey))
        XCTAssertEqual(chord.title, "⌃\\")
        XCTAssertTrue(chord.isValid)
        XCTAssertEqual(ShortcutChord(storedValue: chord.storedValue), chord)
        XCTAssertEqual(ShortcutChord(storedValue: "command+option+control+n"),
                       ShortcutChord(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey | controlKey)))
        XCTAssertNil(ShortcutChord(storedValue: nil))
        XCTAssertNil(ShortcutChord(storedValue: "not-a-shortcut"))
        XCTAssertNil(ShortcutChord(storedValue: "45:not-a-modifier"))
        XCTAssertNil(ShortcutChord(storedValue: "0:0"))
        XCTAssertNil(ShortcutChord(storedValue: "0:\(UInt32(shiftKey))"))
        XCTAssertNil(ShortcutChord(storedValue: "53:\(UInt32(cmdKey))"))
    }

    func testChordRejectsMissingOrShiftOnlyModifiersAndReservedModifierKeys() {
        let noModifiers = ShortcutChord(keyCode: 0, modifiers: 0)
        let shiftOnly = ShortcutChord(keyCode: 0, modifiers: UInt32(shiftKey))

        XCTAssertFalse(noModifiers.isValid)
        XCTAssertFalse(shiftOnly.isValid)
        for keyCode in UInt32(53)...UInt32(63) {
            XCTAssertFalse(
                ShortcutChord(keyCode: keyCode, modifiers: UInt32(cmdKey)).isValid,
                "Modifier key code \(keyCode) must not be recordable as a shortcut"
            )
        }
    }

    func testKeyTitlesUseCharactersAndKeyboardSymbols() {
        XCTAssertEqual(ShortcutChord(keyCode: 24, modifiers: UInt32(controlKey)).title, "⌃=")
        XCTAssertEqual(ShortcutChord(keyCode: 126, modifiers: UInt32(cmdKey)).title, "⌘↑")
        XCTAssertEqual(ShortcutChord(keyCode: 36, modifiers: UInt32(optionKey)).title, "⌥↩")
        XCTAssertEqual(ShortcutChord(keyCode: 122, modifiers: UInt32(cmdKey)).title, "⌘F1")
    }

    func testKeyTitleUsesLayoutTranslatorForPrintableKeysOnly() {
        let chord = ShortcutChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))
        XCTAssertEqual(chord.keyTitle(translator: { _ in "a" }), "A")
        XCTAssertEqual(chord.keyTitle(translator: { _ in nil }), "Q")
        XCTAssertEqual(ShortcutChord(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey)).keyTitle(translator: { _ in "x" }), "←")
    }

    func testLayoutTranslatorFallsBackToASCIICapableSource() {
        func run(current: String?, ascii: String?) -> String? {
            KeyLayoutTranslator.character(for: 0, current: { current }, asciiCapable: { ascii },
                                          isASCIICapable: { $0 != "russian" },
                                          translate: { source, _ in source == "russian" ? "ф" : (source == "us" ? "a" : nil) })
        }
        XCTAssertEqual(run(current: "russian", ascii: "us"), "a")
        XCTAssertEqual(run(current: "us", ascii: nil), "a")
        XCTAssertNil(run(current: "broken", ascii: nil))
        XCTAssertNil(run(current: nil, ascii: "us"))
    }

    func testNavigationDefaultsAndReservedCommands() {
        for key in [kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_E] {
            XCTAssertTrue(ShortcutChord(keyCode: UInt32(key), modifiers: UInt32(cmdKey)).isReservedAppCommand)
        }
        XCTAssertTrue(ShortcutChord(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)).isReservedAppCommand)
        XCTAssertEqual(ShortcutChord.nextNote.title, "⌘]")
        XCTAssertEqual(ShortcutChord.previousNote.title, "⌘[")
        XCTAssertFalse(ShortcutChord.nextNote.isReservedAppCommand)
        XCTAssertFalse(ShortcutChord.previousNote.isReservedAppCommand)
        XCTAssertTrue(ShortcutChord(keyCode: 3, modifiers: UInt32(cmdKey | shiftKey)).isReservedAppCommand)
        // Note list and Trash shortcuts are customizable, so their defaults are not reserved.
        XCTAssertFalse(ShortcutChord.noteList.isReservedAppCommand)
        XCTAssertFalse(ShortcutChord.moveToTrash.isReservedAppCommand)
        XCTAssertEqual(ShortcutChord.noteList.title, "⌘L")
        XCTAssertEqual(ShortcutChord.moveToTrash.title, "⌘⌫")
        // Font size shortcuts are customizable, so their defaults are not reserved.
        for chord in [ShortcutChord.increaseFont, .decreaseFont, .resetFont] { XCTAssertFalse(chord.isReservedAppCommand) }
        XCTAssertEqual(ShortcutChord.decreaseFont.menuKeyEquivalent, "-")
        XCTAssertEqual(AppSettings().chord(for: .resetFont), .resetFont)
        XCTAssertFalse(ShortcutChord(keyCode: 37, modifiers: UInt32(cmdKey | optionKey)).isReservedAppCommand)
    }

    func testNavigationSettingsDecodeLegacyAndRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(AppSettings())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "nextNoteShortcut")
        legacy.removeValue(forKey: "previousNoteShortcut")
        var settings = try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(settings.nextNoteChord, .nextNote)
        XCTAssertEqual(settings.previousNoteChord, .previousNote)
        let custom = ShortcutChord(keyCode: 124, modifiers: UInt32(cmdKey | optionKey))
        settings.nextNoteShortcut = custom.storedValue
        let restored = try decoder.decode(AppSettings.self, from: encoder.encode(settings))
        XCTAssertEqual(restored.nextNoteChord, custom)
        XCTAssertEqual(restored.previousNoteChord, .previousNote)
    }

    func testListGlobalShortcutDefaultsAndPersistence() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(ShortcutChord(storedValue: decoded.listGlobalShortcut), .toggleWithList)
        XCTAssertEqual(ShortcutChord.toggleWithList.title, "⌃⌘\\")
        var settings = decoded
        settings.listGlobalShortcut = ShortcutChord.openLink.storedValue
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.listGlobalShortcut, ShortcutChord.openLink.storedValue)
        XCTAssertNil(restored.openLinkChord)
    }

    func testTwoGlobalShortcutsDispatchIndependently() throws {
        let notes = ShortcutService(signature: 0x4E325348)
        let list = ShortcutService(signature: 0x4E324C53)
        defer { notes.stop(); list.stop() }
        XCTAssertEqual(notes.start(chord(keyCode: UInt32(kVK_ANSI_A))), noErr)
        XCTAssertEqual(list.start(chord(keyCode: UInt32(kVK_ANSI_S))), noErr)
        var notesCount = 0, listCount = 0
        notes.toggle = { notesCount += 1 }
        list.toggle = { listCount += 1 }
        func deliver(_ signature: OSType) throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event), noErr)
            let value = try XCTUnwrap(event)
            defer { ReleaseEvent(value) }
            var identifier = EventHotKeyID(signature: signature, id: 1)
            XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
            _ = SendEventToEventTarget(value, GetApplicationEventTarget())
        }
        try deliver(0x4E325348)
        XCTAssertEqual(notesCount, 1)
        XCTAssertEqual(listCount, 0)
        try deliver(0x4E324C53)
        XCTAssertEqual(notesCount, 1)
        XCTAssertEqual(listCount, 1)
    }

    func testInvalidShortcutCannotStartService() {
        let service = ShortcutService()
        defer { service.stop() }

        let status = service.start(ShortcutChord(keyCode: 0, modifiers: UInt32(shiftKey)))

        XCTAssertEqual(status, OSStatus(paramErr))
        XCTAssertNil(service.chord)
    }

    func testCarbonCollisionKeepsCurrentShortcutRegistration() throws {
        let current = chord(keyCode: UInt32(kVK_ANSI_A))
        let occupied = chord(keyCode: UInt32(kVK_ANSI_S))
        var collision: EventHotKeyRef?
        let collisionStatus = register(occupied, signature: 0x53525431, id: 1, into: &collision)
        XCTAssertEqual(collisionStatus, noErr)
        defer { if let collision { UnregisterEventHotKey(collision) } }

        let service = ShortcutService()
        defer { service.stop() }
        XCTAssertEqual(service.start(current), noErr)

        let rejectedStatus = service.start(occupied)

        XCTAssertNotEqual(rejectedStatus, noErr)
        XCTAssertEqual(service.chord, current)

        var probe: EventHotKeyRef?
        let probeStatus = register(current, signature: 0x53525432, id: 2, into: &probe)
        if let probe { UnregisterEventHotKey(probe) }
        XCTAssertNotEqual(probeStatus, noErr, "The original chord should remain registered after replacement fails")
    }

    func testSuccessfulReplacementReleasesPreviousChord() throws {
        let previous = chord(keyCode: UInt32(kVK_ANSI_A))
        let replacement = chord(keyCode: UInt32(kVK_ANSI_S))
        let service = ShortcutService()
        defer { service.stop() }
        XCTAssertEqual(service.start(previous), noErr)

        XCTAssertEqual(service.start(replacement), noErr)
        XCTAssertEqual(service.chord, replacement)

        var releasedProbe: EventHotKeyRef?
        let releasedStatus = register(previous, signature: 0x53525433, id: 3, into: &releasedProbe)
        XCTAssertEqual(releasedStatus, noErr, "The previous chord should be available after replacement")
        if let releasedProbe { UnregisterEventHotKey(releasedProbe) }

        var activeProbe: EventHotKeyRef?
        let activeStatus = register(replacement, signature: 0x53525434, id: 4, into: &activeProbe)
        if let activeProbe { UnregisterEventHotKey(activeProbe) }
        XCTAssertNotEqual(activeStatus, noErr, "The replacement chord should remain registered")
    }
}

private func chord(keyCode: UInt32) -> ShortcutChord {
    ShortcutChord(keyCode: keyCode, modifiers: UInt32(cmdKey | controlKey))
}

private func register(
    _ chord: ShortcutChord,
    signature: OSType,
    id: UInt32,
    into hotKey: inout EventHotKeyRef?
) -> OSStatus {
    RegisterEventHotKey(
        chord.keyCode,
        chord.modifiers,
        EventHotKeyID(signature: signature, id: id),
        GetApplicationEventTarget(),
        0,
        &hotKey
    )
}
