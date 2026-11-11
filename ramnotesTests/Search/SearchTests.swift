import ramnotesDomain
import XCTest
import AppKit
@testable import ramnotes

final class SearchTests: XCTestCase {
    @MainActor
    func testFirstCardStaysBelowHeaderAcrossEmptyTransitionsWithoutResize() async throws {
        let list = NoteListController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.close() }
        window.orderFront(nil)
        let note = snapshot(filename: "note.txt", text: "First card")
        for notes in [[note], [], [note], [], [note]] {
            list.update(notes)
            try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
            list.view.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(list.table.enclosingScrollView)
            var ancestor = list.search.superview
            while let view = ancestor, !(view is NSGlassEffectView) { ancestor = view.superview }
            let glass = try XCTUnwrap(ancestor)
            let headerFrame = list.table.convert(glass.bounds, from: glass)
            XCTAssertEqual(headerFrame.maxY, -12, accuracy: 1,
                           "Header inset must match its final height without resizing")
            XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.contentInsets.top, accuracy: 1,
                           "An empty or newly populated list must remain at the top")
        }
    }

    @MainActor
    func testGlassHeaderEdgesStayOutsideVisibleContent() throws {
        let list = NoteListController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.close() }
        var ancestor = list.search.superview
        while let view = ancestor, !(view is NSGlassEffectView) { ancestor = view.superview }
        let glass = try XCTUnwrap(ancestor as? NSGlassEffectView)
        for width in [420.0, 640.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            list.view.layoutSubtreeIfNeeded()
            let glassRect = list.view.convert(glass.bounds, from: glass)
            XCTAssertLessThan(glassRect.minX, list.view.bounds.minX)
            XCTAssertGreaterThan(glassRect.maxX, list.view.bounds.maxX)
            let searchRect = list.view.convert(list.search.bounds, from: list.search)
            XCTAssertEqual(searchRect.minX, 12, accuracy: 1)
        }
    }

    @MainActor
    func testScrollbarStaysAtWindowEdgeOutsideCardContent() async throws {
        let list = NoteListController()
        list.update([snapshot(filename: "note.txt", text: "Card layout")])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.close() }
        let scroll = try XCTUnwrap(list.table.enclosingScrollView)
        scroll.autohidesScrollers = false
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            for width in [420.0, 640.0] {
                window.setContentSize(NSSize(width: width, height: 600))
                list.view.layoutSubtreeIfNeeded()
                scroll.tile()
                let scroller = try XCTUnwrap(scroll.verticalScroller)
                let frame = list.view.convert(scroller.bounds, from: scroller)
                XCTAssertEqual(frame.maxX, list.view.bounds.maxX, accuracy: 2,
                               "The scrollbar must stay at the window edge for \(style)")
                let cell = try XCTUnwrap(list.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
                cell.needsLayout = true
                cell.layoutSubtreeIfNeeded()
                let cardContent = try XCTUnwrap(cell.subviews.first)
                let cardFrame = cell.convert(cardContent.bounds, from: cardContent)
                let expectedPadding = style == .legacy ? max(0, 12 - scroller.frame.width) : 12
                XCTAssertEqual(cell.bounds.maxX - cardFrame.maxX, expectedPadding, accuracy: 0.5,
                               "Card padding must account for the reserved scrollbar gutter")
            }
        }
    }

    @MainActor
    func testScrollingRowsExtendUnderHeader() async throws {
        let list = NoteListController()
        let notes = (0..<20).map { snapshot(filename: "note-\($0).txt", text: "Blue text scrolling behind the translucent header.\nSecond preview line.") }
        list.update(notes)
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Header transparency verification"
        window.contentView = list.view
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        list.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(list.table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        list.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.frame.height, scroll.bounds.height, accuracy: 1)
        let searchRect = list.search.convert(list.search.bounds, to: list.view)
        XCTAssertTrue((0..<list.table.numberOfRows).contains { row in
            list.table.convert(list.table.rect(ofRow: row), to: list.view).intersects(searchRect)
        }, "Scrolled rows must extend behind the search field")
    }

    @MainActor
    func testSearchFieldFillsAvailableHeaderWidth() throws {
        let list = NoteListController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.close() }
        for width in [420.0, 640.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            list.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(list.search.frame.width, width - 180,
                                 "Search must fill the space beside New Note at width \(width)")
            XCTAssertGreaterThan(list.search.frame.height, 24)
        }
    }

    @MainActor
    func testSearchFieldPresentationInLightAndDarkAppearances() throws {
        let list = NoteListController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.view
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(list.search)
            list.view.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(list.search.currentEditor())
            let textRect = list.search.convert(editor.bounds, from: editor)
            XCTAssertGreaterThanOrEqual(textRect.minX, 24, "Text must leave room for the search icon")
            XCTAssertEqual(textRect.midY, list.search.bounds.midY, accuracy: 3,
                           "Search text must be vertically centered")
            let bitmap = try XCTUnwrap(list.view.bitmapImageRepForCachingDisplay(in: list.view.bounds))
            list.view.cacheDisplay(in: list.view.bounds, to: bitmap)
            let image = NSImage(size: list.view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Search field focused \(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testLiveEditsKeepUnavailableStatusVisibleWhileQueryRefreshes() async throws {
        let list = NoteListController()
        let unavailable = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(),
            fileURL: URL(fileURLWithPath: "/notes/missing.txt"), fileRevision: nil,
            text: "", availability: .missingOriginal)
        let note = snapshot(filename: "editing.txt", text: "First")
        list.update([note, unavailable])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let message = list.status.stringValue
        XCTAssertFalse(list.status.isHidden)

        for text in ["First edit", "First edit continues", "First edit continues typing"] {
            let edited = NoteSnapshot(id: note.id, collectionToken: note.collectionToken,
                fileURL: note.fileURL, fileRevision: note.fileRevision,
                text: text, availability: .available)
            list.update([edited, unavailable])
            XCTAssertFalse(list.status.isHidden, "Collapsing the status moves every row while the query runs.")
            XCTAssertEqual(list.status.stringValue, message)
            try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
            XCTAssertFalse(list.status.isHidden)
            XCTAssertEqual(list.selectedNotes.map(\.id), [note.id])
        }
    }

    @MainActor
    func testUnavailableRowExposesLocationInsteadOfRecoveryButtons() async throws {
        let list = NoteListController()
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(),
                                fileURL: URL(fileURLWithPath: "/notes/unavailable.txt"),
                                fileRevision: nil, text: "", availability: .unavailable(reason: "Invalid UTF-8"))
        var located: NoteID?
        list.testDelegate.onLocation = { located = $0.id }
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.numberOfRows(in: list.table), 1)
        list.testDelegate.onExportDrag = { _, _, _ in }
        XCTAssertNil(list.tableView(list.table, pasteboardWriterForRow: 0), "Unavailable originals must not be offered as drag exports.")
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        let button = try XCTUnwrap(cell.accessibilityChildren()?.compactMap { $0 as? NSButton }
            .first { $0.toolTip == note.fileURL.path })
        XCTAssertEqual(button.accessibilityRole(), .button)
        button.performClick(nil)
        XCTAssertEqual(located, note.id)
    }

    @MainActor
    func testFilePromiseOwnsProducerUntilAsynchronousWriteCompletes() async throws {
        let fixture = try TestFixture()
        let target = fixture.root.appendingPathComponent("promised.txt")
        var producer: NoteDragPromise? = NoteDragPromise(name: "promised.txt") { url in
            await Task.yield()
            try Data("current editor text".utf8).write(to: url)
        }
        weak var retainedProducer = producer
        let provider = try XCTUnwrap(producer?.provider)
        producer = nil
        XCTAssertNotNil(retainedProducer, "The native provider must retain its producer independently of the table and drag session.")
        let completed = expectation(description: "Promise write completes")
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: target) { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: target), Data("current editor text".utf8))
    }

    @MainActor
    func testHiddenUpdatesCoalesceAndRevealUsesLatestQueryAndFolder() async throws {
        let list = NoteListController()
        var visible = false
        list.isPresented = { visible }
        let old = snapshot(filename: "old.txt", text: "old draft")
        list.update([old])
        for number in 0..<100 {
            list.update([snapshot(filename: "draft.txt", text: "unsaved draft \(number)")])
        }
        list.search.stringValue = "old"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let latest = snapshot(filename: "current.txt", text: "latest unsaved text")
        list.update([latest])
        list.search.stringValue = "unsaved"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(list.queryCount, 0)
        visible = true
        list.reveal()
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.queryCount, 1)
        XCTAssertEqual(list.numberOfRows(in: list.table), 1)
        var opened: NoteID?
        list.testDelegate.onOpen = { opened = $0.id }
        _ = list.control(list.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened, latest.id)

        // Presentation-only updates preserve content results and selection.
        for _ in 0..<100 { list.refreshTones() }
        list.update([latest])
        XCTAssertEqual(list.queryCount, 1)
        list.update([])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.numberOfRows(in: list.table), 0)
        XCTAssertEqual(list.table.selectedRow, -1)
    }

    @MainActor
    func testQueryReplacementRejectsPendingResults() async throws {
        let list = NoteListController()
        let note = snapshot(filename: "draft.txt", text: "latest draft")
        list.update([note])
        list.search.stringValue = "missing"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.numberOfRows(in: list.table), 0)
        list.search.stringValue = "latest"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.numberOfRows(in: list.table), 1)
    }

    @MainActor
    func testMultiSelectionSurvivesUpdateAndBatchTrashTargetsSelection() async throws {
        let list = NoteListController()
        let first = snapshot(filename: "first.txt", text: "First", modifiedAt: 3, id: "00000000-0000-0000-0000-000000000001")
        let middle = snapshot(filename: "middle.txt", text: "Middle", modifiedAt: 2, id: "00000000-0000-0000-0000-000000000002")
        let last = snapshot(filename: "last.txt", text: "Last", modifiedAt: 1, id: "00000000-0000-0000-0000-000000000003")
        list.update([first, middle, last])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        var selection = IndexSet()
        selection.insert(0)
        selection.insert(2)
        list.table.selectRowIndexes(selection, byExtendingSelection: false)

        let updatedLast = NoteSnapshot(id: last.id, collectionToken: last.collectionToken, fileURL: last.fileURL,
            fileRevision: last.fileRevision, text: "Last updated", availability: .available)
        list.update([first, middle, updatedLast])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }

        XCTAssertEqual(Set(list.selectedNotes.map(\.id)), Set([first.id, last.id]))
        var trashed: [NoteID] = []
        list.testDelegate.onTrashBatch = { trashed = $0.map(\.id) }
        let menu = try XCTUnwrap(list.menu(forRow: 0))
        let item = try XCTUnwrap(menu.item(withTitle: "Move 2 Notes to Trash…"))
        XCTAssertTrue(item.isEnabled)
        guard let action = item.action else { return XCTFail("Expected batch Trash action") }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))

        XCTAssertEqual(trashed, [first.id, last.id])
        XCTAssertNil(menu.item(withTitle: "Change Location…"))
        XCTAssertEqual(list.table.accessibilityValue() as? String, "2 notes selected")
        trashed = []
        XCTAssertTrue(list.canTrashSelection)
        list.trashSelection()
        XCTAssertEqual(trashed, [first.id, last.id], "Menu and shortcut dispatch use the same selected batch.")
        var opened: [NoteID] = []
        list.testDelegate.onOpenBatch = { opened = $0.map(\.id) }
        _ = list.control(list.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened, [first.id, last.id])
        list.testDelegate.onActionsAllowed = { false }
        XCTAssertFalse(list.canTrashSelection)
    }

    @MainActor
    func testSearchRowsShowDeepBodyMatchesAndRestoreLeadingPreview() async throws {
        let list = NoteListController()
        let note = snapshot(filename: "note.txt", text: "Opening paragraph. " + String(repeating: "filler ", count: 150) + "needle in the closing paragraph.")
        func displayedPreview() throws -> NSTextField {
            let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
            let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
            let text = try XCTUnwrap(row.arrangedSubviews.first as? NSStackView)
            return try XCTUnwrap(previewLabel(in: text))
        }
        list.search.stringValue = "needle"
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let matching = try displayedPreview()
        XCTAssertTrue(matching.stringValue.contains("needle"))
        XCTAssertEqual(matching.accessibilityLabel(), matching.stringValue)

        list.search.stringValue = ""
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(try displayedPreview().stringValue, note.listPreview)
    }

    @MainActor
    func testRowWithoutDateStartsLocationAtLeadingEdge() async throws {
        let list = NoteListController()
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(),
                                fileURL: URL(fileURLWithPath: "/notes/unavailable.txt"),
                                fileRevision: nil, text: "", availability: .unavailable(reason: "Access"))
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        cell.frame = NSRect(x: 0, y: 0, width: 396, height: 116)
        cell.layoutSubtreeIfNeeded()
        cell.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
        let text = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let footer = try XCTUnwrap(text.arrangedSubviews[1] as? NSStackView)
        let button = try XCTUnwrap(footer.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        let cellFrame = try XCTUnwrap(button.cell).imageRect(forBounds: button.bounds.insetBy(dx: 8, dy: 2))
        let folderX = button.convert(cellFrame, to: cell).minX
        let edgeX = text.convert(text.bounds, to: cell).minX
        XCTAssertEqual(folderX, edgeX, accuracy: 2, "Without a date, the path starts at the card's leading content edge")
    }

    @MainActor
    func testLongLocationDoesNotSqueezeDate() async throws {
        let list = NoteListController()
        let base = snapshot(filename: "a.txt", text: "Dated note")
        let longURL = URL(fileURLWithPath: "/Users/tester/RAMnotes-tests/2026-11-08-finder/some/long/nested/files/finder-test-4.txt")
        let note = NoteSnapshot(id: base.id, collectionToken: base.collectionToken, fileURL: longURL,
                                fileRevision: base.fileRevision, text: base.text, availability: .available)
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 116)
        cell.layoutSubtreeIfNeeded()
        cell.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
        let text = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let footer = try XCTUnwrap(text.arrangedSubviews[1] as? NSStackView)
        let date = try XCTUnwrap(footer.arrangedSubviews.first as? NSTextField)
        XCTAssertFalse(date.stringValue.isEmpty)
        XCTAssertGreaterThan(date.contentCompressionResistancePriority(for: .horizontal),
                             footer.arrangedSubviews[1].contentCompressionResistancePriority(for: .horizontal),
                             "Equal priorities let Auto Layout squeeze either one")
        XCTAssertGreaterThanOrEqual(date.frame.width, date.intrinsicContentSize.width - 1,
                                    "The path truncates before the date does")
    }

    @MainActor
    func testNoteIssueShowsOnTheLineBelowTheTitle() async throws {
        let list = NoteListController()
        let note = snapshot(filename: "a.txt", text: "Short title")
        list.testDelegate.onNoteIssue = { $0 == note.id ? "External change. Local text preserved." : nil }
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        let labels = cell.accessibilityChildren()?.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        XCTAssertEqual(Array(labels.prefix(2)), ["Short title", "External change. Local text preserved."])
    }

    @MainActor
    func testLongTitleKeepsTwoLinesWithoutAProblem() async throws {
        let list = NoteListController()
        list.update([snapshot(filename: "long.txt", text: String(repeating: "Happy families are all alike. ", count: 10))])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        cell.frame = NSRect(x: 0, y: 0, width: 396, height: list.tableView(list.table, heightOfRow: 0))
        cell.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
        let text = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let title = try XCTUnwrap(previewLabel(in: text))
        let line = try XCTUnwrap(title.font).boundingRectForFont.height
        XCTAssertGreaterThan(title.frame.height, line * 1.5, "A title without a problem keeps room for two lines")
    }

    @MainActor
    func testActionsButtonKeepsNormalStyleWhenRowIsSelected() async throws {
        let list = NoteListController()
        let broken = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/notes/broken.txt"),
                                  fileRevision: nil, text: "", availability: .unavailable(reason: "Access"))
        list.update([broken])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0) as? NSTableCellView)
        let button = try XCTUnwrap(cell.accessibilityChildren()?.compactMap { $0 as? NSButton }.first { $0.title == "Actions…" })
        cell.backgroundStyle = .emphasized
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.cell?.backgroundStyle, .normal, "A selected row must not draw the button white on the light card")
    }

    @MainActor
    func testOnlyRowsWithAProblemShowActionsButton() async throws {
        let list = NoteListController()
        let token = CollectionToken()
        let broken = NoteSnapshot(id: NoteID(), collectionToken: token, fileURL: URL(fileURLWithPath: "/notes/broken.txt"),
                                  fileRevision: nil, text: "", availability: .unavailable(reason: "Access"))
        list.update([broken, snapshot(filename: "fine.txt", text: "Fine")])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        func actionsButton(_ row: Int) throws -> NSButton? {
            let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: row))
            return cell.accessibilityChildren()?.compactMap { $0 as? NSButton }.first { $0.title == "Actions…" }
        }
        let brokenRow = try XCTUnwrap(list.results.firstIndex { $0.note.id == broken.id })
        let button = try XCTUnwrap(try actionsButton(brokenRow), "A row with a problem must offer a visible Actions… button")
        XCTAssertFalse(button.isHidden)
        XCTAssertNil(try actionsButton(1 - brokenRow), "A healthy row has no Actions… button")
    }

    @MainActor
    func testTintStaysAtTrailingEdgeForShortAndLongExcerpts() async throws {
        let list = NoteListController()
        list.testDelegate.onBackgroundTone = { _ in .yellow }
        for excerpt in ["Short", String(repeating: "Long excerpt ", count: 20)] {
            list.update([snapshot(filename: "note.txt", text: excerpt)])
            try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
            let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
            cell.frame = NSRect(x: 0, y: 0, width: 396, height: 116)
            cell.layoutSubtreeIfNeeded()
            let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
            let text = try XCTUnwrap(row.arrangedSubviews.first as? NSStackView)
            let footer = try XCTUnwrap(text.arrangedSubviews[1] as? NSStackView)
            let indicator = try XCTUnwrap(footer.arrangedSubviews.compactMap { $0 as? NSImageView }.last)
            let date = try XCTUnwrap(footer.arrangedSubviews.first as? NSTextField)
            let circleFrame = indicator.convert(indicator.bounds, to: cell)
            let dateFrame = date.convert(date.bounds, to: cell)
            XCTAssertEqual(circleFrame.maxX, cell.bounds.maxX - 24, accuracy: 0.5, excerpt)
            XCTAssertEqual(circleFrame.midY, dateFrame.midY, accuracy: 0.5)
        }
    }

    @MainActor
    func testTintRefreshPreservesQueryResultsSelectionAndScroll() async throws {
        let list = NoteListController()
        let note = snapshot(filename: "color.txt", text: "A colored note")
        var tone: NoteBackgroundTone? = .green
        list.testDelegate.onBackgroundTone = { _ in tone }
        list.search.stringValue = "colored"
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        list.table.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        let cell = try XCTUnwrap(list.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(cell.accessibilityHelp(), "Background tint: Green")
        let selection = list.table.selectedRowIndexes
        let origin = list.table.enclosingScrollView?.contentView.bounds.origin
        tone = .purple
        list.refreshTones()
        XCTAssertEqual(cell.accessibilityHelp(), "Background tint: Purple")
        XCTAssertEqual(list.table.numberOfRows, 1)
        XCTAssertEqual(list.search.stringValue, "colored")
        XCTAssertEqual(list.table.selectedRowIndexes, selection)
        XCTAssertEqual(list.table.enclosingScrollView?.contentView.bounds.origin, origin)
        tone = nil
        list.refreshTones()
        XCTAssertEqual(cell.accessibilityHelp(), "Background tint: No color")
        let stack = try XCTUnwrap(cell.subviews.first as? NSStackView)
        let text = try XCTUnwrap(stack.arrangedSubviews.first as? NSStackView)
        let footer = try XCTUnwrap(text.arrangedSubviews[1] as? NSStackView)
        XCTAssertTrue(try XCTUnwrap(footer.arrangedSubviews.compactMap { $0 as? NSImageView }.last).isHidden)
    }

    @MainActor
    func testEditingOneNoteReloadsOnlyItsRow() async throws {
        let list = NoteListController()
        // Only a hosted table keeps row views across a partial reload.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.table.enclosingScrollView
        defer { window.close() }
        let first = snapshot(filename: "first.txt", text: "First", modifiedAt: 2)
        let second = snapshot(filename: "second.txt", text: "Second", modifiedAt: 1)
        list.update([first, second])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let untouched = try XCTUnwrap(list.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        _ = try XCTUnwrap(list.table.view(atColumn: 0, row: 0, makeIfNecessary: true))

        let edited = NoteSnapshot(id: first.id, collectionToken: first.collectionToken, fileURL: first.fileURL,
                                  fileRevision: first.fileRevision, text: "First edited", availability: .available)
        list.update([edited, second])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertTrue(list.table.view(atColumn: 0, row: 1, makeIfNecessary: false) === untouched,
                      "An unchanged row keeps its view when the order is unchanged.")
        let row = try XCTUnwrap(list.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(row.accessibilityChildren()?.compactMap { ($0 as? NSTextField)?.stringValue }.first, edited.listPreview)
    }

    @MainActor
    func testTableKeyboardNavigationAndOpening() async throws {
        let list = NoteListController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.table.enclosingScrollView
        defer { window.close() }
        list.update([
            snapshot(filename: "first.txt", text: "First", modifiedAt: 3),
            snapshot(filename: "second.txt", text: "Second", modifiedAt: 2),
            snapshot(filename: "third.txt", text: "Third", modifiedAt: 1)
        ])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        var opened: [String] = []
        list.testDelegate.onOpen = { opened.append($0.text) }
        func press(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: code == 125 ? "\u{F701}" : code == 126 ? "\u{F700}" : code == 45 ? "n" : code == 35 ? "p" : "\r",
                charactersIgnoringModifiers: code == 125 ? "\u{F701}" : code == 126 ? "\u{F700}" : code == 45 ? "n" : code == 35 ? "p" : "\r", isARepeat: false, keyCode: code))
            list.table.keyDown(with: event)
        }
        try press(125)
        XCTAssertEqual(list.table.selectedRow, 1)
        try press(125, modifiers: .shift)
        XCTAssertEqual(list.table.selectedRowIndexes, IndexSet(integersIn: 1...2), "Shift-Down extends the native row range.")
        try press(125)
        XCTAssertEqual(list.table.selectedRowIndexes, IndexSet(integer: 2), "Down collapses the range at its active row.")
        try press(45, modifiers: .control)
        try press(45, modifiers: .control)
        XCTAssertEqual(list.table.selectedRow, 2)
        try press(35, modifiers: .control)
        XCTAssertEqual(list.table.selectedRow, 1)
        try press(126)
        try press(126)
        XCTAssertEqual(list.table.selectedRow, 0)
        XCTAssertTrue(opened.isEmpty)
        try press(36)
        XCTAssertEqual(opened, ["First"])
        list.update([])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        try press(125)
        try press(36)
        XCTAssertEqual(opened, ["First"])
    }

    @MainActor
    func testPreviewKeepsTailTruncationWhenResized() async throws {
        let list = NoteListController()
        list.update([snapshot(filename: "long.txt", text: String(repeating: "Long preview text and a longwordwithoutspaces ", count: 30))])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0) as? NSTableCellView)
        let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
        let text = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let preview = try XCTUnwrap(previewLabel(in: text))
        for width: CGFloat in [400, 180, 320] {
            preview.frame.size.width = width
            preview.layoutSubtreeIfNeeded()
            let paragraph = preview.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(paragraph?.lineBreakMode ?? preview.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(preview.maximumNumberOfLines, 2)
        }
    }

    @MainActor
    func testOpenNotesUseAccentColorAndAccessibleStateWithoutAnEyeControl() async throws {
        let list = NoteListController()
        let note = snapshot(filename: "note.txt", text: "Open note")
        var opened = true
        list.testDelegate.onIsOpen = { _ in opened }
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        for expected in [true, false] {
            opened = expected
            let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0) as? NSTableCellView)
            let row = try XCTUnwrap(cell.subviews.first as? NSStackView)
            XCTAssertEqual(row.arrangedSubviews.count, 1)
            let text = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
            let footer = try XCTUnwrap(text.arrangedSubviews[1] as? NSStackView)
            XCTAssertTrue(try XCTUnwrap(footer.arrangedSubviews.compactMap { $0 as? NSImageView }.last).isHidden)
            let preview = try XCTUnwrap(previewLabel(in: text))
            let readable = NoteTonePalette.readable(expected ? .controlAccentColor : .labelColor, on: .controlBackgroundColor)
            for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                    XCTAssertEqual(preview.textColor?.usingColorSpace(.sRGB), readable.usingColorSpace(.sRGB))
                }
            }
            XCTAssertEqual(preview.accessibilityHelp(), expected ? "Open note. Background tint: No color" : "Closed note. Background tint: No color")
        }
    }

    func testUnicodeCaseInsensitiveMatchingDoesNotFoldAccents() async {
        let index = SearchIndex()
        let note = snapshot(filename: "Café.txt", text: "Über den Wolken")

        let caseInsensitive = await index.search(notes: [note], query: "CAFÉ")
        let accentFolded = await index.search(notes: [note], query: "cafe")

        XCTAssertEqual(caseInsensitive.map(\.note.id), [note.id])
        XCTAssertTrue(accentFolded.isEmpty)
    }

    func testEveryTokenCanMatchAcrossFilenameAndBodyAndWhitespaceIsTrimmed() async {
        let index = SearchIndex()
        let crossFieldMatch = snapshot(filename: "Project Notes.txt", text: "Launch checklist")
        let other = snapshot(filename: "Archive.txt", text: "Old project notes")
        let notes = [crossFieldMatch, other]

        let results = await index.search(notes: notes, query: " \tPROJECT\nlaunch  ")
        let missingToken = await index.search(notes: notes, query: "project launch missing")
        let whitespaceOnly = await index.search(notes: notes, query: " \n\t ")

        XCTAssertEqual(results.map(\.note.id), [crossFieldMatch.id])
        XCTAssertTrue(missingToken.isEmpty)
        XCTAssertEqual(Set(whitespaceOnly.map(\.note.id)), Set(notes.map(\.id)))
    }

    func testResultsSortByModificationDateThenFilenameThenID() async {
        let index = SearchIndex()
        let newest = snapshot(filename: "zulu.txt", text: "match", modifiedAt: 30, id: "00000000-0000-0000-0000-000000000001")
        let alpha = snapshot(filename: "Alpha.txt", text: "match", modifiedAt: 20, id: "00000000-0000-0000-0000-000000000005")
        let beta = snapshot(filename: "beta.txt", text: "match", modifiedAt: 20, id: "00000000-0000-0000-0000-000000000004")
        let sameNameHigherID = snapshot(filename: "same.txt", text: "match", modifiedAt: 20, id: "00000000-0000-0000-0000-000000000002")
        let sameNameLowerID = snapshot(filename: "same.txt", text: "match", modifiedAt: 20, id: "00000000-0000-0000-0000-000000000001")

        let results = await index.search(
            notes: [sameNameHigherID, beta, newest, sameNameLowerID, alpha],
            query: "match"
        )

        XCTAssertEqual(
            results.map { $0.note.fileURL.lastPathComponent },
            ["zulu.txt", "Alpha.txt", "beta.txt", "same.txt", "same.txt"]
        )
        XCTAssertEqual(
            Array(results.suffix(2)).map(\.note.id),
            [sameNameLowerID.id, sameNameHigherID.id]
        )
    }

    func testFilenameOnlyMatchHasBoundedFilenameContextSnippet() async throws {
        let index = SearchIndex()
        let longFilename = String(repeating: "archive-", count: 50) + "needle.txt"
        let note = snapshot(filename: longFilename, text: "The body has no matching term.")

        let results = await index.search(notes: [note], query: "needle")

        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.snippet, "The body has no matching term.")
        XCTAssertLessThanOrEqual(result.snippet.count, 160)
    }
    func testListPreviewUsesBeginningAndEmptyFallback() {
        XCTAssertEqual(snapshot(filename: "filename.txt", text: " \n\t ").listPreview, "Empty note")
        XCTAssertEqual(snapshot(filename: "filename.txt", text: "First line\nsecond line").listPreview, "First line second line")
    }

    func testSortDirectionsAndAlphabeticalUsesBody() async {
        let index = SearchIndex()
        let alpha = snapshot(filename: "z.txt", text: "Alpha", modifiedAt: 20)
        let beta = snapshot(filename: "a.txt", text: "beta", modifiedAt: 10)
        let notes = [beta, alpha]
        let oldest = await index.search(notes: notes, query: "", sort: .updated, ascending: true)
        let alphabetical = await index.search(notes: notes, query: "", sort: .alphabetical, ascending: true)
        let reversed = await index.search(notes: notes, query: "", sort: .alphabetical, ascending: false)
        XCTAssertEqual(oldest.map(\.note.id), [beta.id, alpha.id])
        XCTAssertEqual(alphabetical.map(\.note.id), [alpha.id, beta.id])
        XCTAssertEqual(reversed.map(\.note.id), [beta.id, alpha.id])
    }

    func testCachedAlphabeticalOrderingMatchesLocalizedReference() async {
        let index = SearchIndex()
        let bodies = ["", " \n\t", " Note 10", "Note 2", "Über café", "東京 📝", "same", "same", "same"]
        let notes = bodies.enumerated().map { offset, body in
            snapshot(filename: offset >= 7 ? "same.txt" : "\(offset).txt", text: body,
                id: String(format: "00000000-0000-0000-0000-%012d", offset + 1))
        }
        for ascending in [true, false] {
            let expected = notes.sorted {
                let comparison = $0.listPreview.localizedStandardCompare($1.listPreview)
                if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
                let a = $0.fileURL.lastPathComponent, b = $1.fileURL.lastPathComponent
                return a == b ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : a < b
            }
            for _ in 0..<3 {
                let results = await index.search(notes: notes.reversed(), query: "", sort: .alphabetical, ascending: ascending)
                XCTAssertEqual(results.map(\.note.id), expected.map(\.id))
                XCTAssertEqual(results.map(\.preview), expected.map(\.listPreview))
            }
        }
    }

    func testPreviewReplacementAvailabilityRemovalAndFolderReuse() async {
        let index = SearchIndex()
        var note = snapshot(filename: "draft.txt", text: "Alpha " + String(repeating: "padding ", count: 100) + "needle")
        let initial = await index.search(notes: [note], query: "needle", sort: .alphabetical)
        XCTAssertTrue(initial[0].snippet.contains("needle"))
        XCTAssertFalse(initial[0].preview.contains("needle"))
        for text in ["Native edit", "External replacement"] {
            note = NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
                fileRevision: nil, text: text, availability: .available)
            let edited = await index.search(notes: [note], query: "", sort: .alphabetical)
            XCTAssertEqual(edited.first?.preview, text)
        }
        note = NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
            fileRevision: nil, text: note.text, availability: .unavailable(reason: "Offline"))
        let unavailable = await index.search(notes: [note], query: "draft", sort: .alphabetical)
        XCTAssertEqual(unavailable.first?.preview, note.listPreview)
        XCTAssertEqual(unavailable.first?.snippet, "Unavailable: Offline")
        let hiddenBody = await index.search(notes: [note], query: "External")
        XCTAssertTrue(hiddenBody.isEmpty)
        note = NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
            fileRevision: nil, text: note.text, availability: .available)
        let available = await index.search(notes: [note], query: "External")
        XCTAssertEqual(available.count, 1)
        _ = await index.search(notes: [], query: "")
        let replacement = NoteSnapshot(id: note.id, collectionToken: CollectionToken(),
            fileURL: note.fileURL, fileRevision: nil, text: "New folder", availability: .available)
        let replaced = await index.search(notes: [replacement], query: "", sort: .alphabetical)
        XCTAssertEqual(replaced.first?.preview, "New folder")
        let oldQuery = await index.search(notes: [replacement], query: "External")
        XCTAssertTrue(oldQuery.isEmpty)
    }

    func testScannedSnapshotCarriesBackingFileCreationDate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.txt")
        var cache: [String: CachedBody] = [:]
        let read = { FolderScanner.snapshot(id: NoteID(), url: url, collectionToken: CollectionToken(),
            editRevision: EditRevision(rawValue: 0), cache: &cache, readBody: { try Data(contentsOf: $0) }) }
        XCTAssertNil(read().createdAt)
        try Data("note".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
        XCTAssertEqual(read().createdAt, Date(timeIntervalSince1970: 1000))
        // A cached body still reports a changed creation date.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 500)], ofItemAtPath: url.path)
        XCTAssertEqual(read().createdAt, Date(timeIntervalSince1970: 500))
    }

    func testCreationSortFollowsSnapshotCreationDate() async throws {
        func note(_ name: String, created: TimeInterval?, modified: TimeInterval, id: NoteID = NoteID()) -> NoteSnapshot {
            NoteSnapshot(id: id, collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/notes/\(name)"),
                fileRevision: FileRevision(fingerprint: name, modifiedAt: Date(timeIntervalSince1970: modified)),
                text: name, availability: .available, createdAt: created.map(Date.init(timeIntervalSince1970:)))
        }
        let older = note("older.txt", created: 1000, modified: 3000)
        let newer = note("newer.txt", created: 2000, modified: 2000)
        let index = SearchIndex()
        let descending = await index.search(notes: [older, newer], query: "", sort: .created)
        let ascending = await index.search(notes: [older, newer], query: "", sort: .created, ascending: true)
        XCTAssertEqual(descending.map(\.note.id), [newer.id, older.id])
        XCTAssertEqual(ascending.map(\.note.id), [older.id, newer.id])

        // A relink keeps the NoteID, text, and path but changes the backing file.
        let relinked = note("older.txt", created: 3000, modified: 3000, id: older.id)
        let afterRelink = await index.search(notes: [relinked, newer], query: "", sort: .created)
        XCTAssertEqual(afterRelink.map(\.note.id), [older.id, newer.id])

        // An unreadable date sorts last but isn't cached once the file is readable.
        let unknown = note("older.txt", created: nil, modified: 3000, id: older.id)
        let whileUnknown = await index.search(notes: [unknown, newer], query: "", sort: .created)
        XCTAssertEqual(whileUnknown.map(\.note.id), [newer.id, older.id])
        let recovered = await index.search(notes: [relinked, newer], query: "", sort: .created)
        XCTAssertEqual(recovered.map(\.note.id), [older.id, newer.id])
    }

    @MainActor
    func testReplacedQueriesAndFolderSnapshotsDoNotReappear() async throws {
        let list = NoteListController()
        let old = snapshot(filename: "old.txt", text: "stale")
        let latest = snapshot(filename: "new.txt", text: "fresh")
        list.update([old])
        list.search.stringValue = "stale"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        list.update([latest])
        list.search.stringValue = "fresh"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.table.numberOfRows, 1)
        var opened: NoteID?
        list.testDelegate.onOpen = { opened = $0.id }
        _ = list.control(list.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened, latest.id)
    }

}

