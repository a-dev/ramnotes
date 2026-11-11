import ramnotesDomain
import AppKit
import XCTest
@testable import ramnotes

@MainActor
final class RecoveryInteractionTests: XCTestCase {
    func testRecoveryNoticeAnnouncesOnceUntilItChanges() async throws {
        let setup = try await makeAccessibilityRecoverySetup()
        defer { setup.window.orderOut(nil) }
        let initialNotice = setup.notice(originalMissing: false)
        setup.controller.setRecoveryNotice(initialNotice)
        XCTAssertEqual(setup.announcements.values.count, 1)
        setup.controller.setRecoveryNotice(initialNotice)
        XCTAssertEqual(setup.announcements.values.count, 1, "A repeated recovery notice must not repeat speech")

        let changedNotice = setup.notice(originalMissing: true)
        setup.controller.setRecoveryNotice(changedNotice)
        let noticeAnnouncement = setup.announcements.values.last
        setup.controller.setRecoveryNotice(changedNotice)
        XCTAssertEqual(setup.announcements.values.last, noticeAnnouncement)
        XCTAssertEqual(setup.announcements.values.count, 2, "Repeated recovery notices must not repeat speech")
    }

    func testNotePreservedInRecoveryKeepsItsListDateWhileTyping() async throws {
        let setup = try await makeAccessibilityRecoverySetup()
        defer { setup.window.orderOut(nil) }
        setup.editor.textView.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        setup.editor.capture()
        XCTAssertNotNil(setup.controller.listedEditTime, "Unsaved edits sort the note as just updated")
        setup.controller.setRecoveryNotice(setup.notice(originalMissing: false))
        setup.editor.textView.insertText("b", replacementRange: NSRange(location: 0, length: 0))
        setup.editor.capture()
        XCTAssertNil(setup.controller.listedEditTime, "The recovery note carries the edits, so the original keeps its file date")
    }

    func testWarningWaitsUntilTypingPausesAndIsSpokenOnce() async throws {
        let announcements = AccessibilityAnnouncements()
        var busy = true
        var delivered: [String] = []
        announcements.isBusy = { busy }
        announcements.quietCheckInterval = .milliseconds(10)
        announcements.deliver = { message, _ in delivered.append(message) }
        announcements.update("Save failed", for: "save", priority: .high)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(delivered, [], "Key echo would cut the warning off while the user types")
        busy = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(delivered, ["Save failed"])
        // A warning that no longer applies when typing pauses is not spoken.
        busy = true
        announcements.update("Cannot close", for: "blocker")
        announcements.update(nil, for: "blocker")
        busy = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(delivered, ["Save failed"])
    }

