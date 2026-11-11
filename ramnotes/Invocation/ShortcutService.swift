import AppKit
import Carbon

@MainActor
final class ShortcutService {
    static let title = String(localized: "Control–Backslash", comment: "Name of the default global shortcut Control plus the backslash key. Keep the en dash as the separator")
    private let signature: OSType
    init(signature: OSType = 0x4E325348) { self.signature = signature }
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private var pressed = false
    private var identifier: UInt32 = 1
    private(set) var chord: ShortcutChord?
    var toggle: () -> Void = {}
    var recordPressed: ((ShortcutChord) -> Void)?

    func start(_ requested: ShortcutChord = .default) -> OSStatus {
        guard requested.isValid else { return OSStatus(paramErr) }
        if chord == requested, hotKey != nil { return noErr }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated { Unmanaged<ShortcutService>.fromOpaque(context).takeUnretainedValue().receive(event) }
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard installed == noErr else { return installed }
        }
        let nextID = chord == nil ? identifier : identifier &+ 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(requested.keyCode, requested.modifiers, EventHotKeyID(signature: signature, id: nextID), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { return status }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        chord = requested
        identifier = nextID
        pressed = false
        return noErr
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; chord = nil; pressed = false
    }
    private func receive(_ event: EventRef) -> OSStatus {
        var value = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &value)
        guard status == noErr, value.signature == signature, value.id == identifier, hotKey != nil else { return OSStatus(eventNotHandledErr) }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed): guard !pressed else { return noErr }; pressed = true; if let chord, let recordPressed { recordPressed(chord) } else { toggle() }
        case UInt32(kEventHotKeyReleased): pressed = false
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