private func snapshot(
    filename: String,
    text: String,
    modifiedAt: TimeInterval = 0,
    id: String = UUID().uuidString
) -> NoteSnapshot {
    NoteSnapshot(
        id: NoteID(UUID(uuidString: id)!),
        collectionToken: CollectionToken(),
        fileURL: URL(fileURLWithPath: "/notes/" + filename),
        fileRevision: FileRevision(fingerprint: "test", modifiedAt: Date(timeIntervalSince1970: modifiedAt)),
        text: text,
        availability: .available
    )
}

extension SearchTests {
    @MainActor
    func testLocationActionHasFullPathAndDoesNotOpenNote() async throws {
        let list = NoteListController()
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/notes/a.txt"), fileRevision: nil, text: "preview", availability: .available)
        list.defaultFolder = URL(fileURLWithPath: "/notes")
        var located = false
        var opened = false
        list.testDelegate.onLocation = { _ in located = true }
        list.testDelegate.onOpen = { _ in opened = true }
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        let button = try XCTUnwrap(cell.accessibilityChildren()?.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.toolTip, "/notes/a.txt")
        XCTAssertEqual(button.accessibilityLabel(), "Change note location: \(PathIsolation.isolate("/notes/a.txt"))")
        button.performClick(nil)
        XCTAssertTrue(located)
        XCTAssertFalse(opened)
    }
}