    func testCloseWithoutSavingStaysAvailableRedAndTrailingWhileTextIsUnsaved() async throws {
        let setup = try await makeAccessibilityRecoverySetup()
        defer { setup.window.orderOut(nil) }
        setup.editor.textView.insertText("unsaved", replacementRange: NSRange(location: 0, length: 0))
        setup.controller.showBlocker(NoteOperationError.permissionDenied)
        setup.window.contentView?.layoutSubtreeIfNeeded()
        let discard = try XCTUnwrap(setup.controller.recoveryActionButtons["Close Without Saving…"])
        let export = try XCTUnwrap(setup.controller.recoveryActionButtons["Export"])
        XCTAssertFalse(discard.isHidden, "A blocked close must always offer a way out")
        XCTAssertEqual(setup.controller.recoveryActionButtons["Save a Copy…"]?.isHidden, false, "Unsaved blocked text can be saved as a copy")
        let color = discard.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .systemRed)
        discard.font = .systemFont(ofSize: 20)
        XCTAssertEqual(discard.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed, "Interface scaling keeps the red title")
        let container = try XCTUnwrap(discard.superview)
        if abs(discard.frame.minY - export.frame.minY) < 1 {
            XCTAssertEqual(discard.frame.maxX, container.bounds.width, accuracy: 1, "On a shared row the destructive action sits at the trailing edge")
        } else {
            XCTAssertEqual(discard.frame.minX, 0, accuracy: 1, "On its own row the destructive action starts at the leading edge")
        }
        XCTAssertGreaterThanOrEqual(discard.frame.maxX, export.frame.maxX)
    }

    func testWrappedCloseWithoutSavingStartsAtTheLeadingEdge() {
        let view = RecoveryActionsView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let export = NSButton(title: "Export", target: nil, action: nil)
        let copy = NSButton(title: "Save a Copy…", target: nil, action: nil)
        let discard = DestructiveButton(title: "Close Without Saving…", target: nil, action: nil)
        [export, copy, discard].forEach(view.addSubview)
        view.trailing = discard
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(discard.frame.minY, export.frame.maxY, "Too narrow for one row, so it wraps")
        XCTAssertEqual(discard.frame.minX, 0, accuracy: 0.5, "A wrapped destructive action lines up under the other actions")
        view.setFrameSize(NSSize(width: 600, height: 100))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(discard.frame.minY, export.frame.minY, accuracy: 0.5)
        XCTAssertEqual(discard.frame.maxX, 600, accuracy: 0.5, "On a shared row it stays apart at the trailing edge")
    }

    func testSaveFailureAnnouncementsDeduplicateAndResetAfterSave() async throws {
        let setup = try await makeAccessibilityRecoverySetup()
        defer { setup.window.orderOut(nil) }
        let controller = setup.controller
        let window = setup.window
        let editor = setup.editor
        controller.display(.failed(EditRevision(rawValue: 1), .inputOutput("A01 disposable off-focus save failure with a long explanation"), journaled: false))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === editor.textView)
        XCTAssertTrue(controller.status.stringValue.contains("A01 disposable off-focus save failure"))
        XCTAssertEqual(setup.announcements.values.count, 1)
        XCTAssertEqual(setup.announcements.priorities, [.high], "Key echo while typing must not cut off the save warning")
        let actionButtons = controller.recoveryActionButtons
        XCTAssertFalse(actionButtons["Save a Copy…"]?.isHidden ?? true)
        XCTAssertTrue(actionButtons["Save a Copy…"]?.isEnabled ?? false)
        XCTAssertTrue(actionButtons["Locate File…"]?.isHidden ?? false, "A save failure with the file present has nothing to locate")
        XCTAssertTrue(actionButtons["Open Original"]?.isHidden ?? false, "A save failure without a recovery note has no original to open")
        XCTAssertTrue(actionButtons["Open Recovery"]?.isHidden ?? false, "A save failure without a recovery note has no recovery note to open")
        controller.display(.pending(EditRevision(rawValue: 2)))
        controller.display(.failed(EditRevision(rawValue: 1), .inputOutput("A01 disposable off-focus save failure with a long explanation"), journaled: false))
        XCTAssertEqual(setup.announcements.values.count, 1, "A pending retry and repeated failure must not repeat speech")
        controller.display(.failed(EditRevision(rawValue: 2), .inputOutput("A01 changed save failure"), journaled: false))
        XCTAssertEqual(setup.announcements.values.last, controller.status.stringValue)
        XCTAssertEqual(setup.announcements.values.count, 2)
        controller.display(.saved(EditRevision(rawValue: 2)))
        XCTAssertEqual(controller.status.stringValue, "")
        controller.display(.failed(EditRevision(rawValue: 3), .inputOutput("A01 disposable off-focus save failure with a long explanation"), journaled: false))
        XCTAssertEqual(setup.announcements.values.count, 3, "A saved state resets the save announcement so a later recurrence is spoken")
        XCTAssertTrue(window.firstResponder === editor.textView)

        let prepared = setup.prepared
        let exportSequence = RecoveryExportSequence()
        let viewer = RecoveryWindowController(record: RetainedEditSummary(recoveryRecord(prepared)), exporter: exportSequence)
        var exportAnnouncements: [String] = []
        viewer.announcements.deliver = { message, _ in exportAnnouncements.append(message) }
        defer { viewer.window?.orderOut(nil) }
        viewer.window?.makeKeyAndOrderFront(nil)
        viewer.window?.makeFirstResponder(viewer.textView)
        viewer.export(to: prepared.fixture.root.appendingPathComponent("export.txt"))
        for _ in 0..<100 where !viewer.status.stringValue.contains("A01 disposable export failure") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewer.status.stringValue.contains("A01 disposable export failure"))
        XCTAssertEqual(exportAnnouncements.count, 1)
        XCTAssertTrue(exportAnnouncements[0].contains("A01 disposable export failure"))
        XCTAssertTrue(viewer.window?.firstResponder === viewer.textView)
        viewer.export(to: prepared.fixture.root.appendingPathComponent("export.txt"))
        for _ in 0..<100 where viewer.status.stringValue.contains("Exporting…") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewer.status.stringValue.contains("A01 disposable export failure"))
        XCTAssertEqual(exportAnnouncements.count, 1, "A repeated export failure must not repeat speech")
        viewer.export(to: prepared.fixture.root.appendingPathComponent("export.txt"))
        for _ in 0..<100 where viewer.status.stringValue.contains("Exporting…") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewer.status.stringValue.contains("Exported and verified"))
        XCTAssertEqual(exportAnnouncements.count, 1, "A successful export clears the failure without announcing success")
        viewer.export(to: prepared.fixture.root.appendingPathComponent("export.txt"))
        for _ in 0..<100 where viewer.status.stringValue.contains("Exporting…") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(viewer.status.stringValue.contains("A01 disposable export failure"))
        XCTAssertEqual(exportAnnouncements.count, 2, "A later export failure is announced after success reset")
        XCTAssertTrue(viewer.window?.firstResponder === viewer.textView)
        XCTAssertEqual(viewer.textView.accessibilityLabel(), "Recovery text")
        let recovery = XCTAttachment(string: "Text label: \(viewer.textView.accessibilityLabel() ?? "")\nExport: \(viewer.exportButton.accessibilityLabel() ?? "")\nStatus: \(viewer.status.stringValue)")
        recovery.name = "A01 recovery viewer accessibility properties and export failure"
        recovery.lifetime = .keepAlways
        add(recovery)
    }

    func testBlockerAnnouncesAndKeepsEditorFocus() async throws {
        let setup = try await makeAccessibilityRecoverySetup()
        defer { setup.window.orderOut(nil) }
        setup.controller.showBlocker(NoteOperationError.permissionDenied, operation: .export)
        XCTAssertTrue(setup.controller.status.stringValue.hasPrefix("Cannot export:"))
        XCTAssertEqual(setup.announcements.values.last, setup.controller.status.stringValue)
        XCTAssertEqual(setup.announcements.values.count, 1)
        XCTAssertTrue(setup.window.firstResponder === setup.editor.textView)
    }

    func testRecoveryActionsFitAt375PointWidth() async throws {
        let setup = try await makeAccessibilityRecoverySetup()
        defer { setup.window.orderOut(nil) }
        let controller = setup.controller
        let window = setup.window
        let initialNotice = setup.notice(originalMissing: false)
        controller.setRecoveryNotice(initialNotice)
        controller.display(.failed(EditRevision(rawValue: 1), .inputOutput("A01 disposable off-focus save failure with a long explanation"), journaled: false))
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = controller.recoveryActionButtons.values.filter { !$0.isHidden }
        let content = try XCTUnwrap(window.contentView)
        let viewport = content.convert(window.contentLayoutRect, from: nil)
        let measurements = buttons.map { button in
            let rect = button.convert(button.bounds, to: window.contentView)
            return "\(button.title): frame=\(rect), insideViewport=\(viewport.contains(rect)), enabled=\(button.isEnabled)"
        }.joined(separator: "\n")
        let layout = XCTAttachment(string: "Requested width=375; actual width=\(window.frame.width); viewport=\(viewport); content bounds=\(content.bounds)\n" + measurements)
        layout.name = "A04 375-point recovery action geometry"
        layout.lifetime = .keepAlways
        add(layout)
        for button in buttons {
            let rect = button.convert(button.bounds, to: content)
            XCTAssertTrue(viewport.contains(rect), "\(button.title) should fit in the recovery viewport: \(rect), viewport: \(viewport)")
        }
        XCTAssertFalse(buttons.contains { $0.title == "Retry" })
        XCTAssertTrue(buttons.contains { $0.title == "Export" })
        let actionButtons = controller.recoveryActionButtons
        XCTAssertTrue(actionButtons["Restore File Access…"]?.isHidden ?? false)
        XCTAssertFalse(actionButtons["Open Original"]?.isHidden ?? true)
        XCTAssertFalse(actionButtons["Open Recovery"]?.isHidden ?? true)
        controller.setRecoveryNotice(setup.notice(originalMissing: true))
        XCTAssertTrue(actionButtons["Open Original"]?.isHidden ?? false)
        XCTAssertFalse(actionButtons["Open Recovery"]?.isHidden ?? true)
        controller.setRecoveryNotice(setup.notice(originalMissing: false))
        controller.setRecoveryNotice(initialNotice)
        let exportButton = try XCTUnwrap(buttons.first { $0.title == "Export" })
        XCTAssertTrue(window.makeFirstResponder(setup.editor.textView))
        controller.restoreRecoveryActionFocus(to: "Export")
        XCTAssertTrue(window.firstResponder === exportButton, "A dismissed export panel should return focus to Export")
        controller.restoreRecoveryActionFocus(to: "Open Recovery")
        XCTAssertTrue(window.firstResponder === actionButtons["Open Recovery"])

        window.setFrame(NSRect(x: 180, y: 180, width: 375, height: 260), display: true)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(setup.editor.scrollView.frame.height, 100, "The editor must remain usable at minimum height")
        let minimumViewport = content.convert(window.contentLayoutRect, from: nil)
        for button in buttons {
            let rect = button.convert(button.bounds, to: content)
            XCTAssertTrue(minimumViewport.contains(rect), "\(button.title) should remain visible at minimum height: \(rect), viewport: \(minimumViewport)")
        }
    }

    func testAccessibilityAnnouncementsTrackIndependentKeysAndReset() {
        let announcements = AccessibilityAnnouncements()
        var delivered: [String] = []
        announcements.deliver = { message, _ in delivered.append(message) }

        announcements.update("Save failed", for: "save")
        announcements.update("Recovery available", for: "recovery")
        announcements.update("Save failed", for: "save")
        XCTAssertEqual(delivered, ["Save failed", "Recovery available"])

        announcements.update(nil, for: "save")
        announcements.update("Save failed", for: "save")
        announcements.update("Recovery available", for: "recovery")
        XCTAssertEqual(delivered, ["Save failed", "Recovery available", "Save failed"],
                       "Resetting one key permits its recurrence without resetting another key")
    }

    func testRecoveryViewerUsesLiveNoteTypographyAndKeepsSelectionOnResize() async throws {
        let prepared = try await makeRecoveryNote()
        let record = recoveryRecord(prepared)
        let viewer = RecoveryWindowController(record: RetainedEditSummary(record))
        defer { viewer.window?.orderOut(nil) }
        viewer.window?.makeKeyAndOrderFront(nil)

        var settings = AppSettings()
        settings.fontSize = 18
        settings.lineHeight = 28
        settings.fontFamily = "System"
        settings.fontWeight = "Bold"
        viewer.apply(settings)
        viewer.textView.setSelectedRange(NSRange(location: 0, length: min(4, (record.text as NSString).length)))
        let selection = viewer.textView.selectedRanges
        XCTAssertFalse(viewer.textView.isEditable)
        XCTAssertTrue(viewer.textView.isSelectable)
        XCTAssertEqual(viewer.textView.defaultParagraphStyle?.minimumLineHeight, 28)
        XCTAssertEqual(viewer.textView.font?.pointSize, 18)
        XCTAssertEqual(viewer.textView.font?.fontDescriptor.symbolicTraits.contains(.bold), true)

        settings.fontSize = 22
        viewer.apply(settings)
        XCTAssertEqual(viewer.textView.font?.pointSize, 22, "Settings changes should update an already open recovery viewer")
        XCTAssertEqual(viewer.textView.selectedRanges.map(\.rangeValue), selection.map(\.rangeValue))
        let minimum = try XCTUnwrap(viewer.window?.minSize)
        viewer.window?.setFrame(NSRect(origin: NSPoint(x: 180, y: 180), size: minimum), display: true)
        viewer.window?.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(viewer.window?.contentView)
        let export = viewer.exportButton.convert(viewer.exportButton.bounds, to: content)
        let status = viewer.status.convert(viewer.status.bounds, to: content)
        XCTAssertTrue(content.bounds.contains(export), "Export should fit at the minimum size")
        XCTAssertEqual(viewer.exportButton.keyEquivalent, "\r", "Export is the default, highlighted button")
        XCTAssertLessThan(abs(export.minX - status.minX), 3, "Export and the explanation share the leading edge")
        XCTAssertEqual(content.isFlipped ? status.minY - export.maxY : export.minY - status.maxY, 12, accuracy: 1, "12 pt between Export and the explanation")
    }

    func testMissingDefaultFolderShowsFooterMessage() throws {
        let list = ListWindowController()
        defer { list.window?.orderOut(nil) }
        list.present(focusing: nil, refresh: {})
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let views = descendants(try XCTUnwrap(list.window?.contentView))
        let footer = try XCTUnwrap(views.compactMap { $0 as? NSBox }.first)
        list.defaultFolderMissing = true
        XCTAssertFalse(footer.isHidden)
        XCTAssertEqual(footer.borderColor, .systemRed)
        XCTAssertFalse(list.missingFolderLabel.isHidden)
        XCTAssertEqual(list.missingFolderLabel.stringValue, "Default folder is missing. Choose one in Settings.")
        list.defaultFolderMissing = false
        XCTAssertTrue(list.missingFolderLabel.isHidden)
    }

    func testFooterDropsStaleActionResultAndLeavesNoteProblemsToCards() throws {
        let list = ListWindowController()
        defer { list.window?.orderOut(nil) }
        list.present(focusing: nil, refresh: {})
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let footer = try XCTUnwrap(descendants(try XCTUnwrap(list.window?.contentView)).compactMap { $0 as? NSBox }.first)
        XCTAssertFalse(descendants(footer).contains { ($0 as? NSButton)?.title.hasPrefix("Locate") == true })
        let token = CollectionToken()
        func note(_ id: NoteID, _ name: String, _ availability: NoteAvailability) -> NoteSnapshot {
            NoteSnapshot(id: id, collectionToken: token, fileURL: URL(fileURLWithPath: "/notes/\(name)"), fileRevision: nil,
                         text: name, availability: availability)
        }
        let kept = NoteID(), trashed = NoteID()
        list.discovery.update([note(kept, "disk-2.txt", .available), note(trashed, "old.txt", .available)])

        // The action's own change (a removed note) keeps its result.
        list.showActionResult("Moved 1 note to Trash.")
        list.discovery.update([note(kept, "disk-2.txt", .available)])
        XCTAssertEqual(list.diagnostic.stringValue, "Moved 1 note to Trash.")

        // A later, unrelated availability change ends the old result.
        list.discovery.update([note(kept, "disk-2.txt", .unavailable(reason: "Ejected"))])
        XCTAssertEqual(list.diagnostic.stringValue, "")
        XCTAssertTrue(list.diagnostic.isHidden)
        // An unavailable note is a card problem, not a footer error.
        XCTAssertNotEqual(footer.borderColor, .systemRed)
    }

    func testNoteListFailureAnnouncementPreservesOtherWindowFocusAndDeduplicates() throws {
        let otherWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        defer { otherWindow.orderOut(nil) }
        let focusedField = NSTextField(string: "Keep focus")
        otherWindow.contentView = focusedField
        otherWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(otherWindow.makeFirstResponder(focusedField))
        let focusedResponder = try XCTUnwrap(otherWindow.firstResponder)
        let keyWindowBefore = NSApp.keyWindow

        let list = ListWindowController()
        defer { list.window?.orderOut(nil) }
        var delivered: [String] = []
        list.announcements.deliver = { message, _ in delivered.append(message) }
        var refreshCount = 0
        list.showFailure("Cannot quit: save failed", refresh: { refreshCount += 1 })
        XCTAssertEqual(delivered, ["Cannot quit: save failed"])
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertTrue(otherWindow.firstResponder === focusedResponder)

        list.showFailure("Cannot quit: save failed", refresh: { refreshCount += 1 })
        XCTAssertEqual(delivered, ["Cannot quit: save failed"])
        list.showFailure("Cannot quit: folder unavailable", refresh: { refreshCount += 1 })
        XCTAssertEqual(delivered, ["Cannot quit: save failed", "Cannot quit: folder unavailable"])
        XCTAssertEqual(refreshCount, 3)
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore)
        XCTAssertTrue(otherWindow.firstResponder === focusedResponder)
    }

    func testRecoveryOriginalLinkFollowsNoteIDAfterMoveAndIgnoresFormerPathReplacement() async throws {
        let prepared = try await makeRecoveryNote()
        let recovery = try await prepared.store.create(in: prepared.folder, collectionToken: prepared.collectionToken)
        let notice = RecoveryNotice(originalURL: prepared.note.fileURL, recoveryURL: recovery.fileURL, originalMissing: false,
            recoveryNoteID: recovery.id, sourceNoteID: prepared.note.id)
        let target = prepared.folder.appendingPathComponent("Moved original.txt")
        let result = await prepared.store.moveNote(prepared.note.id, to: target, collectionToken: prepared.collectionToken,
            locationRevision: prepared.note.locationRevision, editRevision: prepared.note.editRevision)
        guard case .moved = result.outcome else { return XCTFail("Move failed") }
        let moved = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)
        try Data("unrelated replacement".utf8).write(to: prepared.note.fileURL)
        let replacement = try await prepared.store.adopt(prepared.note.fileURL)
        let host = TestRecoveryHost(store: prepared.store)
        host.folderState.replace(with: [moved.id: moved, replacement.id: replacement, recovery.id: recovery])
        let windows = WindowCoordinator(store: prepared.store)
        host.windows = windows
        defer { windows.perform(.hide) }
        windows.open(recovery, focus: false)
        let controller = try XCTUnwrap(windows.windows[recovery.id])
        let owner = RecoveryController(host: host)
        owner.configureRecovery(controller)
        controller.setRecoveryNotice(notice)
        controller.originalRequested?()
        XCTAssertEqual(windows.windows[moved.id]?.editor.note.fileURL, target)
        XCTAssertNil(windows.windows[replacement.id])
        owner.recoveryNotices = [recovery.fileURL: notice]
        let movedController = try XCTUnwrap(windows.windows[moved.id])
        owner.configureRecovery(movedController)
        XCTAssertEqual(movedController.recoveryNotice?.sourceNoteID, moved.id)
    }

    func testFlushFailureRetainsDraftUntilVerifiedExportUnblocksIt() async throws {
        let prepared = try await makeRecoveryNote(failJournalAndDestination: true)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(prepared.note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[prepared.note.id]?.editor)
        let draft = "未保存 ☕\nsecond line"
        editor.textView.string = draft
        editor.capture()

        do {
            try await coordinator.flush()
            XCTFail("The injected journal and destination failures should block flush")
        } catch { }

        let retained = await prepared.store.retainedBuffer(prepared.note.id)
        let canDisposeBeforeExport = await prepared.store.canDispose(prepared.note.id)
        XCTAssertEqual(editor.textView.string, draft)
        XCTAssertEqual(retained?.text, draft)
        XCTAssertFalse(canDisposeBeforeExport)

        let exportURL = prepared.fixture.root.appendingPathComponent("exported draft.txt")
        try await editor.export(to: exportURL)
        try await coordinator.flush()

        let canDisposeAfterExport = await prepared.store.canDispose(prepared.note.id)
        XCTAssertEqual(try Data(contentsOf: exportURL), Data(draft.utf8))
        XCTAssertTrue(canDisposeAfterExport)
    }

    func testBlankDurableNoteIsStillBlankAfterStoreRestart() async throws {
        let prepared = try await makeRecoveryNote()
        let blank = try await prepared.store.create(in: prepared.folder, collectionToken: prepared.collectionToken)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(blank, new: true, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[blank.id]?.editor)

        XCTAssertEqual(editor.textView.string, "")
        try await editor.flush()
        XCTAssertEqual(try Data(contentsOf: blank.fileURL), Data())

        let restarted = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        let nextGeneration = CollectionToken()
        let notes = try await restarted.discover(in: prepared.folder, collectionToken: nextGeneration)
        let reopened = try XCTUnwrap(notes.first { $0.id == blank.id })
        XCTAssertEqual(reopened.text, "")
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL), Data())
    }

    func testStartupJournalReplayAppearsInReopenedEditorText() async throws {
        let prepared = try await makeRecoveryNote(failDestination: true)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(prepared.note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[prepared.note.id]?.editor)
        let draft = "replayed startup draft"
        editor.textView.string = draft
        editor.capture()

        do {
            try await coordinator.flush()
            XCTFail("The injected destination failure should leave a durable journal")
        } catch { }

        let restarted = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        let collectionToken = CollectionToken()
        _ = try await restarted.discover(in: prepared.folder, collectionToken: collectionToken)
        let replayDiagnostics = await restarted.replayRecovery()
        XCTAssertTrue(replayDiagnostics.isEmpty)
        let recovered = try await restarted.read(prepared.note.id, collectionToken: collectionToken)
        XCTAssertEqual(recovered.text, draft)

        let reopenedCoordinator = WindowCoordinator(store: restarted)
        reopenedCoordinator.open(recovered, focus: false)
        let reopenedEditor = try XCTUnwrap(reopenedCoordinator.windows[prepared.note.id]?.editor)
        XCTAssertEqual(reopenedEditor.textView.string, draft)

        let nextDraft = "\(draft) with a later edit"
        reopenedEditor.textView.string = nextDraft
        reopenedEditor.capture()
        try await reopenedEditor.flush()

        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data(nextDraft.utf8))
    }

    func testFailedStartupReplayRestoresJournalTextIntoEditor() async throws {
        let prepared = try await makeRecoveryNote(failDestination: true)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(prepared.note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[prepared.note.id]?.editor)
        let draft = "journal remains after replay failure"
        editor.textView.string = draft
        editor.capture()
        do {
            try await coordinator.flush()
            XCTFail("The injected destination failure should leave a durable journal")
        } catch { }

        let restarted = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock, fault: { stage in
            if case .destination = stage { throw NoteOperationError.permissionDenied }
        })
        let collectionToken = CollectionToken()
        let notes = try await restarted.discover(in: prepared.folder, collectionToken: collectionToken)
        _ = await restarted.replayRecovery()
        let retainedValue = await restarted.retainedBuffer(prepared.note.id)
        let retained = try XCTUnwrap(retainedValue)
        let reopenedCoordinator = WindowCoordinator(store: restarted)
        reopenedCoordinator.adoptRetainedEdits([prepared.note.id: retained])
        reopenedCoordinator.open(try XCTUnwrap(notes.first { $0.id == prepared.note.id }), focus: false)

        let reopenedEditor = try XCTUnwrap(reopenedCoordinator.windows[prepared.note.id]?.editor)
        XCTAssertEqual(reopenedEditor.textView.string, draft)
        XCTAssertTrue(reopenedEditor.state.hasUnsavedEdits)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testRetainedEditIsNotRestoredAgainAfterSaveCloseAndReopen() async throws {
        let prepared = try await makeRecoveryNote()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.adoptRetainedEdits([prepared.note.id: EditSnapshot(
            id: prepared.note.id, collectionToken: prepared.collectionToken, revision: EditRevision(rawValue: 1),
            baseRevision: prepared.note.fileRevision, text: "A")])
        coordinator.open(prepared.note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[prepared.note.id]?.editor)
        XCTAssertEqual(editor.textView.string, "A")
        for text in ["AB", "ABC"] {
            editor.textView.string = text
            editor.capture()
        }
        try await editor.flush()
        coordinator.closeNote(prepared.note.id)
        for _ in 0..<1000 where coordinator.windows[prepared.note.id] != nil { await Task.yield() }
        XCTAssertNil(coordinator.windows[prepared.note.id])

        let saved = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)
        coordinator.open(saved, focus: false)
        let reopened = try XCTUnwrap(coordinator.windows[prepared.note.id]?.editor)
        XCTAssertEqual(reopened.textView.string, "ABC")
        XCTAssertFalse(reopened.state.hasUnsavedEdits)

        reopened.textView.string = "typed after reopen"
        reopened.capture()
        try await reopened.flush()
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "typed after reopen")
    }

    func testStaleRestoredEditIsIgnoredWhenStoreAlreadySavedALaterRevision() async throws {
        let prepared = try await makeRecoveryNote()
        let savedNote = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken, fileURL: prepared.note.fileURL,
            fileRevision: prepared.note.fileRevision, text: "ABC", availability: .available, editRevision: EditRevision(rawValue: 3))
        let stale = EditSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken, revision: EditRevision(rawValue: 1),
            baseRevision: prepared.note.fileRevision, text: "A")
        let editor = NoteEditorController(note: savedNote, store: prepared.store, restoredEdit: stale)

        XCTAssertEqual(editor.textView.string, "ABC")
        XCTAssertEqual(editor.state.currentRevision, EditRevision(rawValue: 3))
        XCTAssertFalse(editor.state.hasUnsavedEdits)
    }

    func testDirtyEditorAdoptsExternalRenameWithoutReloadingText() async throws {
        let prepared = try await makeRecoveryNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.string = "dirty draft"
        editor.capture()
        let renamed = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            fileURL: prepared.folder.appendingPathComponent("Renamed.txt"), fileRevision: prepared.note.fileRevision,
            text: prepared.note.text, availability: .available, editRevision: prepared.note.editRevision)

        XCTAssertFalse(editor.applyExternal(renamed), "Dirty text must not be reloaded")
        XCTAssertEqual(editor.note.fileURL, renamed.fileURL)
        XCTAssertEqual(editor.textView.string, "dirty draft")
        XCTAssertTrue(editor.state.hasUnsavedEdits)
        try await editor.flush()
    }

    func testOpeningHiddenNoteWhoseSaveFailsShowsItsWindowWithTheDraft() async throws {
        let prepared = try await makeRecoveryNote(failDestination: true)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let id = prepared.note.id
        coordinator.open(prepared.note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[id]?.editor)
        editor.textView.string = "draft"
        editor.capture()
        do { try await editor.flush(); XCTFail("The save must fail") } catch {}
        coordinator.perform(.escape(transientActive: false))
        XCTAssertEqual(coordinator.windows[id]?.window?.isVisible, false)

        await coordinator.openVerified(prepared.note, focus: false)

        XCTAssertEqual(coordinator.windows[id]?.window?.isVisible, true)
        XCTAssertEqual(coordinator.windows[id]?.editor.textView.string, "draft")
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testRestoredUnsavedEditReopensAtItsSavedCursorPosition() async throws {
        let prepared = try await makeRecoveryNote(failDestination: true)
        let id = prepared.note.id
        let coordinator = WindowCoordinator(store: prepared.store)
        coordinator.open(prepared.note, focus: true)
        let editor = try XCTUnwrap(coordinator.windows[id]?.editor)
        editor.textView.string = "line one\nline two"
        editor.capture()
        editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
        do { try await editor.flush(); XCTFail("The save must fail") } catch {}
        let position = editor.editorPosition
        coordinator.perform(.hide)
        let retainedValue = await prepared.store.retainedBuffer(id)
        let retained = try XCTUnwrap(retainedValue)

        let matching = WindowCoordinator(store: prepared.store)
        defer { matching.perform(.hide) }
        matching.adoptRetainedEdits([id: retained])
        matching.metadata.notes[id] = NoteWindowMetadata(isOpen: true)
        matching.metadata.notes[id]?.editorPosition = position
        matching.open(prepared.note, focus: true)
        XCTAssertEqual(matching.windows[id]?.editor.textView.selectedRange(), NSRange(location: 12, length: 0))

        let stale = WindowCoordinator(store: prepared.store)
        defer { stale.perform(.hide) }
        stale.adoptRetainedEdits([id: retained])
        stale.metadata.notes[id] = NoteWindowMetadata(isOpen: true)
        stale.metadata.notes[id]?.editorPosition = EditorPosition(selections: [.init(location: 12, length: 0)], scrollX: 0, scrollY: 0,
            hasActiveCaret: true, fileModifiedAt: position.fileModifiedAt, unsavedRevision: EditRevision(rawValue: 99))
        stale.open(prepared.note, focus: true)
        XCTAssertEqual(stale.windows[id]?.editor.textView.selectedRange(), NSRange(location: 0, length: 0),
                       "A position from another edit must not be applied to this text")
    }

    func testRepeatedCloseRequestsRunOneFlushAndNotifyOnce() async throws {
        let prepared = try await makeRecoveryNote()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let id = prepared.note.id
        coordinator.open(prepared.note, focus: false)
        var openStateChanges = 0
        coordinator.openStateChanged = { openStateChanges += 1 }

        coordinator.closeNote(id)
        coordinator.closeNote(id)
        XCTAssertTrue(coordinator.closing.contains(id))
        for _ in 0..<1000 where !coordinator.closing.isEmpty { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }

        XCTAssertNil(coordinator.windows[id])
        XCTAssertTrue(coordinator.closing.isEmpty)
        XCTAssertEqual(openStateChanges, 1)
    }

    func testExternalConflictKeepsLocalDraftAndReportsOriginalAndRecoveryURLs() async throws {
        let prepared = try await makeRecoveryNote()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(prepared.note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[prepared.note.id]?.editor)
        let localDraft = "local recovery draft"
        editor.textView.string = localDraft
        editor.capture()
        try await waitForPending(prepared.store, id: prepared.note.id)

        let externalText = "external disk version"
        try Data(externalText.utf8).write(to: prepared.note.fileURL, options: .atomic)
        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)

        let notices = await prepared.store.recoveryNotices()
        let notice = try XCTUnwrap(notices.first)
        let original = try await prepared.store.read(prepared.note.id, collectionToken: prepared.collectionToken)

        XCTAssertEqual(editor.textView.string, localDraft)
        XCTAssertEqual(original.text, externalText)
        XCTAssertEqual(notice.originalURL, prepared.note.fileURL)
        XCTAssertFalse(notice.originalMissing)
        XCTAssertEqual(try Data(contentsOf: notice.recoveryURL), Data(localDraft.utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notice.originalURL.path))
    }

    func testRecoveryViewerShowsSelectableReadOnlyTextAndAccessibleActions() throws {
        let fixture = try TestFixture()
        let originalURL = URL(fileURLWithPath: "/Volumes/Offline Notes/original.txt")
        let recoveryRecord = RecoveryRecord(
            id: UUID(), noteID: NoteID(), collectionToken: CollectionToken(), originalURL: originalURL,
            baseRevision: nil, editRevision: EditRevision(rawValue: 1), text: "recovery https://example.com text",
            createdAt: fixture.clock.now(), reason: .saveFailure
        )
        let viewer = RecoveryWindowController(record: RetainedEditSummary(recoveryRecord))
        let window = try XCTUnwrap(viewer.window)
        let root = try XCTUnwrap(window.contentView as? NSStackView)
        let scrollView = try XCTUnwrap(root.arrangedSubviews.compactMap { $0 as? NSScrollView }.first)

        XCTAssertTrue(scrollView.documentView === viewer.textView)
        XCTAssertEqual(viewer.textView.string, recoveryRecord.text)
        XCTAssertFalse(viewer.textView.isEditable)
        XCTAssertTrue(viewer.textView.isSelectable)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(viewer.exportButton.title, "Export")
        XCTAssertTrue(viewer.status.stringValue.contains(originalURL.path))
        XCTAssertTrue(viewer.status.stringValue.contains("local recovery journal"))
        var opened: [URL] = []
        viewer.textView.openURL = { opened.append($0) }
        let range = (viewer.textView.string as NSString).range(of: "https://example.com")
        viewer.textView.setSelectedRange(range)
        XCTAssertTrue(window.makeFirstResponder(viewer.textView))
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(PlainTextView.openLink(_:)), with: nil))
        XCTAssertEqual(opened.first?.host, "example.com")
        let action = try XCTUnwrap(viewer.textView.accessibilityCustomActions()?.first {
            $0.name == "Open Link: https://example.com"
        })
        XCTAssertTrue(try XCTUnwrap(action.handler)())
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(viewer.textView.string, recoveryRecord.text)
        XCTAssertFalse(viewer.textView.undoManager?.canUndo == true)
    }

}

