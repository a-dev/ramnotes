import ramnotesDomain
import AppKit
import XCTest
@testable import ramnotes

@MainActor
final class WindowTests: XCTestCase {
    func testLockedNoteShowsOnlyApplicableRecoveryButtonsAndNoMenu() async throws {
        let prepared = try await makeRecoveryNote(failDestination: true)
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.note, store: prepared.store))
        defer { controller.close() }
        controller.editor.textView.string = "draft"
        controller.editor.capture()
        do { try await controller.editor.flush(); XCTFail("The save must fail") } catch {}
        let statusValue = await prepared.store.status(prepared.note.id)
        controller.display(try XCTUnwrap(statusValue))
        func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) } }
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(views(content, NSPopUpButton.self).filter { $0.pullsDown }.isEmpty, "Recovery actions are buttons, not a menu")
        let shown = controller.recoveryActionButtons.filter { !$0.value.isHidden }.keys.sorted()
        XCTAssertEqual(shown, ["Close Without Saving…", "Export", "Save a Copy…"], "A locked file is present: Locate File and Restore File Access do not apply")
    }

    func testFolderStateChangesOnlyThroughApplyAndReplace() {
        let token = CollectionToken()
        func note(_ name: String, _ text: String) -> NoteSnapshot {
            NoteSnapshot(id: NoteID(), collectionToken: token, fileURL: URL(fileURLWithPath: "/tmp/\(name).txt"),
                fileRevision: nil, text: text, availability: .available)
        }
        let first = note("a", "one"), second = note("b", "two")
        let state = FolderState()
        state.replace(with: [first.id: first])
        state.apply(.discovered(second))
        XCTAssertEqual(Set(state.notes.keys), [first.id, second.id])
        let edited = note("c", "changed")
        state.apply(.changed(edited))
        XCTAssertEqual(state.notes[edited.id]?.text, "changed")
        state.apply(.failed(first.id, .inputOutput("x")))
        state.apply(.removed(first.id, token))
        XCTAssertNil(state.notes[first.id])
        XCTAssertNotNil(state.notes[second.id])
        state.replace(with: [:])
        XCTAssertTrue(state.notes.isEmpty)
    }

    func testTrashObservationClosesWindowAndClearsOpenState() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let shared = FolderState()
        let coordinator = WindowCoordinator(store: prepared.store, folderState: shared)
        let original = prepared.notes[0]
        coordinator.open(original, focus: false)
        let window = try XCTUnwrap(coordinator.windows[original.id]?.window)
        let note = NoteSnapshot(id: original.id, collectionToken: original.collectionToken,
            fileURL: original.fileURL, fileRevision: original.fileRevision, text: "", availability: .trashed)
        shared.apply(.changed(note))
        coordinator.acceptFileObservation(note)
        XCTAssertNil(coordinator.windows[note.id])
        XCTAssertEqual(shared.notes[note.id]?.availability, .trashed)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.isOpen, false)
        XCTAssertFalse(window.isVisible)
        coordinator.open(note, focus: false)
        XCTAssertNil(coordinator.windows[note.id])
        shared.apply(.changed(original))
        coordinator.acceptFileObservation(original)
        XCTAssertEqual(shared.notes[note.id]?.availability, .available)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.isOpen, false)
        coordinator.open(original, focus: false)
        XCTAssertNotNil(coordinator.windows[note.id])
        // AppCoordinator removes collection membership only for storage's removal event.
        shared.apply(.removed(note.id, CollectionToken()))
        coordinator.remove(note.id)
        XCTAssertNil(shared.notes[note.id])
        XCTAssertNil(coordinator.windows[note.id])
        XCTAssertNil(coordinator.metadata.notes[note.id])
    }

    func testExternalTrashPreservesQueuedAndComposingLatestBufferBeforeClosing() async throws {
        for composing in [false, true] {
            let prepared = try await makeWindowNotes(count: 1)
            let coordinator = WindowCoordinator(store: prepared.store)
            let original = prepared.notes[0]
            coordinator.open(original, focus: false)
            let editor = try XCTUnwrap(coordinator.windows[original.id]?.editor)
            if composing {
                editor.textView.setMarkedText("latest composition", selectedRange: NSRange(location: 18, length: 0),
                    replacementRange: NSRange(location: 0, length: 8))
            } else {
                editor.textView.string = "latest queued text"
                editor.capture()
            }
            let latest = editor.textView.string
            let trashed = NoteSnapshot(id: original.id, collectionToken: original.collectionToken,
                fileURL: original.fileURL, fileRevision: original.fileRevision, text: "", availability: .trashed)
            // No suspension: the newest delivery has not reached the storage actor.
            coordinator.folderState.apply(.changed(trashed))
            coordinator.acceptFileObservation(trashed)
            XCTAssertNotNil(coordinator.windows[original.id], "Disposal must wait for durable acknowledgement")
            for _ in 0..<1000 where coordinator.windows[original.id] != nil { await Task.yield() }
            XCTAssertNil(coordinator.windows[original.id])
            XCTAssertEqual(coordinator.notes[original.id]?.availability, .trashed)
            XCTAssertEqual(coordinator.metadata.notes[original.id]?.isOpen, false)
            let retained = await prepared.store.retainedRecovery()
            XCTAssertTrue(retained.edits.contains { $0.text == latest })
        }
    }

    func testExternalTrashRetentionFailureKeepsLiveEditor() async throws {
        let prepared = try await makeWindowNotes(failJournal: true, count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        let note = prepared.notes[0]
        coordinator.open(note, focus: false)
        let editor = try XCTUnwrap(coordinator.windows[note.id]?.editor)
        editor.textView.string = "only live copy"
        editor.capture()
        let trashed = NoteSnapshot(id: note.id, collectionToken: note.collectionToken,
            fileURL: note.fileURL, fileRevision: note.fileRevision, text: "", availability: .trashed)
        coordinator.folderState.apply(.changed(trashed))
        coordinator.acceptFileObservation(trashed)
        for _ in 0..<1000 where coordinator.closing.contains(note.id) { await Task.yield() }
        XCTAssertFalse(coordinator.closing.contains(note.id))
        XCTAssertTrue(coordinator.windows[note.id]?.editor === editor)
        XCTAssertEqual(editor.textView.string, "only live copy")
        coordinator.reset()
    }

    func testTrafficLightsStayCenteredWhileTypingAndSaving() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.notes[0], store: prepared.store))
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        func assertCentered(_ stage: String) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(kind))
                let frame = controller.header.convert(button.bounds, from: button)
                XCTAssertEqual(frame.midY, controller.header.bounds.midY, accuracy: 0.5, "\(kind) after \(stage)")
            }
        }

        try assertCentered("opening")
        window.orderOut(nil)
        window.orderFront(nil)
        try assertCentered("revealing without focus")
        window.setContentSize(NSSize(width: 410, height: 300))
        try assertCentered("resizing")
        for text in ["a", "s", "f"] {
            controller.editor.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try assertCentered("typing \(text)")
            try await controller.editor.flush()
            try assertCentered("saving \(text)")
        }
    }

    func testExternalFooterDismissesOnlyVerifiedSaveOfSubsequentTextEdit() async throws {
        let prepared = try await makeRecoveryNote()
        let coordinator = WindowCoordinator(store: prepared.store)
        var note = prepared.note
        note.fileObservation = .disk
        coordinator.acceptFileObservation(note)
        coordinator.open(note, focus: false)
        defer { coordinator.perform(.hide) }
        let controller = try XCTUnwrap(coordinator.windows[note.id])
        let stamp = try XCTUnwrap(note.fileRevision).modifiedAt.addingTimeInterval(30)
        func external(_ date: Date) -> NoteSnapshot {
            NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
                fileRevision: FileRevision(fingerprint: "external", modifiedAt: date), text: note.text,
                availability: .available, fileObservation: .disk)
        }
        coordinator.acceptFileObservation(external(stamp))
        XCTAssertTrue(controller.externalChangeFooter.stringValue.hasPrefix("Changed outside • "))
        XCTAssertTrue(controller.externalChangeFooter.toolTip?.contains("Changed outside RAMnotes") == true)
        XCTAssertEqual(controller.externalChangeFooter.accessibilityValue(), controller.externalChangeFooter.toolTip)
        XCTAssertNil(controller.externalChangeFooter.accessibilityLabel(), "VoiceOver reads the footer once, not the short text and then the full one")
        XCTAssertFalse(controller.externalChangeFooter.acceptsFirstResponder)
        controller.window?.setContentSize(NSSize(width: 375, height: 260))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(controller.externalChangeFooter.frame.width, try XCTUnwrap(controller.window?.contentView).bounds.width - 24)
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.editor.capture()
        note.fileObservation = .ownWrite
        coordinator.acceptFileObservation(note)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt, stamp)
        controller.editor.textView.string += " local"
        controller.editor.capture()
        let revision = controller.editor.state.currentRevision
        controller.display(.failed(revision, .permissionDenied, journaled: false))
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt, stamp)
        let newer = stamp.addingTimeInterval(30)
        coordinator.acceptFileObservation(external(newer))
        var saved = note
        saved.editRevision = revision
        coordinator.acceptFileObservation(saved)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt, newer)
        controller.editor.textView.string += " newer edit"
        controller.editor.capture()
        saved.editRevision = controller.editor.state.currentRevision
        coordinator.acceptFileObservation(saved)
        XCTAssertNil(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt)
        XCTAssertTrue(controller.externalChangeFooter.superview?.isHidden == true)
        try await controller.editor.flush()
    }

    func testExternalFooterSurvivesMetadataReloadAndRejectsOldOrWrongLocationSave() async throws {
        let prepared = try await makeRecoveryNote()
        let id = prepared.note.id
        let stamp = Date(timeIntervalSince1970: 1_793_370_900)
        var metadata = CollectionMetadata()
        metadata.notes[id] = NoteWindowMetadata(isOpen: true)
        metadata.notes[id]?.externalChangeNoticeAt = stamp
        metadata.notes[id]?.acceptedFileModifiedAt = prepared.note.fileRevision?.modifiedAt
        let coordinator = WindowCoordinator(store: prepared.store)
        coordinator.metadata = try JSONDecoder().decode(CollectionMetadata.self, from: JSONEncoder().encode(metadata))
        coordinator.open(prepared.note, focus: false)
        defer { coordinator.perform(.hide) }
        let controller = try XCTUnwrap(coordinator.windows[id])
        XCTAssertFalse(controller.externalChangeFooter.superview?.isHidden ?? true)
        coordinator.perform(.hide)
        coordinator.open(prepared.note, focus: false)
        XCTAssertFalse(controller.externalChangeFooter.superview?.isHidden ?? true)
        controller.editor.textView.string += " edit"
        controller.editor.capture()
        var saved = prepared.note
        saved.fileObservation = .ownWrite
        coordinator.acceptFileObservation(saved)
        XCTAssertEqual(coordinator.metadata.notes[id]?.externalChangeNoticeAt, stamp)
        saved.editRevision = controller.editor.state.currentRevision
        saved.locationRevision = LocationRevision(rawValue: saved.locationRevision.rawValue + 1)
        coordinator.acceptFileObservation(saved)
        XCTAssertEqual(coordinator.metadata.notes[id]?.externalChangeNoticeAt, stamp)
        saved.locationRevision = prepared.note.locationRevision
        coordinator.acceptFileObservation(saved)
        XCTAssertNil(coordinator.metadata.notes[id]?.externalChangeNoticeAt)
        try await controller.editor.flush()
    }

    func testExternalFooterUsesLocalDayAndRefreshesAfterMidnightAndTimeZoneChange() {
        let date = Date(timeIntervalSince1970: 1_793_370_900) // 30 October 2026, 14:35 UTC
        let utc = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_GB")
        let today = NoteWindowController.externalChangeText(timestamp: date, now: date, locale: locale, timeZone: utc)
        XCTAssertEqual(today.label, "Changed outside • 14:35")
        let tomorrow = NoteWindowController.externalChangeText(timestamp: date, now: date.addingTimeInterval(86400), locale: locale, timeZone: utc)
        XCTAssertEqual(tomorrow.label, "Changed outside • 30 Oct 2026 at 14:35")
        let shifted = NoteWindowController.externalChangeText(timestamp: date, now: date, locale: locale,
            timeZone: TimeZone(secondsFromGMT: 14400)!)
        XCTAssertEqual(shifted.label, "Changed outside • 18:35")
        XCTAssertTrue(today.description.contains("2026"))
    }

    func testExternalFooterFollowsLocaleHourCycleAndDateOrder() {
        let date = Date(timeIntervalSince1970: 1_793_370_900) // 30 October 2026, 14:35 UTC
        let utc = TimeZone(secondsFromGMT: 0)!
        func label(_ id: String, earlierDay: Bool = false) -> String {
            NoteWindowController.externalChangeText(timestamp: date, now: earlierDay ? date.addingTimeInterval(86400) : date,
                                                    locale: Locale(identifier: id), timeZone: utc).label
        }
        XCTAssertTrue(label("en_US").contains("2:35"), label("en_US"))
        XCTAssertFalse(label("en_US").contains("14"), label("en_US"))
        XCTAssertTrue(label("de_DE").hasSuffix("14:35"), label("de_DE"))
        XCTAssertTrue(label("de_DE", earlierDay: true).contains("2026"), label("de_DE", earlierDay: true))
        XCTAssertTrue(label("de_DE", earlierDay: true).contains("Okt"), label("de_DE", earlierDay: true))
        let japanese = label("ja_JP", earlierDay: true)
        XCTAssertTrue(japanese.contains("2026") && japanese.contains("14:35"), japanese)
        XCTAssertLessThan(japanese.range(of: "2026")!.lowerBound, japanese.range(of: "14:35")!.lowerBound, japanese)
        let arabic = label("ar", earlierDay: true)
        XCTAssertTrue(arabic.contains("2026") || arabic.contains("٢٠٢٦"), arabic)
        XCTAssertNotEqual(arabic, label("en_GB", earlierDay: true))
    }

    func testExternalFooterFormatsEveryShippedLocale() throws {
        // The process language sets the caption. The supplied locale formats the date.
        // Check both halves per locale: the date part here, the caption through the locale's own bundle.
        let date = Date(timeIntervalSince1970: 1_793_370_900) // 30 October 2026, 14:35 UTC
        let utc = TimeZone(secondsFromGMT: 0)!
        for (id, language) in [("es", "es"), ("pt_BR", "pt"), ("de", "de"), ("fr", "fr"), ("ar", "ar"), ("ja", "ja"), ("zh_Hans", "zh-Hans")] {
            let locale = Locale(identifier: id)
            let today = NoteWindowController.externalChangeText(timestamp: date, now: date, locale: locale, timeZone: utc)
            let earlier = NoteWindowController.externalChangeText(timestamp: date, now: date.addingTimeInterval(86400), locale: locale, timeZone: utc)
            XCTAssertNotEqual(today.label, earlier.label, id)
            XCTAssertFalse(earlier.description.isEmpty, id)
            let path = try XCTUnwrap(Bundle(for: NoteWindowController.self).path(forResource: language, ofType: "lproj"), language)
            let caption = try XCTUnwrap(Bundle(path: path)).localizedString(forKey: "Changed outside • %@", value: "\u{1}missing", table: nil)
            XCTAssertNotEqual(caption, "\u{1}missing", language)
            XCTAssertTrue(caption.contains("•") && caption.contains("%@"), "\(language): \(caption)")
            XCTAssertNotEqual(caption, "Changed outside • %@", language)
        }
        let french = NoteWindowController.externalChangeText(timestamp: date, now: date, locale: Locale(identifier: "fr_FR"), timeZone: utc)
        XCTAssertTrue(french.label.hasSuffix("14:35"), french.label)
    }

    func testExternalFooterRefreshesOnCalendarTimeZoneAndLocaleNotifications() async throws {
        let prepared = try await makeRecoveryNote()
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.note, store: prepared.store))
        let timestamp = Date().addingTimeInterval(-86400)
        controller.setExternalChangeNotice(timestamp)
        let expected = NoteWindowController.externalChangeText(timestamp: timestamp)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                     NSLocale.currentLocaleDidChangeNotification, NSApplication.didBecomeActiveNotification] {
            controller.externalChangeFooter.stringValue = "stale format"
            NotificationCenter.default.post(name: name, object: nil)
            XCTAssertEqual(controller.externalChangeFooter.stringValue, expected.label, name.rawValue)
            XCTAssertEqual(controller.externalChangeFooter.accessibilityValue(), expected.description)
        }
    }

    /// The system posts the day change on a background queue at midnight.
    func testExternalFooterRefreshesWhenDayChangeArrivesOffMainThread() async throws {
        let prepared = try await makeRecoveryNote()
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.note, store: prepared.store))
        let timestamp = Date().addingTimeInterval(-86400)
        controller.setExternalChangeNotice(timestamp)
        controller.externalChangeFooter.stringValue = "stale format"
        await Task.detached { NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil) }.value
        for _ in 0..<50 where controller.externalChangeFooter.stringValue == "stale format" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.externalChangeFooter.stringValue, NoteWindowController.externalChangeText(timestamp: timestamp).label)
    }

    func testClosedNoteObservationsEstablishBaselineResetOnceAndPreserveNoticeOnOwnSave() async throws {
        let prepared = try await makeRecoveryNote()
        let coordinator = WindowCoordinator(store: prepared.store)
        var note = prepared.note
        note.fileObservation = .disk
        coordinator.acceptFileObservation(note)
        XCTAssertNil(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt)
        let original = try XCTUnwrap(note.fileRevision)
        let timestamp = original.modifiedAt.addingTimeInterval(-60)
        note = NoteSnapshot(id: note.id, collectionToken: note.collectionToken, fileURL: note.fileURL,
            fileRevision: FileRevision(fingerprint: original.fingerprint, modifiedAt: timestamp), text: note.text,
            availability: .available, fileObservation: .disk)
        coordinator.acceptFileObservation(note)
        XCTAssertTrue(coordinator.windows.isEmpty)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt, timestamp)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.editorPosition?.hasActiveCaret, false)
        let clicked = EditorPosition(selections: [.init(location: 1, length: 0)], scrollX: 0, scrollY: 10,
            hasActiveCaret: true, fileModifiedAt: timestamp)
        coordinator.metadata.notes[note.id]?.editorPosition = clicked
        coordinator.acceptFileObservation(note)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.editorPosition, clicked)
        note.fileObservation = nil
        coordinator.acceptFileObservation(note)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.editorPosition, clicked)
        note.fileObservation = .ownWrite
        coordinator.acceptFileObservation(note)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.externalChangeNoticeAt, timestamp)
    }

    func testBatchOpenFromReturnAndMenuPresentsEverySelectedNote() async throws {
        for useMenu in [false, true] {
            let gate = ReadGate()
            let prepared = try await makeWindowNotes(count: 3, readBody: gate.read)
            let coordinator = WindowCoordinator(store: prepared.store)
            defer { coordinator.perform(.hide); gate.release() }
            coordinator.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
            let list = NoteListController()
            list.update(prepared.notes)
            try await waitUntil { list.lastAppliedQueryGeneration == list.queryCount }
            list.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
            let selected = list.selectedNotes
            var requests: [Task<Void, Never>] = []
            list.testDelegate.onOpenBatch = { notes in requests.append(Task { await coordinator.openBatchVerified(notes) }) }
            let delayed = selected[0].fileURL
            try Data("changed before presentation".utf8).write(to: delayed)
            gate.stall(delayed)
            if useMenu {
                let menu = try XCTUnwrap(list.menu(forRow: 0))
                let item = try XCTUnwrap(menu.item(withTitle: "Open 3 Notes"))
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            } else {
                XCTAssertTrue(list.control(list.search, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.insertNewline(_:))))
            }
            try await waitUntil { gate.isStalled }
            gate.release()
            for request in requests { await request.value }
            XCTAssertFalse(gate.timedOut)
            XCTAssertEqual(Set(coordinator.windows.keys), Set(selected.map(\.id)))
            XCTAssertEqual(coordinator.requestedFocus, selected.last?.id)
            XCTAssertTrue(selected.allSatisfy { coordinator.metadata.notes[$0.id]?.isOpen == true })
        }
    }

    func testPendingBatchOpenIsCancelledByHideAndNewerOpen() async throws {
        for newerOpen in [false, true] {
            let gate = ReadGate()
            let prepared = try await makeWindowNotes(count: 3, readBody: gate.read)
            let coordinator = WindowCoordinator(store: prepared.store)
            defer { coordinator.perform(.hide); gate.release() }
            coordinator.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
            let selected = Array(prepared.notes.prefix(2))
            let latest = prepared.notes[2]
            try Data("changed before presentation".utf8).write(to: selected[0].fileURL)
            gate.stall(selected[0].fileURL)
            let batch = Task { await coordinator.openBatchVerified(selected) }
            try await waitUntil { gate.isStalled }
            var navigation: Task<Void, Never>?
            if newerOpen {
                var started = false
                navigation = Task {
                    started = true
                    await coordinator.openVerified(latest)
                }
                try await waitUntil { started }
            } else {
                coordinator.perform(.hide)
            }
            gate.release()
            await batch.value
            await navigation?.value
            XCTAssertFalse(gate.timedOut)
            XCTAssertEqual(Set(coordinator.windows.keys), newerOpen ? Set([latest.id]) : [])
            XCTAssertEqual(coordinator.requestedFocus, newerOpen ? latest.id : nil)
            XCTAssertTrue(selected.allSatisfy { coordinator.metadata.notes[$0.id]?.isOpen != true })
        }
    }

    func testVerifiedOpenReadsDiskBeforeCreatingWindow() async throws {
        let prepared = try await makeRecoveryNote()
        let coordinator = WindowCoordinator(store: prepared.store)
        coordinator.folderState.apply(.changed(prepared.note))
        try Data("fresh disk".utf8).write(to: prepared.note.fileURL)
        await coordinator.openVerified(prepared.note, focus: false)
        defer { coordinator.perform(.hide) }
        XCTAssertEqual(coordinator.windows[prepared.note.id]?.editor.textView.string, "fresh disk")
    }

    func testVerifiedOpenRestoresPositionAndExplicitlyOpenedNoteTakesFocus() async throws {
        let prepared = try await makeWindowNotes(count: 2)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let first = prepared.notes[0]
        let second = prepared.notes[1]
        coordinator.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
        for (note, caret) in [(first, 3), (second, 5)] {
            coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
            coordinator.metadata.notes[note.id]?.acceptedFileModifiedAt = note.fileRevision?.modifiedAt
            coordinator.metadata.notes[note.id]?.editorPosition = EditorPosition(
                selections: [.init(location: caret, length: 0)], scrollX: 0, scrollY: 0,
                hasActiveCaret: false, fileModifiedAt: note.fileRevision?.modifiedAt)
        }

        await coordinator.openVerified(first, focus: false)
        let firstEditor = try XCTUnwrap(coordinator.windows[first.id]?.editor)
        XCTAssertEqual(firstEditor.textView.selectedRange().location, 3)
        XCTAssertTrue(firstEditor.textView.preventAutomaticFocus)

        await coordinator.openVerified(second, focus: true)
        XCTAssertEqual(coordinator.requestedFocus, second.id)
        XCTAssertEqual(coordinator.windows[second.id]?.editor.textView.selectedRange().location, 5)
        XCTAssertTrue(coordinator.windows[second.id]?.editor.textView.preventAutomaticFocus ?? false)
    }

    func testHideAndRevealPreserveLivePositionsAndRestoreMostRecentFocus() async throws {
        let prepared = try await makeWindowNotes(count: 2)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let older = prepared.notes[0]
        let mostRecent = prepared.notes[1]
        for (note, order, caret) in [(older, UInt64(2), 2), (mostRecent, UInt64(9), 7)] {
            coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true, focusOrder: order)
            coordinator.open(note, focus: false)
            coordinator.windows[note.id]?.editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
        }

        coordinator.perform(.hide)
        coordinator.perform(.reveal)

        XCTAssertEqual(coordinator.windows[older.id]?.editor.textView.selectedRange().location, 2)
        XCTAssertEqual(coordinator.windows[mostRecent.id]?.editor.textView.selectedRange().location, 7)
        XCTAssertEqual(coordinator.requestedFocus, mostRecent.id)
    }

    func testStaleSavedPositionTimestampIsIgnoredOnVerifiedOpen() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let note = prepared.notes[0]
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.folderState.apply(.changed(note))
        coordinator.metadata.notes[note.id] = NoteWindowMetadata(isOpen: true)
        let stale = try XCTUnwrap(note.fileRevision?.modifiedAt).addingTimeInterval(-60)
        coordinator.metadata.notes[note.id]?.editorPosition = EditorPosition(
            selections: [.init(location: 6, length: 0)], scrollX: 0, scrollY: 0,
            hasActiveCaret: false, fileModifiedAt: stale)

        await coordinator.openVerified(note, focus: false)

        XCTAssertEqual(coordinator.windows[note.id]?.editor.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testRestartRestoresUTF16SelectionAndDeepViewportAfterResizeAndTextSizeChange() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let original = prepared.notes[0]
        let text = (0..<240).map { "Paragraph \($0) 😀 with enough text to wrap across a narrow window." }
            .joined(separator: "\n")
        let note = NoteSnapshot(id: original.id, collectionToken: original.collectionToken,
            fileURL: original.fileURL, fileRevision: original.fileRevision, text: text,
            availability: .available)
        let coordinator = WindowCoordinator(store: prepared.store)
        coordinator.folderState.apply(.changed(note))
        coordinator.open(note, focus: false)
        let firstController = try XCTUnwrap(coordinator.windows[note.id])
        let firstWindow = try XCTUnwrap(firstController.window)
        firstWindow.setContentSize(NSSize(width: 360, height: 260))
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        let editor = firstController.editor
        let marker = (text as NSString).range(of: "Paragraph 190 😀")
        let emoji = (text as NSString).range(of: "😀", range: marker)
        let selection = emoji
        editor.textView.setSelectedRange(selection)
        let container = try XCTUnwrap(editor.textView.textContainer)
        editor.textView.layoutManager?.ensureLayout(for: container)
        editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 900))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification,
            object: editor.scrollView.contentView)
        coordinator.captureAllGeometry()
        let savedPosition = try XCTUnwrap(coordinator.metadata.notes[note.id]?.editorPosition)
        XCTAssertEqual(savedPosition.selections, [.init(location: selection.location, length: selection.length)])
        XCTAssertGreaterThan(savedPosition.scrollY, 0)

        let encoded = try JSONEncoder().encode(coordinator.metadata)
        var reloadedMetadata = try JSONDecoder().decode(CollectionMetadata.self, from: encoded)
        reloadedMetadata.notes[note.id]?.frame = CGRect(x: 180, y: 180, width: 700, height: 520)
        coordinator.perform(.hide)
        let restarted = WindowCoordinator(store: prepared.store)
        restarted.folderState.apply(.changed(note))
        restarted.metadata = reloadedMetadata
        restarted.settings.fontSize = 26
        restarted.open(note, focus: false)
        defer { coordinator.perform(.hide); restarted.perform(.hide) }
        let restored = try XCTUnwrap(restarted.windows[note.id])
        let restoredContainer = try XCTUnwrap(restored.editor.textView.textContainer)
        let layout = try XCTUnwrap(restored.editor.textView.layoutManager)
        layout.ensureLayout(for: restoredContainer)

        XCTAssertEqual(restored.editor.textView.selectedRange(), selection)
        XCTAssertGreaterThan(restored.editor.scrollView.contentView.bounds.origin.y, 0)
        XCTAssertGreaterThan(restored.editor.textView.font?.pointSize ?? 0, 14)
        let glyphs = layout.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        let selectionRect = layout.boundingRect(forGlyphRange: glyphs, in: restoredContainer)
            .offsetBy(dx: restored.editor.textView.textContainerOrigin.x, dy: restored.editor.textView.textContainerOrigin.y)
        XCTAssertTrue(restored.editor.scrollView.contentView.documentVisibleRect.intersects(selectionRect))
    }

    func testSerializedFocusOrderSurvivesRestartIndependentlyOfLastEditedNote() async throws {
        let prepared = try await makeWindowNotes(count: 2)
        let first = prepared.notes[0]
        let editedLast = prepared.notes[1]
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(editedLast, focus: true)
        coordinator.open(first, focus: true)
        let focusOrder = try XCTUnwrap(coordinator.metadata.notes[first.id]?.focusOrder)
        let priorFocusOrder = try XCTUnwrap(coordinator.metadata.notes[editedLast.id]?.focusOrder)
        XCTAssertGreaterThan(focusOrder, priorFocusOrder)

        let editor = try XCTUnwrap(coordinator.windows[editedLast.id]?.editor)
        editor.textView.string = "last text edit belongs to this note"
        editor.capture()
        XCTAssertEqual(coordinator.metadata.notes[first.id]?.focusOrder, focusOrder)

        let reloaded = try JSONDecoder().decode(CollectionMetadata.self,
            from: JSONEncoder().encode(coordinator.metadata))
        let restarted = WindowCoordinator(store: prepared.store)
        restarted.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
        restarted.metadata = reloaded
        restarted.perform(.reveal)
        defer { restarted.perform(.hide) }

        XCTAssertEqual(restarted.requestedFocus, first.id)
        XCTAssertGreaterThan(try XCTUnwrap(restarted.metadata.notes[first.id]?.focusOrder),
            try XCTUnwrap(restarted.metadata.notes[editedLast.id]?.focusOrder))
        try await editor.flush()
    }

    func testAlwaysOnTopUpdatesExistingAndNewWindowsAndCanBeDisabled() async throws {
        let prepared = try await makeRecoveryNote()
        let secondNoteURL = prepared.folder.appendingPathComponent("Second note.txt")
        try Data("second".utf8).write(to: secondNoteURL)
        let notes = try await prepared.store.discover(in: prepared.folder, collectionToken: prepared.collectionToken)
        let secondNote = try XCTUnwrap(notes.first { $0.fileURL == secondNoteURL })
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(prepared.note, focus: false)
        let firstWindow = try XCTUnwrap(coordinator.windows[prepared.note.id]?.window)
        XCTAssertEqual(firstWindow.level, .normal)

        var settings = AppSettings()
        settings.alwaysOnTop = true
        coordinator.settings = settings
        XCTAssertEqual(firstWindow.level, .floating)

        coordinator.open(secondNote, focus: false)
        let secondWindow = try XCTUnwrap(coordinator.windows[secondNote.id]?.window)
        XCTAssertEqual(secondWindow.level, .floating)

        settings.alwaysOnTop = false
        coordinator.settings = settings
        XCTAssertEqual(firstWindow.level, .normal)
        XCTAssertEqual(secondWindow.level, .normal)
    }

    func testRightClickedCardIsRingedWhileItsMenuIsOpenAndSelectionStays() async throws {
        let prepared = try await makeWindowNotes(count: 2)
        let list = NoteListController()
        list.update(prepared.notes)
        try await waitUntil { list.table.numberOfRows == prepared.notes.count }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = list.table
        window.contentView = scroll
        list.table.frame.size.width = 420
        list.table.layoutSubtreeIfNeeded()
        list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let point = list.table.convert(NSPoint(x: 40, y: list.table.rect(ofRow: 1).midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(list.table.menu(for: event))
        let ringed = { (row: Int) in (list.table.rowView(atRow: row, makeIfNecessary: true) as? NoteListRow)?.isMenuTarget }
        list.table.willOpenMenu(menu, with: event)
        XCTAssertEqual(ringed(1), true)
        XCTAssertEqual(ringed(0), false)
        XCTAssertEqual(list.table.selectedRow, 0)
        list.table.didCloseMenu(menu, with: event)
        XCTAssertEqual(ringed(1), false)
        XCTAssertEqual(list.table.selectedRow, 0)
    }

    func testRowMenuCapturesClickedIdentityAndDisablesUnavailableActions() async throws {
        let prepared = try await makeWindowNotes(count: 2)
        let list = NoteListController()
        list.update(prepared.notes)
        try await waitUntil { list.table.numberOfRows == prepared.notes.count }
        list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = try XCTUnwrap(list.menu(forRow: 1))
        var opened: NoteID?
        var trashed: NoteID?
        list.testDelegate.onOpen = { opened = $0.id }
        list.testDelegate.onTrash = { trashed = $0.id }
        for index in [0, 3] {
            let item = menu.items[index]
            _ = item.target?.perform(item.action, with: item)
        }
        XCTAssertEqual(opened, trashed)
        XCTAssertNotNil(opened)
        XCTAssertEqual(list.table.selectedRow, 0)
        let selectedMenu = try XCTUnwrap(list.menu(forRow: 0))
        let item = selectedMenu.items[0]
        _ = item.target?.perform(item.action, with: item)
        XCTAssertNotEqual(opened, trashed)
        XCTAssertNil(list.menu(forRow: -1))
        let original = prepared.notes[0]
        var unavailable = NoteSnapshot(id: original.id, collectionToken: original.collectionToken,
            fileURL: original.fileURL, fileRevision: original.fileRevision, text: original.text,
            availability: .missingOriginal)
        unavailable.accessFailure = NoteAccessFailure(reason: .missingFile, domain: "test", code: 1, message: "Missing")
        list.update([unavailable])
        try await waitUntil { list.table.numberOfRows == 1 }
        let missing = try XCTUnwrap(list.menu(forRow: 0))
        for title in ["Open", "Show in Finder", "Move to Trash…"] {
            XCTAssertFalse(try XCTUnwrap(missing.items.first { $0.title == title }).isEnabled)
        }
        XCTAssertTrue(try XCTUnwrap(missing.items.first { $0.title == "Save a Copy…" }).isEnabled)
        XCTAssertEqual(missing.items.last?.title, "Remove from List")
        var located = false
        list.testDelegate.onLocate = { _ in located = true }
        let locate = try XCTUnwrap(missing.items.first { $0.title == "Locate File…" })
        _ = locate.target?.perform(locate.action, with: locate)
        XCTAssertTrue(located)
        list.testDelegate.onActionsAllowed = { false }
        located = false
        _ = locate.target?.perform(locate.action, with: locate)
        XCTAssertFalse(located)
    }

    func testMissingNoteMenuOffersRemovalWithoutLocating() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let original = prepared.notes[0]
        var missing = NoteSnapshot(id: original.id, collectionToken: original.collectionToken,
            fileURL: original.fileURL, fileRevision: original.fileRevision, text: original.text,
            availability: .missingOriginal)
        missing.accessFailure = NoteAccessFailure(reason: .missingFile, domain: "test", code: 1, message: "Missing")
        let list = NoteListController()
        list.update([missing])
        try await waitUntil { list.table.numberOfRows == 1 }
        var removed: NoteID?
        var located = false
        list.testDelegate.onRemoveUnavailable = { removed = $0.id }
        list.testDelegate.onLocate = { _ in located = true }
        let menu = try XCTUnwrap(list.menu(forRow: 0))
        let remove = try XCTUnwrap(menu.items.first { $0.title == "Remove from List" })
        XCTAssertTrue(remove.isEnabled)
        _ = remove.target?.perform(remove.action, with: remove)
        XCTAssertEqual(removed, missing.id)
        XCTAssertFalse(located)

        removed = nil
        list.testDelegate.onActionsAllowed = { false }
        _ = remove.target?.perform(remove.action, with: remove)
        XCTAssertNil(removed)
        let blockedMenu = try XCTUnwrap(list.menu(forRow: 0))
        XCTAssertFalse(try XCTUnwrap(blockedMenu.items.first { $0.title == "Remove from List" }).isEnabled)

        list.testDelegate.onActionsAllowed = { true }
        list.update([original])
        try await waitUntil { list.menu(forRow: 0)?.items.first?.isEnabled == true }
        _ = remove.target?.perform(remove.action, with: remove)
        XCTAssertNil(removed)
        XCTAssertFalse(try XCTUnwrap(list.menu(forRow: 0)).items.contains { $0.title == "Remove from List" })
    }

    func testCancelledTrashSheetDoesNotRequestDeletion() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        coordinator.open(note)
        let controller = try XCTUnwrap(coordinator.windows[note.id])
        let window = try XCTUnwrap(controller.window as? GroupWindow)
        var deleted = false
        controller.deleteRequested = { deleted = true }
        window.deleteRequested?()
        let sheet = try XCTUnwrap(window.attachedSheet)
        func labels(in view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        let confirmationLabels = labels(in: try XCTUnwrap(sheet.contentView))
        XCTAssertTrue(confirmationLabels.contains(note.fileURL.lastPathComponent))
        XCTAssertTrue(confirmationLabels.contains("The original file will be moved to Trash. You can restore it in Finder."))
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(deleted)
        XCTAssertEqual(controller.editor.note.id, note.id)
        XCTAssertNotNil(coordinator.windows[note.id])
    }

    func testNoProxyIconAndEditedStateFollowsSave() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let snapshot = try XCTUnwrap(prepared.notes.first)
        coordinator.open(snapshot)
        let controller = try XCTUnwrap(coordinator.windows[snapshot.id])
        let window = try XCTUnwrap(controller.window)
        XCTAssertNil(window.representedURL)
        XCTAssertFalse(window.isDocumentEdited)

        let unavailable = NoteSnapshot(id: snapshot.id, collectionToken: snapshot.collectionToken,
            fileURL: snapshot.fileURL, fileRevision: snapshot.fileRevision, text: snapshot.text,
            availability: .missingOriginal, editRevision: snapshot.editRevision,
            locationRevision: snapshot.locationRevision)
        XCTAssertFalse(controller.editor.applyExternal(unavailable))
        XCTAssertTrue(controller.editor.applyExternal(snapshot))
        XCTAssertNil(window.representedURL)

        controller.editor.textView.string = "pending"
        controller.editor.capture()
        XCTAssertTrue(window.isDocumentEdited)
        let revision = controller.editor.state.currentRevision
        controller.editor.receive(.failed(revision, .unavailable, journaled: true))
        XCTAssertTrue(window.isDocumentEdited)
        controller.editor.receive(.saved(revision))
        XCTAssertFalse(window.isDocumentEdited)

        let movedURL = snapshot.fileURL.deletingLastPathComponent().appendingPathComponent("Moved title.txt")
        let result = try await controller.editor.move(to: movedURL)
        guard case .moved = result.outcome else { return XCTFail("Move failed: \(result.outcome)") }
        XCTAssertNil(window.representedURL)
    }

    func testAppCommandsFollowActiveWindowAndSheet() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let app = AppCoordinator()
        let oldMenu = NSApp.mainMenu
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { NSApp.mainMenu = oldMenu; coordinator.perform(.hide) }
        app.installMenu()
        let appMenu = try XCTUnwrap(app.menu)
        let menu = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(menu.items.map(\.title), ["RAMnotes", "File", "Edit", "View", "Window", "Help"])
        let file = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let trash = try XCTUnwrap(file.item(withTitle: "Move to Trash…"))
        XCTAssertFalse(appMenu.validateMenuItem(trash))
        coordinator.open(prepared.notes[0])
        let note = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])
        NSApp.activate(ignoringOtherApps: true)
        note.window?.makeKeyAndOrderFront(nil)
        note.window?.makeKey()
        try await waitUntil { NSApp.keyWindow === note.window }
        XCTAssertTrue(NSApp.keyWindow === note.window)
        XCTAssertFalse(appMenu.validateMenuItem(trash), "A note window without an active storage context cannot delete")
        let view = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let increase = try XCTUnwrap(view.item(withTitle: "Increase Font Size"))
        let before = note.editor.fontSizeOverride ?? 14
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(increase.action), to: increase.target, from: increase))
        XCTAssertEqual(note.editor.fontSizeOverride, before + 1)
        let tint = try XCTUnwrap(view.item(withTitle: "Background Tint")?.submenu?.item(withTitle: "Blue"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(tint.action), to: tint.target, from: tint))
        XCTAssertTrue(appMenu.validateMenuItem(tint))
        XCTAssertEqual(tint.state, .on)
        XCTAssertEqual(note.editor.backgroundTone, .blue)
        let sheet = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        note.window?.beginSheet(sheet, completionHandler: { _ in })
        XCTAssertFalse(appMenu.validateMenuItem(trash))
        XCTAssertFalse(appMenu.validateMenuItem(increase))
        note.window?.endSheet(sheet)
        sheet.orderOut(nil)
        let settings = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        settings.makeKeyAndOrderFront(nil)
        defer { settings.orderOut(nil) }
        XCTAssertFalse(appMenu.validateMenuItem(trash))
        XCTAssertFalse(appMenu.validateMenuItem(increase))
        let new = try XCTUnwrap(file.item(withTitle: "New Note"))
        XCTAssertFalse(appMenu.validateMenuItem(new), "No active folder means creation cannot run")
    }

    func testRemovedNoteWithUnsavedEditsDropsWindowStateAndMoveDoesNotWriteItBack() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let shared = FolderState()
        let coordinator = WindowCoordinator(store: prepared.store, folderState: shared)
        let note = prepared.notes[0]
        shared.apply(.changed(note))
        coordinator.open(note, focus: false)
        defer { coordinator.windows[note.id]?.window?.orderOut(nil) }
        let controller = try XCTUnwrap(coordinator.windows[note.id])
        controller.editor.textView.string = "unsaved"
        controller.editor.capture()
        XCTAssertTrue(controller.editor.state.hasUnsavedEdits)
        var submissions = 0
        coordinator.changed = { submissions += 1 }

        // AppCoordinator's `.removed` handling.
        shared.apply(.removed(note.id, CollectionToken()))
        coordinator.noteRemoved(note.id)
        XCTAssertNotNil(coordinator.windows[note.id], "The window stays until recovery finishes")
        XCTAssertNil(coordinator.metadata.notes[note.id])
        XCTAssertEqual(submissions, 1, "Dropping the entry submits window state")

        let window = try XCTUnwrap(controller.window)
        window.setFrame(window.frame.offsetBy(dx: 40, dy: -40), display: false)
        coordinator.captureGeometry(note.id)
        coordinator.captureAllGeometry()
        XCTAssertNil(coordinator.metadata.notes[note.id], "A later move must not write the entry back")
    }

    func testHideAndCheckpointCapturePositionWithoutChangingFocusOrder() async throws {
        let prepared = try await makeWindowNotes(count: 2)
        let coordinator = WindowCoordinator(store: prepared.store)
        for note in prepared.notes { coordinator.open(note, focus: false) }
        defer { coordinator.perform(.hide) }
        let note = prepared.notes[0]
        let editor = try XCTUnwrap(coordinator.windows[note.id]?.editor)
        editor.textView.string = "a😀bcdef\n" + String(repeating: "line\n", count: 200)
        editor.textView.setSelectedRange(NSRange(location: 3, length: 2))
        coordinator.metadata.notes[note.id]?.focusOrder = 42
        coordinator.perform(.hide)
        let position = try XCTUnwrap(coordinator.metadata.notes[note.id]?.editorPosition)
        XCTAssertEqual(position.selections, [.init(location: 3, length: 2)])
        XCTAssertEqual(position.fileModifiedAt, note.fileRevision?.modifiedAt)
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.focusOrder, 42)
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        try await waitUntil {
            coordinator.metadata.notes[note.id]?.editorPosition?.selections == [.init(location: 5, length: 0)]
        }
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 30))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification,
            object: editor.scrollView.contentView)
        try await waitUntil { coordinator.metadata.notes[note.id]?.editorPosition?.scrollY == 30 }
        coordinator.captureAllGeometry()
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.editorPosition?.selections,
                       [.init(location: 5, length: 0)])
        XCTAssertEqual(coordinator.metadata.notes[note.id]?.focusOrder, 42)
    }

    func testGeometryAndFocusOnlyDeliverMetadata() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        let list = NoteListController()
        list.update(prepared.notes)
        try await waitUntil { list.table.numberOfRows == prepared.notes.count }
        coordinator.openStateChanged = { list.refreshTones() }
        var metadataWrites = 0
        var presentationChanges = 0
        coordinator.changed = { metadataWrites += 1 }
        coordinator.toneChanged = { presentationChanges += 1; list.refreshTones() }
        let note = prepared.notes[0]
        coordinator.open(note, focus: false)
        let initialQueries = list.queryCount
        let initialWrites = metadataWrites
        for _ in 0..<100 {
            coordinator.captureGeometry(note.id)
            coordinator.focusAdjacentNote(backward: false, from: coordinator.windows[note.id]?.window)
        }
        XCTAssertGreaterThanOrEqual(metadataWrites - initialWrites, 100)
        XCTAssertEqual(presentationChanges, 0)
        XCTAssertEqual(list.queryCount, initialQueries)
        XCTAssertNotNil(coordinator.metadata.notes[note.id]?.frame)
    }

    func testRevealRestoresOnlyActiveNotesAndFallsBackToList() async throws {
        let prepared = try await makeWindowNotes(count: 3)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.folderState.replace(with: Dictionary(uniqueKeysWithValues: prepared.notes.map { ($0.id, $0) }))
        var listRequests = 0
        coordinator.showList = { listRequests += 1 }
        coordinator.perform(.reveal)
        XCTAssertEqual(listRequests, 1)
        XCTAssertTrue(coordinator.windows.isEmpty)

        coordinator.metadata.notes[prepared.notes[0].id] = NoteWindowMetadata(isOpen: true)
        coordinator.metadata.notes[prepared.notes[1].id] = NoteWindowMetadata(isOpen: true)
        coordinator.metadata.notes[prepared.notes[1].id]?.focusOrder = 10
        coordinator.metadata.notes[prepared.notes[2].id] = NoteWindowMetadata(isOpen: false)
        coordinator.perform(.reveal)
        XCTAssertEqual(listRequests, 1)
        XCTAssertEqual(Set(coordinator.windows.keys), Set(prepared.notes.prefix(2).map(\.id)))
        XCTAssertEqual(coordinator.requestedFocus, prepared.notes[1].id)
        XCTAssertTrue(coordinator.windows.values.allSatisfy { $0.window?.isVisible == true })

        coordinator.perform(.hide)
        coordinator.perform(.reveal)
        XCTAssertEqual(listRequests, 1)
        XCTAssertTrue(coordinator.windows.values.allSatisfy { $0.window?.isVisible == true })
    }

    func testAdjacentNoteNavigationWrapsAndSkipsHiddenNotes() async throws {
        let prepared = try await makeWindowNotes(count: 3)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        for note in prepared.notes { coordinator.open(note, focus: false) }
        let ordered = coordinator.windows.values.compactMap(\.window).sorted { $0.windowNumber < $1.windowNumber }
        func focusedWindow() -> NSWindow? {
            coordinator.requestedFocus.flatMap { coordinator.windows[$0]?.window }
        }
        coordinator.focusAdjacentNote(backward: false, from: ordered[0])
        XCTAssertTrue(focusedWindow() === ordered[1])
        coordinator.focusAdjacentNote(backward: true, from: ordered[1])
        XCTAssertTrue(focusedWindow() === ordered[0])
        coordinator.focusAdjacentNote(backward: true, from: ordered[0])
        XCTAssertTrue(focusedWindow() === ordered[2])
        ordered[1].orderOut(nil)
        coordinator.focusAdjacentNote(backward: false, from: ordered[2])
        XCTAssertTrue(focusedWindow() === ordered[0])
        coordinator.focusAdjacentNote(backward: false, from: ordered[0])
        XCTAssertTrue(focusedWindow() === ordered[2])
    }

    func testBackgroundTonePaletteAtMinimumWindowWidthInBothAppearances() async throws {
        let prepared = try await makeWindowNotes()
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.notes[0], store: prepared.store))
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 375, height: 300))
        let root = try XCTUnwrap(window.contentView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for tone in [nil] + NoteBackgroundTone.allCases.map({ Optional($0) }) {
                controller.setBackgroundTone(tone)
                root.layoutSubtreeIfNeeded()
                XCTAssertFalse(controller.header.hasAmbiguousLayout)
                XCTAssertGreaterThanOrEqual(controller.backgroundTintButton.frame.width, 30)
                XCTAssertEqual(controller.editor.backgroundTone, tone)
            }
        }
    }

    func testBackgroundToneContrastMeasurements() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ]
        let tones: [NoteBackgroundTone?] = [nil] + NoteBackgroundTone.allCases.map(Optional.some)
        let foregrounds: [(String, NSColor)] = [
            ("label", .labelColor),
            ("text", .textColor),
            ("secondaryLabel", .secondaryLabelColor),
            ("controlAccent", .controlAccentColor),
            ("systemBlue", .systemBlue),
            ("systemRed", .systemRed)
        ]

        let legacyCard = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua { return .controlBackgroundColor }
            return NSColor(srgbRed: 249.0 / 255, green: 249.0 / 255, blue: 250.0 / 255, alpha: 1)
        }
        let legacySelectedCard = NSColor(name: nil) { appearance in
            var result = NSColor.controlBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                let base = legacyCard.usingColorSpace(.sRGB)!
                let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
                result = NSColor(srgbRed: base.redComponent * 0.9 + accent.redComponent * 0.1,
                                 green: base.greenComponent * 0.9 + accent.greenComponent * 0.1,
                                 blue: base.blueComponent * 0.9 + accent.blueComponent * 0.1,
                                 alpha: 1)
            }
            return result
        }
        let surfaces = tones.map { ($0?.rawValue ?? "none", NoteTonePalette.surface($0)) } + [
            ("listSurface", NSColor.controlBackgroundColor),
            ("legacyListCard", legacyCard),
            ("legacyListSelected10", legacySelectedCard)
        ]
        let measurements = surfaces.flatMap { surface in
            foregrounds.map { foreground in
                (surface.0, surface.1, foreground.0, foreground.1,
                 NoteTonePalette.readable(foreground.1, on: surface.1))
            }
        }

        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let accent = Self.sRGBComponents(NSColor.controlAccentColor)
                print("A06 \(name.rawValue) systemAccent RGB \(Self.rgbString(accent))")
                for (surfaceName, surfaceColor, label, color, readable) in measurements {
                    let background = Self.sRGBComponents(surfaceColor)
                    let before = Self.contrastRatio(Self.sRGBComponents(color), over: background)
                    let after = Self.contrastRatio(Self.sRGBComponents(readable), over: background)
                    let description = "\(surfaceName) / \(label)"
                    XCTAssertTrue(before.isFinite && before >= 1, "Invalid contrast measurement: \(description)")
                    XCTAssertGreaterThanOrEqual(after, 4.5, "Readable color missed 4.5:1 for \(name.rawValue), \(description)")
                    print("A06 \(name.rawValue) \(description): \(String(format: "%.2f", Double(before))) -> \(String(format: "%.2f", Double(after))); bg \(Self.rgbString(background)); fg \(Self.rgbString(Self.sRGBComponents(readable)))")
                }
            }
        }
    }

    private static func contrastRatio(_ foreground: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
                                      over background: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> CGFloat {
        func composite(_ foreground: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
                       over background: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
            let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
            guard alpha > 0 else { return (0, 0, 0) }
            return ((foreground.red * foreground.alpha + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
                    (foreground.green * foreground.alpha + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
                    (foreground.blue * foreground.alpha + background.blue * background.alpha * (1 - foreground.alpha)) / alpha)
        }
        func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
        }
        let fg = luminance(composite(foreground, over: background))
        let bg = luminance((background.red, background.green, background.blue))
        return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
    }

    private static func sRGBComponents(_ source: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let color = source.usingColorSpace(.sRGB)!
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    private static func rgbString(_ components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> String {
        String(format: "%.3f,%.3f,%.3f", Double(components.red), Double(components.green), Double(components.blue))
    }

    func testRecoveryToneInheritanceUsesIdentityAndRemainsIndependent() async throws {
        let prepared = try await makeWindowNotes()
        let coordinator = WindowCoordinator(store: prepared.store)
        let source = prepared.notes[0]
        coordinator.metadata.notes[source.id] = NoteWindowMetadata(isOpen: false, backgroundTone: .red)
        let recoveryID = NoteID()
        let notice = RecoveryNotice(originalURL: source.fileURL,
            recoveryURL: source.fileURL.deletingLastPathComponent().appendingPathComponent("Recovery.txt"),
            originalMissing: true, recoveryNoteID: recoveryID, sourceNoteID: source.id)
        coordinator.inheritRecoveryTone(notice)
        XCTAssertEqual(coordinator.metadata.notes[recoveryID]?.backgroundTone, .red)
        coordinator.metadata.notes[recoveryID]?.backgroundTone = .blue
        coordinator.inheritRecoveryTone(notice)
        XCTAssertEqual(coordinator.metadata.notes[recoveryID]?.backgroundTone, .blue)
        XCTAssertEqual(coordinator.metadata.notes[source.id]?.backgroundTone, .red)
        let unknown = RecoveryNotice(originalURL: URL(fileURLWithPath: "/unknown.txt"),
            recoveryURL: URL(fileURLWithPath: "/Recovery2.txt"), originalMissing: true,
            recoveryNoteID: NoteID(), sourceNoteID: NoteID())
        coordinator.inheritRecoveryTone(unknown)
        XCTAssertNil(coordinator.metadata.notes[unknown.recoveryNoteID]?.backgroundTone)
    }

    func testTintsPreserveContentAndRestoreIndependently() async throws {
        let prepared = try await makeWindowNotes()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        for note in prepared.notes { coordinator.open(note, focus: false) }
        let first = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])
        let second = try XCTUnwrap(coordinator.windows[prepared.notes[1].id])
        let editor = first.editor
        editor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        let selection = editor.textView.selectedRanges
        let revision = editor.state.currentRevision
        let text = editor.textView.string
        let undo = editor.textView.undoManager?.canUndo
        let origin = editor.scrollView.contentView.bounds.origin
        let modified = try prepared.notes[0].fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let menu = first.backgroundTintMenu
        XCTAssertEqual(menu.items.map(\.title), ["No color", "Gray", "Blue", "Green", "Yellow", "Red", "Purple"])
        for item in menu.items {
            XCTAssertNotNil(item.image)
            if #available(macOS 27.0, *) { XCTAssertEqual(item.preferredImageVisibility, .visible) }
        }
        menu.performActionForItem(at: 2)
        second.backgroundTintMenu.performActionForItem(at: 4)
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[0].id]?.backgroundTone, .blue)
        XCTAssertEqual(second.editor.backgroundTone, .yellow)
        XCTAssertEqual(menu.item(at: 2)?.state, .on)
        editor.adjustFontSize(by: 1)
        first.window?.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(editor.backgroundTone, .blue)
        XCTAssertEqual(editor.textView.selectedRanges, selection)
        XCTAssertEqual(editor.state.currentRevision, revision)
        XCTAssertEqual(editor.textView.string, text)
        XCTAssertEqual(editor.textView.undoManager?.canUndo, undo)
        XCTAssertEqual(editor.scrollView.contentView.bounds.origin, origin)
        XCTAssertEqual(try prepared.notes[0].fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        let store = MetadataStore(root: prepared.fixture.root.appendingPathComponent("ToneMetadata"))
        try await store.saveCollection(coordinator.metadata)
        let restored = WindowCoordinator(store: prepared.store)
        defer { restored.perform(.hide) }
        restored.metadata = await store.loadCollection().value
        restored.open(prepared.notes[0], focus: false)
        XCTAssertEqual(restored.windows[prepared.notes[0].id]?.editor.backgroundTone, .blue)
        menu.performActionForItem(at: 0)
        XCTAssertNil(editor.backgroundTone)
        XCTAssertNil(coordinator.metadata.notes[prepared.notes[0].id]?.backgroundTone)
        XCTAssertEqual(menu.item(at: 0)?.state, .on)
    }

    func testOpenReusesControllerPreservesOpenStateAndSeparatesWindowFrames() async throws {
        let prepared = try await makeWindowNotes()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.metadata.notes[prepared.notes[0].id] = NoteWindowMetadata(isOpen: true)

        coordinator.open(prepared.notes[0])
        let firstController = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])

        coordinator.open(prepared.notes[0])
        XCTAssertTrue(coordinator.windows[prepared.notes[0].id] === firstController)

        coordinator.open(prepared.notes[1], new: true)
        let secondController = try XCTUnwrap(coordinator.windows[prepared.notes[1].id])
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[1].id]?.isOpen, true)
        XCTAssertNotEqual(firstController.window?.frame, secondController.window?.frame,
                          "Open note windows should receive distinct frames")
    }

    func testExistingWindowMetadataLoadsWithoutFontOverride() throws {
        let legacy = Data(#"{"isOpen":true,"focusOrder":3}"#.utf8)
        let decoded = try JSONDecoder().decode(NoteWindowMetadata.self, from: legacy)
        XCTAssertTrue(decoded.isOpen)
        XCTAssertEqual(decoded.focusOrder, 3)
        XCTAssertNil(decoded.fontSize)
    }

    func testFontSizeIsIndependentPersistsAndResetsToCurrentDefault() async throws {
        let prepared = try await makeWindowNotes()
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        for note in prepared.notes { coordinator.open(note, focus: false) }
        let first = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])
        let second = try XCTUnwrap(coordinator.windows[prepared.notes[1].id])
        let selection = NSRange(location: 1, length: 2)
        first.editor.textView.setSelectedRange(selection)
        let revision = first.editor.state.currentRevision
        first.editor.adjustFontSize(by: 1)
        XCTAssertEqual(first.editor.textView.font?.pointSize, 15)
        XCTAssertEqual(second.editor.textView.font?.pointSize, 14)
        XCTAssertEqual(first.editor.textView.selectedRange(), selection)
        XCTAssertEqual(first.editor.state.currentRevision, revision)
        XCTAssertEqual(first.editor.textView.string, "original")

        let metadata = MetadataStore(root: prepared.fixture.root.appendingPathComponent("Metadata"))
        try await metadata.saveCollection(coordinator.metadata)
        let loaded = await metadata.loadCollection()
        XCTAssertNil(loaded.diagnostic)
        let restored = WindowCoordinator(store: prepared.store)
        defer { restored.perform(.hide) }
        restored.metadata = loaded.value
        restored.open(prepared.notes[0], focus: false)
        XCTAssertEqual(restored.windows[prepared.notes[0].id]?.editor.textView.font?.pointSize, 15)

        coordinator.settings.fontSize = 20
        XCTAssertEqual(first.editor.textView.font?.pointSize, 15)
        XCTAssertEqual(second.editor.textView.font?.pointSize, 20)
        first.editor.setFontSize(nil)
        XCTAssertEqual(first.editor.textView.font?.pointSize, 20)
        XCTAssertNil(coordinator.metadata.notes[prepared.notes[0].id]?.fontSize)
        first.editor.setFontSize(192)
        first.editor.adjustFontSize(by: 1)
        XCTAssertEqual(first.editor.textView.font?.pointSize, 192)
        first.editor.setFontSize(8)
        first.editor.adjustFontSize(by: -1)
        XCTAssertEqual(first.editor.textView.font?.pointSize, 8)
    }

    func testFontShortcutsWorkInNoteWindow() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let editor = NoteEditorController(note: prepared.notes[0], store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        let window = try XCTUnwrap(controller.window)
        for (key, modifiers, expected) in [("=", NSEvent.ModifierFlags.command, 15.0),
                                            ("+", [.command, .shift], 16.0),
                                            ("-", .command, 15.0), ("0", .command, 14.0)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(editor.textView.font?.pointSize, CGFloat(expected))
        }
    }

    func testClosingCleanNoteIsIndependentOfAnotherFailedSave() async throws {
        let prepared = try await makeWindowNotes(failDestination: true)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.open(prepared.notes[0], new: true, focus: false)
        coordinator.open(prepared.notes[1], new: true, focus: false)
        let dirty = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])
        let clean = try XCTUnwrap(coordinator.windows[prepared.notes[1].id])
        dirty.editor.textView.string = "draft that cannot save"
        dirty.editor.capture()
        do { try await dirty.editor.flush(); XCTFail("Injected save failure must block this note") } catch { }
        coordinator.closeNote(prepared.notes[1].id)
        try await waitUntil { clean.window?.isVisible == false }
        XCTAssertEqual(clean.window?.isVisible, false)
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[1].id]?.isOpen, false)
        XCTAssertEqual(dirty.editor.textView.string, "draft that cannot save")
        let dirtyCanDispose = await prepared.store.canDispose(prepared.notes[0].id)
        XCTAssertFalse(dirtyCanDispose)
    }

    func testCompactToolbarExposesDirectNoteActions() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let editor = NoteEditorController(note: prepared.notes[0], store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        let window = try XCTUnwrap(controller.window)
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(window.minSize.width, 375)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.header.frame.height, 41)
        let actions = controller.headerButtons
        XCTAssertEqual(actions.compactMap { $0.accessibilityLabel() },
                       ["Note list", "New Note", "Move to Trash"])
        XCTAssertEqual(actions.compactMap(\.action).map(NSStringFromSelector),
                       ["list", "newNote", "deleteNote"])
        for button in actions {
            XCTAssertTrue(button.isBordered)
            XCTAssertNotNil(button.image)
            XCTAssertTrue(button.target === controller)
            XCTAssertNotNil(button.toolTip)
            XCTAssertEqual(button.frame.height, 29)
            XCTAssertEqual(button.convert(button.bounds, to: controller.header).minY, 6)
        }
        XCTAssertEqual(actions.first?.toolTip, "Note list")
        XCTAssertEqual(controller.headerGlassViews.count, 1)
        XCTAssertEqual(controller.headerGlassViews.first?.style, .regular)
        for glass in controller.headerGlassViews {
            XCTAssertTrue(glass.effectIsInteractive)
            XCTAssertEqual(glass.frame.height, 29)
        }
        XCTAssertEqual(controller.fontSizeButtons.count, 2)
        XCTAssertEqual(controller.fontSizeControl.spacing, 0)
        XCTAssertEqual(controller.fontSizeControl.frame.height, 29)
        XCTAssertEqual(controller.fontSizeControl.convert(controller.fontSizeControl.bounds, to: controller.header).minY, 6)
        for button in controller.fontSizeButtons {
            XCTAssertTrue(button.isBordered)
            XCTAssertEqual(button.frame.size, NSSize(width: 30, height: 29))
            XCTAssertEqual(button.contentTintColor, .labelColor)
        }
        let originalSize = editor.textView.font!.pointSize
        controller.fontSizeButtons[1].performClick(nil)
        XCTAssertEqual(editor.textView.font!.pointSize, originalSize + 1)
        controller.fontSizeButtons[0].performClick(nil)
        XCTAssertEqual(editor.textView.font!.pointSize, originalSize)
        XCTAssertTrue(controller.status.isHidden)
    }

    func testHeaderFocusAndNativeToolbarComparisonAtMinimumWidth() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.notes[0], store: prepared.store))
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil) }
        window.setFrame(NSRect(x: 180, y: 180, width: 375, height: 260), display: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = [controller.backgroundTintButton] + controller.fontSizeButtons + controller.headerButtons
        let labels = buttons.compactMap { $0.accessibilityLabel() }
        XCTAssertEqual(Set(labels).count, 6)
        for button in buttons {
            XCTAssertEqual(button.contentTintColor, .labelColor)
            let grouped = controller.fontSizeButtons.contains { $0 === button }
            XCTAssertEqual(button.bezelStyle, grouped ? .regularSquare : .glass)
            XCTAssertTrue(button.isBordered)
            XCTAssertEqual(button.showsBorderOnlyWhileMouseInside, grouped)
            XCTAssertTrue(button.acceptsFirstResponder)
            XCTAssertTrue(window.makeFirstResponder(button))
            XCTAssertTrue(window.firstResponder === button)
            XCTAssertEqual(button.focusRingType, .exterior)
            XCTAssertEqual(button.focusRingMaskBounds, button.bounds)
            let rect = button.convert(button.bounds, to: controller.header)
            XCTAssertTrue(controller.header.bounds.contains(rect), "Clipped header action: \(button.accessibilityLabel() ?? "")")
            XCTAssertGreaterThan(rect.minX, 78, "Controls must clear the traffic lights")
        }
        window.recalculateKeyViewLoop()
        var keyViews = Set<ObjectIdentifier>()
        var view: NSView? = controller.editor.textView
        while let current = view, keyViews.insert(ObjectIdentifier(current)).inserted {
            view = current.nextKeyView
        }
        for button in buttons { XCTAssertTrue(keyViews.contains(ObjectIdentifier(button))) }
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertTrue(window.isMovable)

        // A native, labeled six-item toolbar is the comparison, not a shipped alternative.
        let native = NSWindow(contentRect: NSRect(x: 580, y: 180, width: 375, height: 260),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        defer { native.orderOut(nil) }
        let delegate = HeaderToolbarComparison(labels: labels, images: buttons.map(\.image))
        let toolbar = NSToolbar(identifier: "A11Comparison")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        native.toolbar = toolbar
        native.makeKeyAndOrderFront(nil)
        native.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil { toolbar.items.count == 6 }
        XCTAssertEqual(toolbar.items.count, 6)
        XCTAssertEqual(toolbar.items.map(\.label), labels)
        print("A11 native toolbar visible items: \(toolbar.visibleItems?.count ?? 0)/6 at 375 pt; custom header: 6/6 at 200% interface scale")
        for (name, target) in [("A11 custom header minimum width 200 percent", window), ("A11 native toolbar minimum width", native)] {
            if let frameView = target.contentView?.superview,
               let image = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: image)
                let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testLongTrashTitleDoesNotStretchConfirmation() throws {
        for title in [String(repeating: "Long note title with spaces 👩🏽‍💻 ", count: 100),
                      String(repeating: "unbrokentext", count: 300)] {
            let preview = NoteWindowController.trashTitlePreview(title)
            let alert = NSAlert()
            alert.messageText = "Move this note to Trash?"
            alert.informativeText = "The original file will be moved to Trash. You can restore it in Finder."
            alert.accessoryView = preview
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
            alert.layout()
            let label = try XCTUnwrap(preview.subviews.first as? NSTextField)
            XCTAssertEqual(preview.frame.width, 320)
            XCTAssertEqual(label.frame.minX, 4)
            XCTAssertEqual(label.frame.width, 316)
            XCTAssertEqual(label.maximumNumberOfLines, 2)
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
            XCTAssertLessThanOrEqual(alert.window.frame.width, 500,
                                     "Long text must not expand the confirmation window")
            XCTAssertLessThanOrEqual(preview.frame.height, 40)
        }
    }

    func testTrashClickAndShortcutRequireConfirmation() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.notes[0], store: prepared.store))
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var deletions = 0
        controller.deleteRequested = { deletions += 1 }
        let trashItem = try XCTUnwrap(controller.headerButtons.last)
        let action = try XCTUnwrap(trashItem.action)
        XCTAssertTrue(NSApp.sendAction(action, to: trashItem.target, from: trashItem))
        let cancelledSheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(deletions, 0)
        window.endSheet(cancelledSheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(deletions, 0)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        // The app's key monitor resolves the chord from settings, then calls the window's hook.
        let chord = ShortcutChord(event: event)
        XCTAssertEqual(AppShortcut.allCases.first { AppSettings().chord(for: $0) == chord }, .moveToTrash)
        let shortcutTarget = try XCTUnwrap((window as? GroupWindow)?.deleteRequested)
        shortcutTarget()
        let confirmedSheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(deletions, 0)
        // Repeating the shortcut while the sheet is open must not delete the note.
        shortcutTarget()
        XCTAssertEqual(deletions, 0)
        window.endSheet(confirmedSheet, returnCode: .alertSecondButtonReturn)
        try await waitUntil { deletions == 1 }
        XCTAssertEqual(deletions, 1)
    }

    func testUnavailableWithoutPendingEditDoesNotReportFailedSave() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let editor = NoteEditorController(note: prepared.notes[0], store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        XCTAssertFalse(editor.state.hasUnsavedEdits)
        for journaled in [true, false] {
            controller.display(.failed(editor.state.currentRevision, .unavailable, journaled: journaled))
            XCTAssertFalse(controller.status.isHidden)
            XCTAssertTrue(controller.status.stringValue.hasPrefix("This note is unavailable:"), controller.status.stringValue)
            XCTAssertFalse(controller.status.stringValue.contains("Save failed"))
            XCTAssertFalse(controller.status.stringValue.contains("recovery copy"))
        }
        editor.textView.string = "unsaved"
        editor.capture()
        XCTAssertTrue(editor.state.hasUnsavedEdits)
        controller.display(.failed(editor.state.currentRevision, .unavailable, journaled: true))
        XCTAssertTrue(controller.status.stringValue.hasPrefix("Save failed:"))
    }

    func testTypingDuringSaveFailureKeepsWarningUntilSaveSucceeds() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let editor = NoteEditorController(note: prepared.notes[0], store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        editor.textView.string = "unsaved"
        editor.capture()
        controller.display(.failed(editor.state.currentRevision, .permissionDenied, journaled: true))
        let message = controller.status.stringValue
        editor.textView.string += " more"
        editor.capture()
        controller.display(.pending(editor.state.currentRevision))
        XCTAssertFalse(controller.status.isHidden)
        XCTAssertEqual(controller.status.stringValue, message)
        controller.display(.saved(editor.state.currentRevision))
        XCTAssertTrue(controller.status.isHidden)
        controller.display(.pending(editor.state.currentRevision))
        XCTAssertTrue(controller.status.isHidden)
    }

    func testRoutineSavesStaySilentAndFailuresKeepDetails() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let editor = NoteEditorController(note: prepared.notes[0], store: prepared.store)
        let controller = NoteWindowController(editor: editor)
        for state in [StorageSaveStatus.pending(editor.note.editRevision), .saved(editor.note.editRevision)] {
            controller.display(state)
            XCTAssertTrue(controller.status.isHidden)
            XCTAssertTrue(controller.errorBlock.isHidden)
            XCTAssertEqual(controller.status.stringValue, "")
        }
        controller.showBlocker(NoteOperationError.permissionDenied)
        XCTAssertFalse(controller.status.isHidden)
        XCTAssertTrue(controller.status.stringValue.hasPrefix("Cannot close:"))
        XCTAssertFalse(controller.errorBlock.isHidden)
        controller.display(.saved(editor.note.editRevision))
        XCTAssertTrue(controller.errorBlock.isHidden)
    }

    func testReducedMotionUpdatesGlassWithoutChangingNoteTypography() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let controller = NoteWindowController(editor: NoteEditorController(note: prepared.notes[0], store: prepared.store))
        defer { controller.close() }
        var settings = AppSettings()
        settings.fontWeight = "Medium"
        controller.editor.apply(settings)
        let font = controller.editor.textView.font
        XCTAssertFalse(controller.headerGlassViews.isEmpty)
        controller.applyDisplayPreferences(reduceMotion: true)
        XCTAssertTrue(controller.headerGlassViews.allSatisfy { !$0.effectIsInteractive })
        controller.applyDisplayPreferences(reduceMotion: false)
        XCTAssertTrue(controller.headerGlassViews.allSatisfy { $0.effectIsInteractive })
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertTrue(controller.headerGlassViews.allSatisfy { $0.effectIsInteractive == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
        XCTAssertEqual(controller.editor.textView.font, font)
    }

    func testCloseFailureKeepsWindowTextAndWindowOpen() async throws {
        let prepared = try await makeWindowNotes(failDestination: true, count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.metadata.notes[prepared.notes[0].id] = NoteWindowMetadata(isOpen: true)
        coordinator.open(prepared.notes[0])
        let controller = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])
        let localText = "unsaved text must remain visible"

        controller.editor.textView.string = localText
        controller.editor.capture()
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        try await waitUntil { controller.status.stringValue.hasPrefix("Cannot close:") }

        XCTAssertTrue(controller.status.stringValue.hasPrefix("Cannot close:"))
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(controller.editor.textView.string, localText)
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[0].id]?.isOpen, true)
        XCTAssertEqual(try Data(contentsOf: prepared.notes[0].fileURL), Data("original".utf8))
    }

    func testCloseFlushesLatestTextBeforeClosingWindow() async throws {
        let prepared = try await makeWindowNotes(count: 1)
        let coordinator = WindowCoordinator(store: prepared.store)
        defer { coordinator.perform(.hide) }
        coordinator.metadata.notes[prepared.notes[0].id] = NoteWindowMetadata(isOpen: true)
        coordinator.open(prepared.notes[0])
        let controller = try XCTUnwrap(coordinator.windows[prepared.notes[0].id])
        let latestText = "latest text before close"

        controller.editor.textView.string = latestText
        controller.editor.capture()
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))

        try await waitUntil { coordinator.metadata.notes[prepared.notes[0].id]?.isOpen == false }

        XCTAssertEqual(try Data(contentsOf: prepared.notes[0].fileURL), Data(latestText.utf8))
        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertEqual(coordinator.metadata.notes[prepared.notes[0].id]?.isOpen, false)
        XCTAssertNil(coordinator.windows[prepared.notes[0].id])
    }
}