extension SearchTests {
    @MainActor
    func testUnavailableLocationActionsPreserveIdentityAndNarrowLayout() async throws {
        let list = NoteListController()
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/a/very/long/custom/folder/with/a/name/unavailable.txt"), fileRevision: nil, text: "", availability: .missingOriginal, accessFailure: NoteAccessFailure(reason: .missingFile, domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, message: "File is missing"))
        list.update([note])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        XCTAssertEqual(cell.accessibilityChildren()?.compactMap { ($0 as? NSTextField)?.stringValue }.first, "File not located…")
        let buttons = cell.accessibilityChildren()?.compactMap { $0 as? NSButton } ?? []
        XCTAssertFalse(buttons.contains { ["Retry", "Locate file…", "Remove from list"].contains($0.title) })
        let available = snapshot(filename: "available.txt", text: "Available note")
        list.update([note, available])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertGreaterThan(list.tableView(list.table, heightOfRow: 0), 0)
        XCTAssertEqual(list.tableView(list.table, heightOfRow: 0), list.tableView(list.table, heightOfRow: 1))
        let location = try XCTUnwrap(buttons.first { $0.toolTip == note.fileURL.path })
        XCTAssertEqual(location.cell?.lineBreakMode, .byTruncatingMiddle)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            cell.appearance = NSAppearance(named: appearance)
            cell.frame = NSRect(x: 0, y: 0, width: 396, height: 148)
            cell.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(location.convert(location.bounds, to: cell).maxX, cell.bounds.maxX)
        }
    }
}