@MainActor
private final class AnnouncementCapture { var values: [String] = []; var priorities: [NSAccessibilityPriorityLevel] = [] }

private struct AccessibilityRecoverySetup {
    let prepared: RecoveryPreparedNote
    let editor: NoteEditorController
    let controller: NoteWindowController
    let window: NSWindow
    let announcements: AnnouncementCapture

    func notice(originalMissing: Bool) -> RecoveryNotice {
        RecoveryNotice(originalURL: prepared.note.fileURL,
            recoveryURL: prepared.folder.appendingPathComponent("A01 preserved recovery.txt"),
            originalMissing: originalMissing, recoveryNoteID: NoteID())
    }
}

@MainActor
private func makeAccessibilityRecoverySetup() async throws -> AccessibilityRecoverySetup {
    let prepared = try await makeRecoveryNote(filename: "A01 long filename for narrow recovery controls and off-focus save failure.txt")
    let editor = NoteEditorController(note: prepared.note, store: prepared.store)
    let controller = NoteWindowController(editor: editor)
    let announcements = AnnouncementCapture()
    controller.announcements.deliver = { message, priority in announcements.values.append(message); announcements.priorities.append(priority) }
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 180, y: 180, width: 375, height: 420), display: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor.textView)
    return AccessibilityRecoverySetup(prepared: prepared, editor: editor, controller: controller,
        window: window, announcements: announcements)
}