private struct WindowPreparedNotes {
    let fixture: TestFixture
    let store: NoteStore
    let folder: URL
    let collectionToken: CollectionToken
    let notes: [NoteSnapshot]
}

private func makeWindowNotes(failDestination: Bool = false, failJournal: Bool = false, count: Int = 2, readBody: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) async throws -> WindowPreparedNotes {
    let fixture = try TestFixture()
    let fault: StorageFault = { stage in
        if failDestination, case .destination = stage { throw NoteOperationError.permissionDenied }
        if failJournal, case .journal = stage { throw NoteOperationError.permissionDenied }
    }
    let store = try NoteStore(support: fixture.root, clock: fixture.clock, fault: fault, readBody: readBody)
    let folder = await store.defaultFolder()
    for number in 0..<count {
        try Data("original".utf8).write(to: folder.appendingPathComponent("Window note \(number).txt"))
    }
    let collectionToken = CollectionToken()
    let notes = try await store.discover(in: folder, collectionToken: collectionToken)
    return WindowPreparedNotes(fixture: fixture, store: store, folder: folder,
                               collectionToken: collectionToken, notes: notes)
}

@MainActor
private final class HeaderToolbarComparison: NSObject, NSToolbarDelegate {
    let labels: [String]
    let images: [NSImage?]
    init(labels: [String], images: [NSImage?]) { self.labels = labels; self.images = images }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        labels.indices.map { NSToolbarItem.Identifier("A11.\($0)") }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = toolbarDefaultItemIdentifiers(toolbar).firstIndex(of: identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = labels[index]
        item.paletteLabel = labels[index]
        item.image = images[index]
        item.target = self
        item.action = #selector(activate)
        return item
    }
    @objc private func activate() { }
}