extension SearchTests {
    @MainActor
    func testRetainedLiveTextRemainsSearchableWithLocationAction() async throws {
        let list = NoteListController()
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/notes/a.txt"), fileRevision: nil, text: "retained needle", availability: .available)
        list.search.stringValue = "needle"
        list.update([note], availability: [note.id: .missingOriginal])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.numberOfRows(in: list.table), 1)
        let cell = try XCTUnwrap(list.tableView(list.table, viewFor: list.table.tableColumns[0], row: 0))
        let children = cell.accessibilityChildren() ?? []
        XCTAssertTrue(children.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("needle") })
        XCTAssertTrue(children.compactMap { $0 as? NSButton }.contains { $0.toolTip == note.fileURL.path })
        XCTAssertTrue(list.status.stringValue.contains("1 unavailable file"))
        XCTAssertEqual(list.menu(forRow: 0)?.items.first { $0.title == "Remove from List" }?.toolTip,
                       "Removing this entry does not delete any files.")
    }

    @MainActor
    func testRegisteredFilesSelectVisibleMatchesAndReportFilteredFiles() async throws {
        let list = NoteListController()
        let visible = snapshot(filename: "visible.txt", text: "needle")
        let hidden = snapshot(filename: "hidden.txt", text: "other")
        list.search.stringValue = "needle"
        list.update([visible, hidden])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        list.selectRegisteredFiles(ids: [visible.id, hidden.id])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertEqual(list.search.stringValue, "needle")
        XCTAssertEqual(list.selectedNotes.map(\.id), [visible.id])
        XCTAssertEqual(list.status.stringValue, "Added 2 files. 1 hidden by the current search.")
    }

    @MainActor
    func testEmptyListOffersAccessibleAddExistingAction() async throws {
        let list = NoteListController()
        var invoked = false
        list.testDelegate.onAddExistingFiles = { invoked = true }
        list.update([])
        try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
        XCTAssertTrue(list.emptyAddButton.isHidden == false)
        XCTAssertTrue(list.emptyAddButton.canBecomeKeyView)
        XCTAssertTrue(list.emptyAddButton.acceptsFirstResponder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = list.view
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(list.emptyAddButton))
        XCTAssertTrue(window.firstResponder === list.emptyAddButton)
        XCTAssertEqual(list.emptyAddButton.accessibilityLabel(), "Add Existing Files")
        list.emptyAddButton.performClick(nil)
        XCTAssertTrue(invoked)
        XCTAssertTrue(list.search.nextKeyView is ActionButton)
        XCTAssertTrue(list.search.nextKeyView?.nextKeyView === list.sortPicker)
        XCTAssertTrue(list.sortPicker.nextKeyView === list.emptyAddButton)
        XCTAssertTrue(list.emptyAddButton.nextKeyView === list.table)
        XCTAssertTrue(list.table.nextKeyView === list.search)
    }
}