private func waitForPending(_ store: NoteStore, id: NoteID) async throws {
    for _ in 0..<100 {
        if await store.pending[id] != nil { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Editor did not submit its draft to the store")
}

extension RecoveryInteractionTests {

    func testRecoveryOwnerReusesClosedWindowAndReleasesWithoutCycle() async throws {
        let prepared = try await makeRecoveryNote()
        let record = RetainedEditSummary(recoveryRecord(prepared))
        let host = TestRecoveryHost(store: prepared.store)
        var owner: RecoveryController? = RecoveryController(host: host)
        weak var weakOwner = owner
        owner?.openRetained(record)
        for _ in 0..<1000 where owner?.recoveryWindows[record.id] == nil { await Task.yield() }
        weak var window = owner?.recoveryWindows[record.id]
        XCTAssertNotNil(window)
        window?.close()
        owner?.openRetained(record)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(window === owner?.recoveryWindows[record.id])
        window?.close()
        owner = nil
        XCTAssertNil(weakOwner)
        // AppKit can keep a closed key window through the close notification.
        for _ in 0..<100 where window != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(window)
    }

    func testDelayedRecoveryOpenCoalescesAndExportOutlivesOwner() async throws {
        let prepared = try await makeRecoveryNote()
        let record = RetainedEditSummary(recoveryRecord(prepared))
        var gate: CheckedContinuation<NoteBackgroundTone?, Never>?
        var loads = 0
        let host = TestRecoveryHost(store: prepared.store)
        let owner = RecoveryController(host: host,
            loadTone: { _ in loads += 1; return await withCheckedContinuation { gate = $0 } })
        owner.openRetained(record)
        while gate == nil { await Task.yield() }
        owner.openRetained(record)
        XCTAssertEqual(loads, 1)
        gate?.resume(returning: .purple)
        for _ in 0..<1000 where owner.recoveryWindows[record.id] == nil { await Task.yield() }
        owner.recoveryWindows[record.id]?.close()

        let exporter = SuspendedRecoveryExport()
        var controller: RecoveryWindowController? = RecoveryWindowController(record: record, exporter: exporter)
        weak var retained = controller
        let target = prepared.fixture.root.appendingPathComponent("export.txt")
        controller?.export(to: target)
        await exporter.waitUntilStarted()
        controller?.close()
        controller = nil
        XCTAssertNotNil(retained)
        await exporter.release()
        for _ in 0..<1000 where retained != nil { await Task.yield() }
        XCTAssertNil(retained)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), record.text)
    }

    func testTrashingOriginalRemovesItsNotice() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        host.folder = FolderSelection(url: prepared.folder, collectionToken: prepared.collectionToken,
            notes: [prepared.note], recoveryDiagnostics: [])
        host.folderState.apply(.changed(prepared.note))
        let owner = RecoveryController(host: host)
        let notice = RecoveryNotice(originalURL: prepared.note.fileURL,
            recoveryURL: prepared.folder.appendingPathComponent("Recovery.txt"), originalMissing: false,
            recoveryNoteID: NoteID(), sourceNoteID: prepared.note.id)
        owner.recoveryNotices[notice.recoveryURL] = notice
        owner.deleteNotes([prepared.note])
        for _ in 0..<300 where host.messages.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(owner.recoveryNotices.isEmpty, host.messages.joined())
        let stack = NSStackView()
        owner.render(in: stack, height: nil)
        XCTAssertTrue(stack.arrangedSubviews.isEmpty)
    }

    func testProjectDropsNoticeTheStoreDroppedAndClearsItsBanner() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        host.folderState.apply(.changed(prepared.note))
        let coordinator = WindowCoordinator(store: prepared.store, folderState: host.folderState)
        host.windows = coordinator
        let owner = RecoveryController(host: host)
        coordinator.open(prepared.note, focus: false)
        let window = try XCTUnwrap(coordinator.windows[prepared.note.id])
        defer { window.window?.orderOut(nil) }
        let notice = RecoveryNotice(originalURL: prepared.note.fileURL,
            recoveryURL: prepared.folder.appendingPathComponent("A.txt"), originalMissing: false,
            recoveryNoteID: prepared.note.id, sourceNoteID: prepared.note.id)
        owner.project([notice])
        XCTAssertEqual(window.recoveryNotice, notice)
        owner.project([])
        XCTAssertTrue(owner.recoveryNotices.isEmpty)
        XCTAssertNil(window.recoveryNotice, "A dropped notice must clear the window banner")
    }

    func testProjectAnnouncesNewNoticeOnlyOnce() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        host.folderState.apply(.changed(prepared.note))
        let owner = RecoveryController(host: host)
        var spoken: [String] = []
        owner.announcements.deliver = { message, _ in spoken.append(message) }
        let notice = RecoveryNotice(originalURL: prepared.note.fileURL,
            recoveryURL: prepared.folder.appendingPathComponent("A.txt"), originalMissing: false,
            recoveryNoteID: NoteID(), sourceNoteID: prepared.note.id)
        owner.project([notice])
        XCTAssertEqual(spoken.count, 1, "A new notice is announced")
        owner.project([notice])
        XCTAssertEqual(spoken.count, 1, "An unchanged notice is not announced again")
        let another = RecoveryNotice(originalURL: notice.originalURL,
            recoveryURL: prepared.folder.appendingPathComponent("B.txt"), originalMissing: false,
            recoveryNoteID: NoteID(), sourceNoteID: prepared.note.id)
        owner.project([notice, another])
        XCTAssertEqual(spoken.count, 2, "A new notice is announced")
    }

    func testProjectSubmitsWindowStateOncePerProjection() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        host.folderState.apply(.changed(prepared.note))
        let owner = RecoveryController(host: host)
        let notices = (0..<3).map { index in
            RecoveryNotice(originalURL: prepared.note.fileURL,
                recoveryURL: prepared.folder.appendingPathComponent("N\(index).txt"), originalMissing: false,
                recoveryNoteID: NoteID(), sourceNoteID: prepared.note.id)
        }
        owner.project(notices)
        XCTAssertEqual(host.persistCount, 1)
        owner.project(Array(notices.prefix(1)))
        XCTAssertEqual(host.persistCount, 2)
    }

    func testPruneDropsNoticesWhoseNotesAreGone() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        host.folderState.apply(.changed(prepared.note))
        let owner = RecoveryController(host: host)
        let live = RecoveryNotice(originalURL: prepared.note.fileURL, recoveryURL: prepared.folder.appendingPathComponent("A.txt"),
            originalMissing: false, recoveryNoteID: NoteID(), sourceNoteID: prepared.note.id)
        let stale = RecoveryNotice(originalURL: prepared.folder.appendingPathComponent("Gone.txt"),
            recoveryURL: prepared.folder.appendingPathComponent("B.txt"), originalMissing: false,
            recoveryNoteID: NoteID(), sourceNoteID: NoteID())
        owner.recoveryNotices = [live.recoveryURL: live, stale.recoveryURL: stale]
        owner.pruneNotices()
        XCTAssertEqual(Array(owner.recoveryNotices.values), [live])
    }

    func testFooterShowsOneMessagePerNoteAndRevealsItsCard() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        let owner = RecoveryController(host: host)
        let source = NoteID()
        let original = prepared.folder.appendingPathComponent("Original.txt")
        for name in ["A.txt", "B.txt"] {
            let notice = RecoveryNotice(originalURL: original, recoveryURL: prepared.folder.appendingPathComponent(name),
                originalMissing: false, recoveryNoteID: prepared.note.id, sourceNoteID: source)
            owner.recoveryNotices[notice.recoveryURL] = notice
        }
        let stack = NSStackView()
        owner.render(in: stack, height: nil)
        XCTAssertFalse(stack.arrangedSubviews.contains { $0 is NSButton })
        let messages = stack.arrangedSubviews.compactMap { $0 as? FooterMessage }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.toolTip, original.path)
        messages.first?.press()
        XCTAssertEqual(host.revealed, [source])
    }

    func testFinishedRecoveryShowsNoProblemOnCardOrFooter() async throws {
        let prepared = try await makeRecoveryNote()
        let host = TestRecoveryHost(store: prepared.store)
        host.folderState.apply(.changed(prepared.note))
        let owner = RecoveryController(host: host)
        let notice = RecoveryNotice(originalURL: prepared.folder.appendingPathComponent("Original.txt"),
            recoveryURL: prepared.folder.appendingPathComponent("R.txt"), originalMissing: true,
            recoveryNoteID: NoteID(), sourceNoteID: prepared.note.id)
        owner.recoveryNotices[notice.recoveryURL] = notice
        XCTAssertNil(owner.cardIssue(for: prepared.note.id), "The local text is already its own note")
        let stack = NSStackView()
        owner.render(in: stack, height: nil)
        XCTAssertTrue(stack.arrangedSubviews.isEmpty, "A listed note's recovery is not a footer message")
    }

    func testFooterMessageWithLongFileNameWrapsInsteadOfWideningTheWindow() async throws {
        let prepared = try await makeRecoveryNote()
        let owner = RecoveryController(host: TestRecoveryHost(store: prepared.store))
        let original = prepared.folder.appendingPathComponent(
            "recovery-source-with-a-deliberately-long-filename-for-layout-checks-and-no-spaces-at-all.txt")
        let notice = RecoveryNotice(originalURL: original, recoveryURL: prepared.folder.appendingPathComponent("R.txt"),
            originalMissing: false, recoveryNoteID: prepared.note.id, sourceNoteID: NoteID())
        owner.recoveryNotices[notice.recoveryURL] = notice
        let list = ListWindowController()
        defer { list.window?.orderOut(nil) }
        list.present(focusing: nil, refresh: {})
        let window = try XCTUnwrap(list.window)
        list.render(owner)
        var frame = window.frame
        frame.size.width = window.minSize.width
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, window.minSize.width, accuracy: 0.5, "The footer message must not widen the window")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let message = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? FooterMessage }.first)
        let oneLine = message.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 16
        XCTAssertGreaterThan(message.frame.height, oneLine * 1.5, "The long file name should wrap onto more lines")
    }

}

