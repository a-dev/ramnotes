import ramnotesDomain
import AppKit

@MainActor
final class PlainTextView: NSTextView {
    var preventAutomaticFocus = false
    override var acceptsFirstResponder: Bool { !preventAutomaticFocus && super.acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool {
        guard !preventAutomaticFocus else { return false }
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NSWorkspace.shared.notificationCenter
        center.removeObserver(self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if window != nil {
            center.addObserver(self, selector: #selector(refreshDisplayColors), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func refreshDisplayColors() {
        clearLinkHover()
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDisplayColors()
    }

    private let documentUndo = UndoManager()
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private var detectedLinks: [NSTextCheckingResult]?
    private var detectedLinksSource: String?
    override var string: String {
        didSet {
            clearLinkHover()
            detectedLinks = nil
        }
    }
    override var undoManager: UndoManager? { documentUndo }
    var compositionChanged: (() -> Void)?
    var escape: (() -> Void)?
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func unmarkText() {
        super.unmarkText()
        compositionChanged?()
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() || isWritingToolsActive { super.cancelOperation(sender) }
        else if enclosingScrollView?.isFindBarVisible == true {
            let action = NSMenuItem()
            action.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(action)
            window?.makeFirstResponder(self)
        }
        else { escape?() }
    }
    private var linkTrackingArea: NSTrackingArea?
    private var hoveredLinkRange: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateLinkHover(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateLinkHover(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLinkHover()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { clearLinkHover(); return }
        updateLinkHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: event.modifierFlags)
    }

    override func didChangeText() {
        clearLinkHover()
        detectedLinks = nil
        super.didChangeText()
    }

    private func clearLinkHover() {
        if let range = hoveredLinkRange, let layoutManager {
            let length = (string as NSString).length
            let validRange = NSIntersectionRange(range, NSRange(location: 0, length: length))
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: validRange)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: validRange)
        }
        hoveredLinkRange = nil
    }

    func updateLinkHover(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        clearLinkHover()
        guard modifiers.contains(.command), visibleRect.contains(point),
              let match = detectedLink(at: point) else { return }
        hoveredLinkRange = match.range
        layoutManager?.addTemporaryAttributes([
            .foregroundColor: NoteTonePalette.readable(.systemBlue, on: backgroundColor),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], forCharacterRange: match.range)
    }

    private func detectedLink(at point: NSPoint) -> NSTextCheckingResult? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let adjusted = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = manager.characterIndex(for: adjusted, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < (string as NSString).length else { return nil }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard manager.boundingRect(forGlyphRange: glyphs, in: container).contains(adjusted) else { return nil }
        return detectedLink(at: index)
    }

    override func mouseDown(with event: NSEvent) {
        let needsExplicitFocus = preventAutomaticFocus
        preventAutomaticFocus = false
        if needsExplicitFocus { window?.makeFirstResponder(self) }
        if event.modifierFlags.contains(.command),
           let url = detectedLink(at: convert(event.locationInWindow, from: nil))?.url {
            openURL(url)
            return
        }
        super.mouseDown(with: event)
    }

    static func detectedURL(in text: String, at index: Int) -> URL? {
        detectedLink(in: text, at: index)?.url
    }

    func detectedURL(at index: Int) -> URL? { detectedLink(at: index)?.url }

    // A caret must be inside the URL. A nonempty selection must be contained in
    // one URL or contain that whole URL, with no second URL intersecting it.
    var selectedLinkURL: URL? {
        guard !hasMarkedText(), !isWritingToolsActive else { return nil }
        let ranges = selectedRanges.map(\.rangeValue)
        guard ranges.count == 1, let selection = ranges.first,
              selection.location != NSNotFound,
              NSMaxRange(selection) <= (string as NSString).length else { return nil }
        if selection.length == 0 { return detectedLink(at: selection.location)?.url }
        let matches = currentDetectedLinks.filter { NSIntersectionRange(selection, $0.range).length > 0 }
        guard matches.count == 1, let match = matches.first,
              NSIntersectionRange(selection, match.range) == selection ||
                NSIntersectionRange(selection, match.range) == match.range else { return nil }
        return match.url
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        // Future release: restore Font controls after per-note typography and text color
        // are persisted and restored. AppKit currently applies these changes only in memory.
        for item in menu.items where item.submenu?.items.contains(where: {
            $0.action == #selector(NSFontManager.orderFrontFontPanel(_:)) ||
            $0.action == #selector(NSApplication.orderFrontColorPanel(_:))
        }) == true {
            menu.removeItem(item)
        }
        if let item = menu.items.first(where: { $0.action.map { NSStringFromSelector($0).contains("openLink") } ?? false }) {
            item.action = #selector(openLink(_:))
            item.target = nil
        } else {
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Open Link", comment: "Text context menu item that opens the link under the cursor. Use Apple's own term, because the system adds the same item and the app matches it by title"), action: #selector(openLink(_:)), keyEquivalent: "")
        }
        return menu
    }

    @objc func openLink(_ sender: Any?) {
        guard let url = selectedLinkURL else { return }
        openURL(url)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(openLink(_:)) { return selectedLinkURL != nil }
        return super.validateUserInterfaceItem(item)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let source = string
        let actions = currentDetectedLinks.compactMap { match -> NSAccessibilityCustomAction? in
            guard let url = match.url else { return nil }
            return NSAccessibilityCustomAction(name: String(localized: "Open Link: \(url.absoluteString)", comment: "VoiceOver custom action that opens a link found in the note. The value is the link address")) { [weak self] in
                guard let self, self.string == source,
                      !self.hasMarkedText(), !self.isWritingToolsActive else { return false }
                self.openURL(url)
                return true
            }
        }
        return (super.accessibilityCustomActions() ?? []) + actions
    }

    /// Links never span paragraphs, so a point query scans only the paragraph at `index`.
    private func detectedLink(at index: Int) -> NSTextCheckingResult? {
        guard let text = textStorage?.mutableString, index >= 0, index <= text.length else { return nil }
        let paragraph = text.paragraphRange(for: NSRange(location: min(index, max(text.length - 1, 0)), length: 0))
        let local = text.substring(with: paragraph)
        return Self.linkDetector?.matches(in: local, range: NSRange(location: 0, length: paragraph.length))
            .first { NSLocationInRange(index - paragraph.location, $0.range) }?
            .adjustingRanges(offset: paragraph.location)
    }

    private var currentDetectedLinks: [NSTextCheckingResult] {
        // Cache full-note matches for selection checks and accessibility actions. Invalidate
        // after edits or reloads. Compare text because Undo can precede `didChangeText`.
        let text = string
        if detectedLinks == nil || detectedLinksSource != text {
            detectedLinks = Self.linkDetector?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? []
            detectedLinksSource = text
        }
        return detectedLinks ?? []
    }

    private static func detectedLink(in text: String, at index: Int) -> NSTextCheckingResult? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return linkDetector?.matches(in: text, range: range).first { NSLocationInRange(index, $0.range) }
    }
}
