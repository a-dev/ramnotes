import ramnotesDomain
import AppKit
import XCTest
@testable import ramnotes

@MainActor
final class EditorTests: XCTestCase {
    func testRelinkReplacesLiveDirtySessionWithoutReplayingDraft() async throws {
        for targetText in ["original", "different target"] {
            let prepared = try await makeEditorNote()
            let editor = NoteEditorController(note: prepared.note, store: prepared.store)
            let lifecycle = LifecycleController()
            await lifecycle.observe(prepared.store) { event in
                switch event {
                case let .changed(note): editor.applyExternal(note)
                case let .rebound(note): editor.applyRebinding(note)
                default: break
                }
            }
            try FileManager.default.removeItem(at: prepared.note.fileURL)
            editor.textView.string = "retained draft"
            editor.capture()
            try await editor.prepareForTrackingRemoval()
            let oldRevision = editor.state.currentRevision
            let target = prepared.fixture.root.appendingPathComponent("target.txt")
            try Data(targetText.utf8).write(to: target)
            let linked = try await editor.relink(file: try await prepared.store.acquireFile(target))
            for _ in 0..<1000 where editor.note.locationRevision != linked.locationRevision { await Task.yield() }
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), targetText)
            XCTAssertEqual(editor.textView.string, targetText)
            XCTAssertFalse(editor.state.hasUnsavedEdits)
            XCTAssertGreaterThanOrEqual(editor.state.currentRevision, oldRevision)
            XCTAssertFalse(editor.applyExternal(prepared.note))
            let stale = EditSnapshot(id: prepared.note.id, collectionToken: prepared.note.collectionToken,
                revision: oldRevision, baseRevision: prepared.note.fileRevision,
                text: "retained draft", locationRevision: prepared.note.locationRevision)
            guard case .failed(.staleLocation) = await prepared.store.save(stale) else {
                return XCTFail("A delayed old-binding edit reached the new resource")
            }
            let reopenedEditor = NoteEditorController(note: linked, store: prepared.store, restoredEdit: stale)
            XCTAssertEqual(reopenedEditor.textView.string, targetText)
            XCTAssertFalse(reopenedEditor.state.hasUnsavedEdits)
            XCTAssertFalse(editor.applyRebinding(linked), "Duplicate events must not reset a session")
            let retained = await prepared.store.retainedRecovery()
            XCTAssertTrue(retained.edits.contains { $0.text == "retained draft" })
            lifecycle.stopObservation()
            let restarted = try NoteStore(support: prepared.fixture.root)
            let restored = try await restarted.openSelectedFolder()
            XCTAssertEqual(restored.notes.first { $0.id == linked.id }?.text, targetText)
            let recovery = await restarted.retainedRecovery()
            XCTAssertTrue(recovery.edits.contains { $0.text == "retained draft" })
            editor.textView.string = "intentional new edit"
            editor.capture()
            try await editor.flush()
            XCTAssertGreaterThan(editor.state.currentRevision, oldRevision)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "intentional new edit")
        }
    }

    func testLocationMoveFinishesMarkedTextBeforeFlushing() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.setMarkedText("composed", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: 0, length: 8))
        XCTAssertTrue(editor.textView.hasMarkedText())
        let target = prepared.folder.appendingPathComponent("Composed.txt")
        let result = try await editor.move(to: target)
        guard case .moved = result.outcome else { return XCTFail("Move failed") }
        XCTAssertFalse(editor.textView.hasMarkedText())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), editor.textView.string)
        XCTAssertEqual(editor.note.id, prepared.note.id)
    }

    func testExplicitMoveFlushesDirtyEditorAndRetainsSelectionUndoAndRevision() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.insertText(" changed", replacementRange: NSRange(location: editor.textView.string.utf16.count, length: 0))
        editor.capture()
        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        let target = prepared.folder.appendingPathComponent("Renamed editor.txt")
        let result = try await editor.move(to: target)
        guard case .moved = result.outcome else { return XCTFail("Move failed: \(result.outcome)") }
        XCTAssertEqual(editor.note.id, prepared.note.id)
        XCTAssertEqual(editor.note.collectionToken, prepared.note.collectionToken)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertEqual(editor.textView.string, "original changed")
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        XCTAssertTrue(editor.textView.isEditable)
        editor.textView.undoManager?.undo()
        editor.capture()
        try await editor.flush()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
    }

    func testOnlyVerifiedFileSaveClearsDirtyRevision() async throws {
        let prepared = try await makeEditorNote(text: "original")
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.string = "draft"
        editor.capture()
        let revision = editor.state.currentRevision

        editor.receive(.pending(revision))
        XCTAssertTrue(editor.state.hasUnsavedEdits)
        editor.receive(.failed(revision, .unavailable, journaled: true))
        XCTAssertTrue(editor.state.hasUnsavedEdits, "A journal is not a save of the represented file")
        editor.receive(.recoverable(revision, prepared.fixture.root.appendingPathComponent("recovery.txt")))
        XCTAssertTrue(editor.state.hasUnsavedEdits)
        editor.receive(.saved(revision))
        XCTAssertFalse(editor.state.hasUnsavedEdits)
    }

    func testLocationChangeRequeuesLatestBufferAndRejectsDelayedSnapshot() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.string = "latest local buffer"
        editor.capture()
        let moved = prepared.note.fileURL.deletingLastPathComponent().appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: prepared.note.fileURL, to: moved)
        try await prepared.store.reconcile(collectionToken: prepared.collectionToken)
        let records = await prepared.store.records
        let updated = try XCTUnwrap(records[prepared.note.id])
        editor.applyExternal(updated)
        XCTAssertEqual(editor.note.fileURL, moved)
        XCTAssertEqual(editor.textView.string, "latest local buffer")
        XCTAssertFalse(editor.applyExternal(prepared.note))
        XCTAssertEqual(editor.note.fileURL, moved)
        try await editor.flush()
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "latest local buffer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.note.fileURL.path))
    }

    func testAvailabilityChangesDuringSuspendedFlushAndCancellationReleasesLock() async throws {
        let prepared = try await makeEditorNote()
        var resume: CheckedContinuation<Void, Never>?
        let editor = NoteEditorController(note: prepared.note, store: prepared.store, flushNote: {
            await withCheckedContinuation { resume = $0 }
        })
        let task = Task { try await editor.flush() }
        while resume == nil { await Task.yield() }
        XCTAssertFalse(editor.textView.isEditable)
        let unavailable = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            fileURL: prepared.note.fileURL, fileRevision: prepared.note.fileRevision,
            text: "", availability: .missingOriginal)
        editor.applyExternal(unavailable)
        task.cancel()
        resume?.resume()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertEqual(editor.textView.string, prepared.note.text)
        editor.applyExternal(prepared.note)
        XCTAssertTrue(editor.textView.isEditable)
    }

    func testReturningNoteClearsUnavailableWarning() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        var statuses: [StorageSaveStatus] = []
        editor.statusChanged = { statuses.append($0) }
        let placeholder = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            fileURL: prepared.note.fileURL, fileRevision: prepared.note.fileRevision, text: "",
            availability: .unavailable(reason: "placeholder"), accessFailure: NoteAccessFailure(reason: .cloudPlaceholder, domain: NSCocoaErrorDomain, code: 0, message: "iCloud download requested"))
        editor.applyExternal(placeholder)
        guard case .failed = statuses.last else { return XCTFail("Expected the unavailable warning") }
        XCTAssertEqual(editor.textView.string, prepared.note.text)
        XCTAssertTrue(editor.applyExternal(prepared.note))
        guard case .saved = statuses.last else { return XCTFail("Expected the warning to clear") }
    }

    func testRapidTypingCoalescesToLatestEditAndKeepsWritingOrder() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        // The main actor never yields here, so the drain cannot run between keystrokes.
        for index in 1...50 {
            editor.textView.string = "draft \(index)"
            editor.capture()
        }
        XCTAssertEqual(editor.queuedDeliveryCount, 1, "Keystrokes must not queue one store call each.")
        editor.textViewWritingToolsWillBegin(editor.textView)
        editor.textView.string = "after tools"
        editor.capture()
        XCTAssertEqual(editor.queuedDeliveryCount, 3, "Edits never coalesce across a writing-state change.")

        try await editor.flush()
        XCTAssertEqual(editor.queuedDeliveryCount, 0)
        XCTAssertFalse(editor.state.hasUnsavedEdits)
        XCTAssertEqual(try String(contentsOf: prepared.note.fileURL, encoding: .utf8), "after tools")
    }

    func testOverlappingLocksRespectRestoredAvailabilityAndFailedFlush() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store,
            flushNote: { throw NoteOperationError.unavailable })
        let first = editor.beginEditingLock()
        let second = editor.beginEditingLock()
        let unavailable = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            fileURL: prepared.note.fileURL, fileRevision: prepared.note.fileRevision,
            text: "", availability: .missingOriginal)
        editor.applyExternal(unavailable)
        editor.endEditingLock(first)
        editor.applyExternal(prepared.note)
        XCTAssertFalse(editor.textView.isEditable)
        editor.endEditingLock(second)
        XCTAssertTrue(editor.textView.isEditable)
        editor.applyExternal(unavailable)
        do { try await editor.flush(); XCTFail("Expected failure") } catch { }
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertEqual(editor.textView.string, prepared.note.text)
    }

    func testUnavailableDirtyBufferRemainsEditableWithoutReplacingText() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.string = "local text"
        editor.capture()
        let unavailable = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            fileURL: prepared.note.fileURL, fileRevision: prepared.note.fileRevision,
            text: "", availability: .missingOriginal)
        editor.applyExternal(unavailable)
        let lock = editor.beginEditingLock()
        XCTAssertFalse(editor.textView.isEditable)
        editor.endEditingLock(lock)
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertEqual(editor.textView.string, "local text")
        try await editor.flush()
    }

    func testNativeFindBarOpensAndEscapeKeepsTheNoteOpen() async throws {
        let prepared = try await makeEditorNote(text: "first match, second match")
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(editor.textView))
        var escaped = false
        editor.textView.escape = { escaped = true }
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue

        editor.textView.performTextFinderAction(action)

        XCTAssertTrue(editor.textView.usesFindBar)
        XCTAssertTrue(editor.textView.isIncrementalSearchingEnabled)
        XCTAssertTrue(editor.scrollView.isFindBarVisible)
        XCTAssertEqual(editor.scrollView.findBarPosition, .aboveContent)
        editor.textView.cancelOperation(nil)
        XCTAssertFalse(editor.scrollView.isFindBarVisible)
        XCTAssertFalse(escaped)
        XCTAssertEqual(editor.textView.string, prepared.note.text)
        editor.textView.cancelOperation(nil)
        XCTAssertTrue(escaped)
    }

    func testUndoRedoActionsReachTheFocusedEditorsHistory() async throws {
        let prepared = try await makeEditorNote(text: "abc")
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(editor.textView))
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("X", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()

        XCTAssertTrue(view.tryToPerform(Selector(("undo:")), with: nil))
        XCTAssertEqual(view.string, "abc")
        XCTAssertTrue(view.tryToPerform(Selector(("redo:")), with: nil))
        XCTAssertEqual(view.string, "abcX")
        try await editor.flush()
    }

    func testEditFlushAndReopenPreservesExactUTF8Bytes() async throws {
        let prepared = try await makeEditorNote()
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        let editedText = "Café ☕️\nSecond line\n終わり"

        controller.textView.string = editedText
        controller.capture()
        try await controller.flush()

        let expected = Data(editedText.utf8)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), expected)

        let reopenedStore = try NoteStore(support: prepared.fixture.root, clock: prepared.fixture.clock)
        let reopened = try await reopenedStore.discover(in: prepared.folder, collectionToken: prepared.collectionToken)
        XCTAssertEqual(try XCTUnwrap(reopened.first { $0.fileURL == prepared.note.fileURL }).text, editedText)
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), expected)
    }

    func testExternalReloadClampsSelectionAndDirtyEditorKeepsLocalText() async throws {
        let prepared = try await makeEditorNote(text: "0123456789")
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        controller.textView.setSelectedRange(NSRange(location: 8, length: 5))
        let shorter = snapshot(prepared.note, text: "abcde")

        XCTAssertTrue(controller.applyExternal(shorter))
        XCTAssertEqual(controller.textView.string, "abcde")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 5, length: 0))

        controller.textView.string = "local dirty draft"
        controller.capture()
        let newerExternal = snapshot(prepared.note, text: "remote update")

        XCTAssertFalse(controller.applyExternal(newerExternal))
        XCTAssertEqual(controller.textView.string, "local dirty draft")
        XCTAssertEqual(controller.note.text, "abcde")
        try await controller.flush()
    }

    func testExternalTimestampOnlyChangeResetsPositionAndRemovesEditorResponder() async throws {
        let prepared = try await makeEditorNote(text: "same text")
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))

        let original = try XCTUnwrap(prepared.note.fileRevision)
        let changedTimestamp = original.modifiedAt.addingTimeInterval(-30)
        let external = NoteSnapshot(id: prepared.note.id, collectionToken: prepared.collectionToken,
            fileURL: prepared.note.fileURL,
            fileRevision: FileRevision(fingerprint: original.fingerprint, modifiedAt: changedTimestamp),
            text: prepared.note.text, availability: .available, fileObservation: .disk)

        XCTAssertTrue(editor.applyExternal(external))
        XCTAssertEqual(editor.textView.string, prepared.note.text)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(window.firstResponder === editor.textView)
        window.makeFirstResponder(editor.textView)
        XCTAssertFalse(window.firstResponder === editor.textView)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        window.sendEvent(key)
        XCTAssertEqual(editor.textView.string, prepared.note.text)
        XCTAssertFalse(editor.textView.undoManager?.canUndo ?? false)

        // The same external timestamp is a duplicate observation. It must not erase a
        // position established by a later explicit click.
        editor.textView.preventAutomaticFocus = false // models a direct user activation
        window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(editor.applyExternal(external))
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
        window.orderOut(nil)
    }

    func testRestorePositionClampsUTF16SelectionsAndDoesNotStealFocusWhenInactive() async throws {
        let prepared = try await makeEditorNote(text: "A😀BC")
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        let otherResponder = NSButton(title: "Other", target: nil, action: nil)
        window.contentView?.addSubview(otherResponder)
        window.makeFirstResponder(otherResponder)

        let position = EditorPosition(selections: [.init(location: 3, length: 50)],
            scrollX: 0, scrollY: 120, hasActiveCaret: false, fileModifiedAt: prepared.note.fileRevision?.modifiedAt)
        editor.restorePosition(position)

        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 3, length: 2),
                       "Selection offsets use UTF-16 units, including the emoji's surrogate pair")
        XCTAssertFalse(window.firstResponder === editor.textView)
        window.orderOut(nil)
    }

    func testRestorePositionRevealsADeepSelectionAfterApplyingSavedViewport() async throws {
        let text = (0..<300).map { "Paragraph \($0)" }.joined(separator: "\n")
        let prepared = try await makeEditorNote(text: text)
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let end = (text as NSString).length
        let position = EditorPosition(selections: [.init(location: end, length: 0)],
            scrollX: 0, scrollY: 0, hasActiveCaret: true, fileModifiedAt: prepared.note.fileRevision?.modifiedAt)

        editor.restorePosition(position)

        XCTAssertGreaterThan(editor.scrollView.contentView.bounds.origin.y, 0)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: end, length: 0))
        XCTAssertTrue(window.firstResponder === editor.textView)
        window.orderOut(nil)
    }

    func testExternalResetAllowsExplicitMouseActivationAndTyping() async throws {
        let prepared = try await makeEditorNote(text: "external text")
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        defer { window.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { NSApp.keyWindow === window }
        window.contentView?.layoutSubtreeIfNeeded()
        editor.restorePosition(EditorPosition(selections: [.init(location: 0, length: 0)],
            scrollX: 0, scrollY: 0, hasActiveCaret: false, fileModifiedAt: prepared.note.fileRevision?.modifiedAt))
        XCTAssertFalse(window.firstResponder === editor.textView)
        let point = editor.textView.convert(NSPoint(x: 30, y: 15), to: nil)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(content.hitTest(content.convert(point, from: nil)) === editor.textView)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)

        window.sendEvent(down)

        XCTAssertTrue(window.firstResponder === editor.textView)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        window.sendEvent(key)
        XCTAssertEqual((editor.textView.string as NSString).length, (prepared.note.text as NSString).length + 1)
    }

    func testRestorePositionPreservesSavedViewportWhenSelectionIsAlreadyVisible() async throws {
        let text = (0..<300).map { "Paragraph \($0) 😀" }.joined(separator: "\n")
        let prepared = try await makeEditorNote(text: text)
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(editor.textView.textContainer)
        editor.textView.layoutManager?.ensureLayout(for: container)
        let selection = (text as NSString).range(of: "Paragraph 190")
        editor.textView.setSelectedRange(selection)
        editor.textView.scrollRangeToVisible(selection)
        let clip = editor.scrollView.contentView
        let savedY = clip.bounds.origin.y + 20
        clip.scroll(to: NSPoint(x: 0, y: savedY))
        let saved = editor.editorPosition
        XCTAssertGreaterThan(saved.scrollY, 0)
        clip.scroll(to: .zero)

        editor.restorePosition(saved)

        XCTAssertEqual(clip.bounds.origin.y, saved.scrollY, accuracy: 0.5,
            "Restoration must use the saved viewport when revealing the selection needs no extra scroll")
        XCTAssertEqual(editor.textView.selectedRange(), selection)
    }

    func testExternalReloadRejectsDifferentNoteOrCollectionToken() async throws {
        let prepared = try await makeEditorNote(text: "current")
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        let wrongID = NoteSnapshot(
            id: NoteID(), collectionToken: prepared.collectionToken, fileURL: prepared.note.fileURL,
            fileRevision: prepared.note.fileRevision, text: "wrong note", availability: .available
        )
        let wrongGeneration = NoteSnapshot(
            id: prepared.note.id, collectionToken: CollectionToken(), fileURL: prepared.note.fileURL,
            fileRevision: prepared.note.fileRevision, text: "stale folder", availability: .available
        )

        XCTAssertFalse(controller.applyExternal(wrongID))
        XCTAssertFalse(controller.applyExternal(wrongGeneration))
        XCTAssertEqual(controller.textView.string, "current")
    }

    func testEditorUsesPlainTextSettingsAndSupportsUndo() async throws {
        let prepared = try await makeEditorNote(text: "abc")
        var settings = AppSettings()
        settings.fontFamily = "System"
        settings.fontWeight = "Bold"
        settings.fontSize = 17
        settings.lineHeight = 29
        let controller = NoteEditorController(note: prepared.note, store: prepared.store, settings: settings)
        let view = controller.textView

        XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.importsGraphics)
        XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
        XCTAssertEqual(view.font?.pointSize, 17)
        XCTAssertEqual(view.defaultParagraphStyle?.minimumLineHeight, 29)
        XCTAssertEqual(view.typingAttributes[.font] as? NSFont, view.font)

        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText("X", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "aXbc")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "abc")
        view.undoManager?.redo()
        XCTAssertEqual(view.string, "aXbc")
    }

    func testReadingRTFPasteboardIntoPlainTextViewDropsRichFormatting() throws {
        let view = PlainTextView()
        view.isRichText = false
        view.font = .systemFont(ofSize: 20)
        let formatted = NSAttributedString(
            string: "formatted text",
            attributes: [.font: NSFont.systemFont(ofSize: 42, weight: .bold)]
        )
        let rtf = try formatted.data(from: NSRange(location: 0, length: formatted.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ramnotes-editor-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(rtf, forType: .rtf))

        XCTAssertTrue(view.readSelection(from: pasteboard, type: .rtf))
        XCTAssertEqual(view.string, "formatted text")
        let pastedFont = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(pastedFont.pointSize, view.font?.pointSize)
        XCTAssertFalse(pastedFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testAutosavePreservesCRLFConventionWithoutClearingTextUndo() async throws {
        let prepared = try await makeEditorNote(text: "first\r\n")
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        let view = controller.textView
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("second\n", replacementRange: view.selectedRange())
        controller.capture()
        try await controller.flush()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("first\r\nsecond\r\n".utf8))
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "first\r\n")
    }

    func testRevertingToOriginalImmediatelyAfterSaveIsStillAnEdit() async throws {
        let prepared = try await makeEditorNote(text: "original")
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        controller.textView.string = "draft"
        controller.capture()
        try await controller.flush()
        controller.textView.string = "original"
        controller.capture()
        try await controller.flush()
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("original".utf8))
    }

    func testMarkedTextBlocksReloadAndCloseUntilCompositionEnds() async throws {
        let prepared = try await makeEditorNote(text: "original")
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        controller.textView.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0), replacementRange: NSRange(location: 0, length: 8))
        controller.capture()
        XCTAssertTrue(controller.textView.hasMarkedText())
        XCTAssertFalse(controller.applyExternal(snapshot(prepared.note, text: "external")))
        do { try await controller.flush(); XCTFail("Composition must block close") } catch { }
        controller.textView.unmarkText()
        try await controller.flush()
        XCTAssertEqual(try Data(contentsOf: prepared.note.fileURL), Data("composition".utf8))
    }

    func testWritingToolsSessionWithoutEditsReleasesCloseBarrier() async throws {
        let prepared = try await makeEditorNote()
        let controller = NoteEditorController(note: prepared.note, store: prepared.store)
        controller.textViewWritingToolsWillBegin(controller.textView)
        controller.textViewWritingToolsDidEnd(controller.textView)
        try await controller.flush()
        let disposable = await prepared.store.canDispose(prepared.note.id)
        XCTAssertTrue(disposable)
    }

    func testCommandHoverStylesOnlyTheLinkAndClearsOnReleaseOrExit() throws {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.isRichText = false
        view.font = .systemFont(ofSize: 14)
        view.string = "See https://example.com now"
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let range = (view.string as NSString).range(of: "https://example.com")
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.location + 2, length: 1), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)

        view.updateLinkHover(at: point, modifiers: .command)
        for index in range.location..<NSMaxRange(range) {
            XCTAssertNotNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(manager.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        }
        XCTAssertNil(manager.temporaryAttribute(.underlineStyle, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertNil(view.textStorage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil))
        XCTAssertFalse(view.undoManager?.canUndo == true)

        view.updateLinkHover(at: point, modifiers: [])
        XCTAssertNil(manager.temporaryAttribute(.underlineStyle, atCharacterIndex: range.location, effectiveRange: nil))
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        view.updateLinkHover(at: point, modifiers: .command)
        view.updateLinkHover(at: NSPoint(x: 590, y: 190), modifiers: .command)
        XCTAssertNil(manager.temporaryAttribute(.underlineStyle, atCharacterIndex: range.location, effectiveRange: nil))
        XCTAssertEqual(view.string, "See https://example.com now")
    }

    func testOpenLinkSelectionEligibilityAndDispatch() throws {
        let view = PlainTextView()
        view.string = "😀 See https://example.com/path then https://example.org end"
        let first = (view.string as NSString).range(of: "https://example.com/path")
        let second = (view.string as NSString).range(of: "https://example.org")
        var opened: [URL] = []
        view.openURL = { opened.append($0) }
        let item = NSMenuItem(title: "Open Link", action: #selector(PlainTextView.openLink(_:)), keyEquivalent: "")
        for range in [NSRange(location: first.location, length: 0),
                      NSRange(location: first.location + 8, length: 3), first,
                      NSRange(location: first.location - 1, length: first.length + 2)] {
            view.setSelectedRange(range)
            XCTAssertTrue(view.validateUserInterfaceItem(item))
            view.openLink(nil)
        }
        XCTAssertEqual(opened.map(\.host), Array(repeating: "example.com", count: 4))
        for range in [NSRange(location: 0, length: 0),
                      NSRange(location: NSMaxRange(first), length: 0),
                      NSRange(location: first.location - 1, length: 5),
                      NSRange(location: first.location, length: NSMaxRange(second) - first.location)] {
            view.setSelectedRange(range)
            XCTAssertFalse(view.validateUserInterfaceItem(item))
            view.openLink(nil)
        }
        XCTAssertEqual(opened.count, 4)
        view.selectedRanges = [NSValue(range: first), NSValue(range: second)]
        XCTAssertNil(view.selectedLinkURL)
        view.setMarkedText("composing", selectedRange: NSRange(location: 0, length: 0), replacementRange: first)
        XCTAssertNil(view.selectedLinkURL)
    }

    func testLinkAccessibilityActionsDispatchAndRejectStaleTargets() throws {
        let view = PlainTextView()
        view.isRichText = false
        view.string = "https://example.com and https://example.org"
        var opened: [URL] = []
        view.openURL = { opened.append($0) }
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        let action = try XCTUnwrap(actions.first { $0.name == "Open Link: https://example.com" })
        let typing = view.typingAttributes
        let selection = view.selectedRange()
        XCTAssertTrue(try XCTUnwrap(action.handler)())
        XCTAssertEqual(opened.first?.host, "example.com")
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(NSDictionary(dictionary: view.typingAttributes).isEqual(to: typing))
        XCTAssertNil(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertFalse(view.undoManager?.canUndo == true)
        view.string = "https://example.net"
        XCTAssertFalse(try XCTUnwrap(action.handler)())
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.openLink(nil)
        XCTAssertEqual(opened.last?.host, "example.net")
        XCTAssertEqual(opened.count, 2)
    }

    func testLinkDetectionFindsURLAtCharacterIndex() {
        let text = "See https://example.com/path?q=1 and then stop."
        let location = (text as NSString).range(of: "example").location

        XCTAssertEqual(PlainTextView.detectedURL(in: text, at: location)?.absoluteString,
                       "https://example.com/path?q=1")
        XCTAssertNil(PlainTextView.detectedURL(in: text, at: 0))
    }

    func testCachedLinksFollowExternalReloadsNativeEditsAndUndo() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        let window = try XCTUnwrap(controller.window)
        let view = editor.textView
        XCTAssertTrue(window.makeFirstResponder(view))
        view.string = "https://example.com"
        XCTAssertEqual(view.detectedURL(at: 4)?.host, "example.com")
        XCTAssertEqual(view.detectedURL(at: 8)?.host, "example.com")

        view.string = "https://example.org"
        XCTAssertEqual(view.detectedURL(at: 4)?.host, "example.org")
        view.insertText("plain text", replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        view.breakUndoCoalescing()
        XCTAssertNil(view.detectedURL(at: 4))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "https://example.org")
        XCTAssertEqual(view.detectedURL(at: 4)?.host, "example.org")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        var opened: URL?
        view.openURL = { opened = $0 }
        view.openLink(nil)
        XCTAssertEqual(opened?.host, "example.org")
        try await editor.flush()
    }
}

private struct EditorPreparedNote {
    let fixture: TestFixture
    let store: NoteStore
    let folder: URL
    let collectionToken: CollectionToken
    let note: NoteSnapshot
}

private func makeEditorNote(text: String = "original") async throws -> EditorPreparedNote {
    let fixture = try TestFixture()
    let store = try NoteStore(support: fixture.root, clock: fixture.clock)
    let folder = await store.defaultFolder()
    let url = folder.appendingPathComponent("Editor note.txt")
    try Data(text.utf8).write(to: url)
    let collectionToken = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: collectionToken)
    return EditorPreparedNote(fixture: fixture, store: store, folder: folder, collectionToken: collectionToken,
                              note: try XCTUnwrap(notes.first))
}

private func snapshot(_ note: NoteSnapshot, text: String) -> NoteSnapshot {
    NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
                 fileRevision: note.fileRevision, text: text, availability: .available)
}

extension EditorTests {
    func testFolderRepairCapturesLiveTextAndKeepsSelectionAndUndo() async throws {
        let prepared = try await makeEditorNote()
        let editor = NoteEditorController(note: prepared.note, store: prepared.store)
        editor.textView.insertText(" local", replacementRange: NSRange(location: editor.textView.string.utf16.count, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 2, length: 2))
        let file = try await prepared.store.acquireFile(prepared.note.fileURL)
        let repaired = try await editor.renewFileAccess(file: file, expected: prepared.note)
        XCTAssertEqual(repaired.id, prepared.note.id)
        XCTAssertEqual(editor.textView.string, "original local")
        XCTAssertEqual(try String(contentsOf: repaired.fileURL, encoding: .utf8), "original local")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 2))
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        XCTAssertTrue(editor.textView.isEditable)
    }
}