private func recoveryRecord(_ prepared: RecoveryPreparedNote) -> RecoveryRecord {
    RecoveryRecord(id: UUID(), noteID: prepared.note.id, collectionToken: prepared.collectionToken,
        originalURL: prepared.note.fileURL, baseRevision: prepared.note.fileRevision,
        editRevision: EditRevision(rawValue: 1), text: "preserved text", createdAt: Date(), reason: .saveFailure)
}

private actor SuspendedRecoveryExport: RecoveryTextExporting {
    func exportRecoveryText(_ data: Data, to url: URL) async throws { try await write(data, to: url) }
    private var gate: CheckedContinuation<Void, Never>?
    func write(_ data: Data, to url: URL) async throws {
        await withCheckedContinuation { gate = $0 }
        try data.write(to: url)
    }
    func waitUntilStarted() async { while gate == nil { await Task.yield() } }
    func release() { gate?.resume(); gate = nil }
}

private actor RecoveryExportSequence: RecoveryTextExporting {
    func exportRecoveryText(_ data: Data, to url: URL) async throws { try next() }
    private(set) var completedCount = 0

    func next() throws {
        completedCount += 1
        if completedCount == 1 || completedCount == 2 || completedCount == 4 {
            throw NoteOperationError.inputOutput("A01 disposable export failure")
        }
    }
}