/// Records what the note list asks of its delegate. Tests set the closures they care about.
@MainActor
final class TestListDelegate: NoteListDelegate {
    var onNewNote: () -> Void = {}
    var onTrash: (NoteSnapshot) -> Void = { _ in }
    var onTrashBatch: ([NoteSnapshot]) -> Void = { _ in }
    var onDragText: (NoteSnapshot) throws -> String? = { _ in nil }
    var onExportDrag: (NoteSnapshot, String?, URL) async throws -> Void = { _, _, _ in }
    var onAddExistingFiles: () -> Void = {}
    var onMoveTo: (NoteSnapshot) -> Void = { _ in }
    var onSaveCopy: (NoteSnapshot) -> Void = { _ in }
    var onHasPreservedText: (NoteID) -> Bool = { _ in false }
    var onNoteIssue: (NoteID) -> String? = { _ in nil }
    var onOpenPreservedText: (NoteSnapshot) -> Void = { _ in }
    var onShowInFinder: (NoteSnapshot) -> Void = { _ in }
    var onActionsAllowed: () -> Bool = { true }
    var onRestoreFileAccess: (NoteSnapshot) -> Void = { _ in }
    var onOpen: (NoteSnapshot) -> Void = { _ in }
    var onOpenBatch: ([NoteSnapshot]) -> Void = { _ in }
    var onBackgroundTone: (NoteID) -> NoteBackgroundTone? = { _ in nil }
    var onIsOpen: (NoteID) -> Bool = { _ in false }
    var onLocate: (NoteSnapshot) -> Void = { _ in }
    var onRemoveUnavailable: (NoteSnapshot) -> Void = { _ in }
    var onRemoveUnavailableBatch: ([NoteSnapshot]) -> Void = { _ in }
    var onLocation: (NoteSnapshot) -> Void = { _ in }
    var onRegisterFiles: ([URL]) -> Void = { _ in }

