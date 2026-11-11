import ramnotesDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NoteListTableView: NSTableView {
    var handleCommand: ((Selector) -> Bool)?
    var rowMenu: ((Int) -> NSMenu?)?
    var isDropTarget = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDropTarget else { return }
        let rect = visibleRect.insetBy(dx: 12, dy: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.controlAccentColor]
        let text = String(localized: "Add files in place", comment: "Drop target label drawn over the note list while the user drags text files over it")
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }
    private var menuTargetRow = -1
    override func menu(for event: NSEvent) -> NSMenu? {
        menuTargetRow = row(at: convert(event.locationInWindow, from: nil))
        return rowMenu?(menuTargetRow)
    }
    // Outline the context menu row without changing focus or selection.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard menuTargetRow >= 0 else { return }
        (rowView(atRow: menuTargetRow, makeIfNecessary: false) as? NoteListRow)?.isMenuTarget = true
    }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        enumerateAvailableRowViews { view, _ in (view as? NoteListRow)?.isMenuTarget = false }
        menuTargetRow = -1
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSButton { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 109, modifiers == .shift,
           let menu = rowMenu?(selectedRow), selectedRow >= 0 {
            menu.popUp(positioning: nil, at: NSPoint(x: 16, y: rect(ofRow: selectedRow).midY), in: self)
            return
        }
        let command: Selector?
        switch (event.keyCode, modifiers) {
        case (45, .control): command = #selector(NSResponder.moveDown(_:))
        case (35, .control): command = #selector(NSResponder.moveUp(_:))
        case (36, []), (76, []): command = #selector(NSResponder.insertNewline(_:))
        default: command = nil
        }
        if let command, handleCommand?(command) == true { return }
        super.keyDown(with: event)
    }
}