@MainActor
final class NoteListWarningIconTests: XCTestCase {
    func testWarningIconStaysRedInSelectedRow() throws {
        let icon = NoteListWarningIcon(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemRed
        icon.appearance = NSAppearance(named: .aqua)
        icon.cell?.backgroundStyle = .emphasized
        let bitmap = try XCTUnwrap(icon.bitmapImageRepForCachingDisplay(in: icon.bounds))
        icon.cacheDisplay(in: icon.bounds, to: bitmap)
        var redPixels = 0
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
            if color.redComponent > 0.6, color.greenComponent < 0.45, color.blueComponent < 0.45 { redPixels += 1 }
        } }
        XCTAssertGreaterThan(redPixels, 10, "A selected row must keep the red warning icon visible")
    }
}

/// The title label inside a note card's text column: title block, then title line, then the label.
@MainActor
private func previewLabel(in text: NSStackView) -> NSTextField? {
    let block = text.arrangedSubviews.first as? NSStackView
    let line = block?.arrangedSubviews.first as? NSStackView
    return line?.arrangedSubviews.last as? NSTextField
}

final class NoteListItemTests: XCTestCase {
    func testCaptureMakesRetainedTextSearchableAndSortsByEditTime() async {
        let modified = Date(timeIntervalSince1970: 100)
        let edited = Date(timeIntervalSince1970: 500)
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/notes/a.txt"),
            fileRevision: FileRevision(fingerprint: "f", modifiedAt: modified), text: "", availability: .missingOriginal)
        let item = NoteListItem(note: note, capture: NoteListEditCapture(text: "retained needle", editedAt: edited))
        XCTAssertEqual(item.note, note, "Actions keep the verified snapshot")
        XCTAssertEqual(item.textAvailability, .available)
        XCTAssertEqual(item.sourceAvailability, .missingOriginal)
        XCTAssertEqual(item.updatedAt, edited)
        let matches = await SearchIndex().search([item.searchDocument], query: SearchQuery(text: "needle"))
        XCTAssertEqual(matches.map(\.id), [note.id])
        XCTAssertEqual(NoteListController.unavailableDetail(item), String(localized: "Local text is retained. The original file is unavailable."))
    }

    func testUnavailableExcerptIsAValueThatPresentationFormats() async {
        let note = NoteSnapshot(id: NoteID(), collectionToken: CollectionToken(), fileURL: URL(fileURLWithPath: "/notes/a.txt"),
            fileRevision: nil, text: "", availability: .trashed)
        let matches = await SearchIndex().search([SearchDocument(note)], query: SearchQuery(text: ""))
        XCTAssertEqual(matches.first?.excerpt, .unavailable(.trashed))
        XCTAssertEqual(NoteListController.unavailableDetail(NoteListItem(note: note)),
                       String(localized: "File was moved to Trash", comment: "Row title for a note whose file was moved to the Trash. Use the system term for Trash"))
    }
}

/// A search match paired with its snapshot, formatted the way the list shows it.
struct IndexedSearchResult {
    let note: NoteSnapshot
    let match: SearchMatch
    var preview: String { match.preview }
    var snippet: String {
        if case let .text(text) = match.excerpt { return text }
        return NoteListController.unavailableDetail(NoteListItem(note: note))
    }
}

extension SearchIndex {
    func search(notes: [NoteSnapshot], query: String, sort: NoteSort = .updated, ascending: Bool = false) -> [IndexedSearchResult] {
        search(notes.map(SearchDocument.init), query: SearchQuery(text: query, sort: sort, ascending: ascending))
            .map { IndexedSearchResult(note: notes[$0.offset], match: $0) }
    }
}