    func newNote() { onNewNote() }
    func trash(_ note: NoteSnapshot) { onTrash(note) }
    func trashBatch(_ notes: [NoteSnapshot]) { onTrashBatch(notes) }
    func dragText(_ note: NoteSnapshot) throws -> String? { try onDragText(note) }
    func exportDrag(_ note: NoteSnapshot, text: String?, to url: URL) async throws { try await onExportDrag(note, text, url) }
    func addExistingFiles() { onAddExistingFiles() }
    func moveTo(_ note: NoteSnapshot) { onMoveTo(note) }
    func saveCopy(_ note: NoteSnapshot) { onSaveCopy(note) }
    func hasPreservedText(_ id: NoteID) -> Bool { onHasPreservedText(id) }
    func noteIssue(_ id: NoteID) -> String? { onNoteIssue(id) }
    func openPreservedText(_ note: NoteSnapshot) { onOpenPreservedText(note) }
    func showInFinder(_ note: NoteSnapshot) { onShowInFinder(note) }
    func actionsAllowed() -> Bool { onActionsAllowed() }
    func restoreFileAccess(_ note: NoteSnapshot) { onRestoreFileAccess(note) }
    func open(_ note: NoteSnapshot) { onOpen(note) }
    func openBatch(_ notes: [NoteSnapshot]) { onOpenBatch(notes) }
    func backgroundTone(_ id: NoteID) -> NoteBackgroundTone? { onBackgroundTone(id) }
    func isOpen(_ id: NoteID) -> Bool { onIsOpen(id) }
    func locate(_ note: NoteSnapshot) { onLocate(note) }
    func removeUnavailable(_ note: NoteSnapshot) { onRemoveUnavailable(note) }
    func removeUnavailableBatch(_ notes: [NoteSnapshot]) { onRemoveUnavailableBatch(notes) }
    func location(_ note: NoteSnapshot) { onLocation(note) }
    func registerFiles(_ urls: [URL]) { onRegisterFiles(urls) }
}

nonisolated(unsafe) private var testDelegateKey = 0

extension NoteListController {
    /// Installs a `TestListDelegate` on first use and keeps it alive with the controller.
    var testDelegate: TestListDelegate {
        if let existing = objc_getAssociatedObject(self, &testDelegateKey) as? TestListDelegate { return existing }
        let created = TestListDelegate()
        objc_setAssociatedObject(self, &testDelegateKey, created, .OBJC_ASSOCIATION_RETAIN)
        delegate = created
        return created
    }
}
