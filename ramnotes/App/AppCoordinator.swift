import ramnotesDomain
import AppKit
import Synchronization
import os
#if !APP_STORE
import Sparkle
#endif

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let settingsCoordinator = SettingsCoordinator()
#if !APP_STORE
    private var updaterController: SPUStandardUpdaterController?
#endif
    private var shortcut: ShortcutService { settingsCoordinator.shortcut }
    private var gesture: GestureService { settingsCoordinator.gesture }
    private var settings: AppSettings { settingsCoordinator.settings }
    private var recordingShortcut: Bool { settingsCoordinator.recordingShortcut }
    private let list = ListWindowController()
    private var discovery: NoteListController { list.discovery }
    /// Every message shown in the list footer is also logged, because the next one replaces it.
    private var diagnostic: LoggedDiagnostic { LoggedDiagnostic(field: list.diagnostic) }
    private(set) var menu: AppMenuController?
    private var launchOrigin = LaunchOrigin()
    private let lifecycle = LifecycleController()
    private var storageReady: Bool { lifecycle.state == .ready || lifecycle.state == .failed }
    private(set) var metadataStore: MetadataStore?
    private var locations: LocationWorkflow?
    #if DEBUG
    private var exportPause: ExportPauseFixture?
    #endif
    private(set) var store: NoteStore? {
        didSet { locations = store.map { LocationWorkflow(notes: $0) } }
    }
    private(set) var windows: WindowCoordinator?
    private(set) var folder: FolderSelection? { didSet { defaultFolderCheckStale = true } }
    /// The default folder's missing state changes only with folder events, reconcile, or folder changes, not with each list refresh.
    private var defaultFolderCheckStale = true
    private var folderID: String?
    let folderState = FolderState()
    private var notes: [NoteID: NoteSnapshot] { folderState.notes }
    private var terminating = false
    private var switchingFolder: Bool { lifecycle.state == .switching }
    private var readyToQuit = false
    private(set) var metadataDelivery: MetadataPersistence?
    private var loadingToken = UUID()
    private let recovery = RecoveryController(exporter: VerifiedRecoveryExporter())
    private lazy var fileActions = NoteFileActions(discovery: discovery)
#if DEBUG
    private var recoveryLayoutFixtureSupport: URL?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Unit tests build their own throwaway stores.
        if NSClassFromString("XCTestCase") != nil { return }
        recovery.host = self
        fileActions.host = self
        recovery.saveCopy = { [weak self] note, _ in self?.fileActions.saveCopy(note) }
        list.recovery = recovery
        recovery.allowFolderAccess = { [weak self] in self?.fileActions.allowFolderAccess($0) }
        recovery.showLocation = { [weak self] note, onDismiss in self?.fileActions.showLocation(note, onDismiss: onDismiss) }
        settingsCoordinator.host = self
        list.showCommands = { [weak self] in self?.showCommands(nil) }
        list.showSettings = { [weak self] in self?.showSettings(nil) }
        list.escape = { [weak self] in self?.windows?.perform(.escape(transientActive: false)) }
        discovery.delegate = self
#if !APP_STORE
        if NSClassFromString("XCTestCase") == nil,
           let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let url = URL(string: feed), url.host != nil,
           (url.scheme == "https" || Bundle.main.object(forInfoDictionaryKey: "RNUpdateMode") as? String == "fixture"),
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           let decoded = Data(base64Encoded: key), decoded.count == 32 {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        settingsCoordinator.makeUpdateControls = { [weak self] in
            let check = NSButton(title: String(localized: "Check for Updates…", comment: "Settings button that checks for a new version of the app"), target: self?.updaterController,
                                 action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
            check.bezelStyle = .rounded
            let automatic = NSButton(checkboxWithTitle: String(localized: "Automatically check for updates", comment: "Settings checkbox for automatic update checks"), target: nil, action: nil)
            if let updater = self?.updaterController?.updater {
                check.bind(.enabled, to: updater, withKeyPath: "canCheckForUpdates", options: nil)
                automatic.bind(.value, to: updater, withKeyPath: "automaticallyChecksForUpdates", options: nil)
            } else {
                check.isEnabled = false
                automatic.isEnabled = false
            }
            let controls = NSStackView(views: [check, automatic])
            controls.orientation = .vertical
            controls.alignment = .leading
            return controls
        }
#endif
        installMenu()
        shortcut.toggle = { [weak self] in guard let self, !recordingShortcut else { return }; toggleNotes(invocationRequest) }
        settingsCoordinator.listShortcut.toggle = { [weak self] in guard let self, !recordingShortcut else { return }; toggleNotesWithList(invocationRequest) }

        gesture.invoke = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: toggleNotes(invocationRequest)
            case .toggleWithList: toggleNotesWithList(invocationRequest)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--login-launch") { launchOrigin.receive([LaunchOrigin.loginURL]) }
        #endif
        // AppKit delivers launch-time URL events before or just after this method, so the login helper's URL
        // is normally already recorded. The short grace period covers a late delivery without delaying normal launches.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !launchOrigin.finished else { return }
            launchOrigin.finish()
            if !launchOrigin.hidden { revealNotesWhenReady() }
        }
        Task { await startStorage() }
        observeResumeTriggers()
    }
    private var resumeObservers: [NSObjectProtocol] = []
    /// Activation and volume mounts can make a lost folder or an interrupted default-folder move workable again.
    private func observeResumeTriggers() {
        let resume: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.resumeInterruptedWork() } }
        resumeObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: resume),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAfterMount() }
            }
        ]
    }
    /// A mounted volume can also hold custom-path notes. Reconnect so they become available
    /// and their retained edits are saved, even when the default folder never went away.
    private func resumeAfterMount() {
        let reconnects = folder == nil || lifecycle.state == .failed || retryBatchID != nil
        resumeInterruptedWork()
        guard !reconnects, !terminating, !lifecycle.busy, lifecycle.state != .loading,
              notes.values.contains(where: { $0.availability != .available && $0.availability != .trashed }) else { return }
        reconnectFolder()
    }
    private func resumeInterruptedWork() {
        guard !terminating, !lifecycle.busy, lifecycle.state != .loading else { return }
        if folder == nil || lifecycle.state == .failed { reconnectFolder() }
        else if retryBatchID != nil { resumeDefaultMove() }
    }
    private func revealNotesWhenReady(withList: Bool = false) {
        lifecycle.reveal = { [weak self] in
            guard let self else { return }
            guard let windows = self.windows else { self.showList(nil); return }
            Task { [weak self] in
                await windows.revealVerified()
                if withList { self?.showList(nil) }
            }
        }
        lifecycle.requestReveal()
    }
    private func startStorage() async {
        await lifecycle.initialize { [weak self] token in
            guard let self else { return false }
            return await self.loadStorage(token: token)
        }
    }
    private func loadStorage(token: UUID) async -> Bool {
        lifecycle.stopObservation()
        let load = token
        loadingToken = load
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ramnotes")
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--test-session"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let session = UUID(uuidString: ProcessInfo.processInfo.arguments[index + 1]) {
            support = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-ui-" + session.uuidString, isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--test-pause-export") { exportPause = ExportPauseFixture() }
        }
        #endif
        // One metadata queue for the app's life, so a load retry keeps pending and failed writes.
        let metadata = metadataStore ?? MetadataStore(root: support)
        metadataStore = metadata
        if metadataDelivery == nil {
            let delivery = MetadataPersistence(store: metadata)
            delivery.failed = { [weak self] _, error in
                guard let self else { return }
                diagnostic.stringValue = String(localized: "Metadata could not be saved. Quit or folder switching may be blocked: \(error.localizedDescription)", comment: "Shown when note metadata cannot be written. The value is the system error")
            }
            metadataDelivery = delivery
        }
        let loaded = await metadata.loadSettings()
        settingsCoordinator.load(loaded.value)
        list.apply(settings)
        recovery.apply(settings)
        menu?.syncShortcuts()
        let supportAlreadyExisted = FileManager.default.fileExists(atPath: support.path)
        do {
            var storageFault: StorageFault = { _ in }
            #if DEBUG
            if support.lastPathComponent.hasPrefix("ramnotes-ui-"),
               let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--test-pause-at"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                storageFault = StoragePauseFixture.fault(stage: ProcessInfo.processInfo.arguments[index + 1], support: support)
            }
            #endif
            let store = try await NoteStore.make(support: support, fault: storageFault)
            #if DEBUG
            if support.lastPathComponent.hasPrefix("ramnotes-ui-"),
               ProcessInfo.processInfo.arguments.contains("--test-folder-access-fixture") {
                try await store.seedFolderAccessFixture()
            }
            if support.lastPathComponent.hasPrefix("ramnotes-ui-"),
               ProcessInfo.processInfo.arguments.contains("--test-damage-file-bookmarks") {
                try await store.damageFileBookmarksFixture()
            }
            #endif
            self.store = store
            await lifecycle.observe(store) { [weak self] event in self?.receive(event) }
            let coordinator = WindowCoordinator(store: store, folderState: folderState)
            windows = coordinator
            coordinator.settings = settings
            coordinator.listVisible = { [weak self] in self?.list.isVisible == true }
            coordinator.hideList = { [weak self] in self?.list.hide() }
            coordinator.createNote = { [weak self] in self?.newNote(nil) }
            coordinator.showList = { [weak self] in self?.showList(nil) }
            coordinator.showSettings = { [weak self] in self?.showSettings(nil) }
            coordinator.configureRecovery = { [weak self] in self?.recovery.configureRecovery($0) }
            coordinator.deleteNote = { [weak self] id in self?.recovery.deleteNote(id) }
            coordinator.toneChanged = { [weak self] in
                self?.discovery.refreshTones()
                self?.persistMetadata()
            }
            coordinator.openStateChanged = { [weak self] in self?.discovery.refreshTones() }
            coordinator.changed = { [weak self] in self?.persistMetadata() }
            let selection = try await store.openSelectedFolder { [weak self] partial in
                Task { @MainActor in
                    guard let self, self.loadingToken == load, self.lifecycle.isCurrent(load), self.folder == nil else { return }
                    self.discovery.indexing = true
                    self.discovery.update(partial)
                }
            }
            loadingToken = UUID()
            discovery.indexing = false
            folder = selection
            retryBatchID = await store.retryableDefaultFolderBatch()?.id
            folderID = await store.activeFolderIdentity
            folderState.replace(with: Dictionary(uniqueKeysWithValues: selection.notes.map { ($0.id, $0) }))
            let loadedCollection = await metadata.loadCollection()
            try await store.reconcile(collectionToken: selection.collectionToken)
            coordinator.metadata = loadedCollection.value
            adopt(await store.collectionReadSnapshot(), .initialRestoration)
            diagnostic.stringValue = (selection.recoveryDiagnostics + [loadedCollection.diagnostic?.localizedDescription].compactMap { $0 }).joined(separator: "\n")
#if DEBUG
            if RecoveryLayoutFixture.requested {
                recoveryLayoutFixtureSupport = try await RecoveryLayoutFixture.seed(
                    support: support, supportAlreadyExisted: supportAlreadyExisted, selection: selection, store: store,
                    folderState: folderState, recovery: recovery, windows: coordinator)
            }
#endif
            if let message = loaded.diagnostic?.localizedDescription { diagnostic.stringValue = message }
            refreshList()
            if retryBatchID != nil { Task { @MainActor in self.resumeDefaultMove() } }
            return true
        } catch {
            loadingToken = UUID()
            discovery.indexing = false
            let reason = error.localizedDescription
            diagnostic.stringValue = String(localized: "Cannot open notes: \(reason). Recovery journals remain available below. RAMnotes reconnects when the folder becomes available, or choose another folder in Settings.", comment: "Shown when the notes folder cannot be opened; value is the system error")
            if let store {
                let retained = await store.retainedRecovery()
                recovery.retainedEdits = retained.edits
            }
            refreshList()
            return false
        }
    }
    /// A recovery notice surfaces the note list once storage is ready and the app is on screen.
    private var revealsListForNotice: Bool {
        storageReady && (windows?.anyGroupVisible == true || (launchOrigin.finished && !launchOrigin.hidden))
    }
    func persistMetadata() {
        guard let value = windows?.metadata else { return }
        metadataDelivery?.submit(.collection(value))
    }
    @objc private func displaysChanged() { windows?.displaysChanged() }
    private func receive(_ event: NoteEvent) {
        switch event {
        case let .saveStatus(id, token, status):
            guard token == folder?.collectionToken else { return }
            windows?.windows[id]?.editor.receive(status)
        case let .saved(note):
            guard note.collectionToken == folder?.collectionToken else { return }
            folderState.apply(event)
            windows?.acceptFileObservation(note)
            windows?.windows[note.id]?.editor.adoptSaved(note)
            refreshList()
        case let .rebound(note):
            guard note.collectionToken == folder?.collectionToken else { return }
            folderState.apply(event)
            windows?.acceptFileObservation(note)
            windows?.windows[note.id]?.editor.applyRebinding(note)
            refreshList()
        case let .discovered(note), let .changed(note):
            guard note.collectionToken == folder?.collectionToken else { return }
            folderState.apply(event)
            defaultFolderCheckStale = true
            windows?.acceptFileObservation(note)
            windows?.windows[note.id]?.editor.applyExternal(note)
            refreshList()
        case let .removed(id, token):
            guard token == folder?.collectionToken else { return }
            folderState.apply(event)
            defaultFolderCheckStale = true
            windows?.noteRemoved(id)
            refreshList()
        case .notice:
            // The store holds the notice before it emits. Re-read its list rather than keep a copy.
            // A folder switch or a newer projection during the await makes this result stale.
            let token = folder?.collectionToken, generation = recovery.projectionGeneration
            Task { [weak self] in
                guard let self, let store = self.store else { return }
                let notices = await store.recoveryNotices()
                guard token == self.folder?.collectionToken, generation == self.recovery.projectionGeneration else { return }
                self.recovery.project(notices)
                if self.revealsListForNotice { self.showList(nil) }
            }
        case let .failed(_, error): diagnostic.stringValue = String(localized: "Storage needs attention: \(error.localizedDescription)", comment: "Shown when the notes store reports a failure. The value is the system error")
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        menu?.stop()
        shortcut.stop(); settingsCoordinator.listShortcut.stop(); gesture.stop(); lifecycle.stopObservation()
#if DEBUG
        if let recoveryLayoutFixtureSupport { try? FileManager.default.removeItem(at: recoveryLayoutFixtureSupport) }
#endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launchOrigin.manualReopen()
        revealNotesWhenReady()
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) { launchOrigin.receive(urls) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            do {
                try await lifecycle.transact(.quitting, editors: { self.windows }, captureGeometry: { self.windows?.captureAllGeometry() },
                    flushMetadata: { try await self.metadataDelivery?.flush() }, commit: {})
                readyToQuit = true
#if DEBUG
                if let recoveryLayoutFixtureSupport {
                    try? FileManager.default.removeItem(at: recoveryLayoutFixtureSupport)
                    self.recoveryLayoutFixtureSupport = nil
                }
#endif
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            catch { terminating = false; let reason = error.localizedDescription.trimmingCharacters(in: .punctuationCharacters); diagnostic.stringValue = String(localized: "Quit blocked: \(reason). Try again, or export unsaved text.", comment: "Shown when quitting fails; value is the system error"); list.showFailure(diagnostic.stringValue) { self.performRefresh() }; NSApp.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }

    func installMenu() {
        var updateTarget: AnyObject?
#if !APP_STORE
        updateTarget = updaterController
#endif
        let menu = AppMenuController(commands: AppMenuCommands(
            showSettings: { [weak self] in self?.showSettings(nil) },
            quit: { [weak self] in self?.quit(nil) },
            searchNotes: { [weak self] in self?.searchNotes(nil) },
            newNote: { [weak self] in self?.newNote(nil) },
            addExistingFiles: { [weak self] in self?.addExistingFiles(nil) },
            trashActiveNote: { [weak self] in self?.trashActiveNote(nil) },
            showList: { [weak self] in self?.showList(nil) },
            nextNote: { [weak self] in self?.nextNote(nil) },
            previousNote: { [weak self] in self?.previousNote(nil) },
            toggleNotes: { [weak self] in self?.toggleNotes() },
            showCommands: { [weak self] in self?.showCommands(nil) },
            changeFontSize: { [weak self] in self?.changeNoteFont(by: $0) },
            changeTint: { [weak self] in self?.activeNote?.chooseBackgroundTint($0) }),
            state: { [weak self] in self?.menuState ?? AppMenuState() },
            settings: { [weak self] in self?.settings ?? AppSettings() },
            updateTarget: updateTarget)
        menu.install()
        self.menu = menu
    }
    /// The values the application menu validates its items and shortcuts against.
    private var menuState: AppMenuState {
        let listIsKey = NSApp.keyWindow === list.window
        return AppMenuState(
            commandsAllowed: commandsAllowed,
            canAddNotes: commandsAllowed && !recoveryBlocked && store != nil && folder != nil,
            canTrash: canTrashActiveNote,
            selectedListNotes: listIsKey ? discovery.selectedNotes.count : 0,
            activeNoteTone: activeNote.map { .some($0.editor.backgroundTone) } ?? .none,
            noteWindowCount: windows?.windows.count ?? 0)
    }
    private var canTrashActiveNote: Bool {
        if NSApp.keyWindow === list.window { return discovery.canTrashSelection }
        guard let note = activeNote else { return false }
        return !recoveryBlocked && store != nil && folder != nil
            && windows?.windows[note.editor.note.id] === note
            && notes[note.editor.note.id]?.availability == .available
    }
    private var commandsAllowed: Bool {
        !recordingShortcut && NSApp.modalWindow == nil && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil
    }
    private var activeNote: NoteWindowController? {
        guard commandsAllowed else { return nil }
        return NSApp.keyWindow?.windowController as? NoteWindowController
    }
    private func trashActiveNote(_ sender: Any?) {
        guard canTrashActiveNote else { return }
        if NSApp.keyWindow === list.window { discovery.trashSelection(); return }
        (activeNote?.window as? GroupWindow)?.deleteRequested?()
    }
    /// Steps the active note's font size; zero restores the default size.
    private func changeNoteFont(by step: Int) {
        guard let note = activeNote else { return }
        if step == 0 { note.editor.setFontSize(nil) }
        else { note.editor.adjustFontSize(by: Double(step)) }
    }
    private func nextNote(_ sender: Any?) {
        guard commandsAllowed, let window = NSApp.keyWindow else { return }
        windows?.focusAdjacentNote(backward: false, from: window)
    }
    private func previousNote(_ sender: Any?) {
        guard commandsAllowed, let window = NSApp.keyWindow else { return }
        windows?.focusAdjacentNote(backward: true, from: window)
    }
    private func showCommands(_ sender: Any?) {
        guard commandsAllowed, let menu = NSApp.mainMenu?.copy() as? NSMenu,
              let view = NSApp.keyWindow?.contentView else { return }
        if NSApp.keyWindow === list.window, let button = list.commandsButton {
            let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
            menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 12, y: view.bounds.height - 40), in: view)
        }
    }
    private func searchNotes(_ sender: Any?) {
        showList(sender)
        discovery.focus()
    }
    private func showList(_ sender: Any?) {
        if lifecycle.state == .idle || lifecycle.state == .loading {
            revealNotesWhenReady()
            return
        }
        let sourceNoteID = windows?.windows.first { $0.value.window === NSApp.keyWindow }?.key
        list.present(focusing: sourceNoteID) { refreshList() }
    }
    private var refreshScheduled = false
    /// Runs at most once per main-queue turn. Otherwise each keystroke and each scan event
    /// would re-index every snapshot.
    func refreshList() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            performRefresh()
        }
    }
    private func performRefresh() {
        var captures: [NoteID: NoteListEditCapture] = [:]
        for (id, controller) in windows?.windows ?? [:] where notes[id] != nil && controller.editor.state.hasUnsavedEdits {
            captures[id] = NoteListEditCapture(text: controller.editor.capturedText, editedAt: controller.listedEditTime)
        }
        windows?.defaultFolder = folder?.url
        discovery.defaultFolder = folder?.url
        discovery.update(Array(notes.values), captures: captures)
        updateSettingsStatus()
        list.render(recovery)
        if defaultFolderCheckStale, let store, let selected = folder {
            defaultFolderCheckStale = false
            let token = selected.collectionToken
            Task {
                guard let missing = try? await store.isDefaultFolderMissing(collectionToken: token),
                      self.folder?.collectionToken == token, self.folder?.url == selected.url else { return }
                self.list.defaultFolderMissing = missing
                self.updateSettingsStatus()
            }
        }
    }
    private func openAvailable(_ note: NoteSnapshot) {
        guard note.collectionToken == folder?.collectionToken else { return }
        guard note.availability == .available else { recheckAvailability(note); return }
        Task { await windows?.openVerified(note) }
    }
    private func recheckAvailability(_ note: NoteSnapshot) {
        guard let store, note.collectionToken == folder?.collectionToken else { return }
        diagnostic.stringValue = String(localized: "Checking availability…", comment: "Status while the app checks whether the notes folder is reachable again")
        Task {
            do {
                let message = try await store.retryAvailability(note.id, collectionToken: note.collectionToken)
                guard note.collectionToken == folder?.collectionToken else { return }
                diagnostic.stringValue = message
                folderState.apply(.changed(try await store.read(note.id, collectionToken: note.collectionToken)))
                refreshList()
            } catch {
                guard note.collectionToken == folder?.collectionToken else { return }
                diagnostic.stringValue = String(localized: "Still unavailable: \(error.localizedDescription)", comment: "Shown when the notes folder is still unreachable. The value is the system error") }
        }
    }
    /// How `adopt` treats open windows: the first load after opening a folder also passes each
    /// note's file facts to its window; later refreshes leave window observation to note events.
    private enum CollectionAdoption { case initialRestoration, refresh }
    /// Publishes one store read to the collection projection, window state, and recovery presentation.
    /// Window metadata is loaded separately and must already be in place.
    private func adopt(_ snapshot: CollectionReadSnapshot, _ adoption: CollectionAdoption) {
        folderState.replace(with: snapshot.notes)
        // Drop window state for notes the store no longer registers and save it if it changed.
        if let windows, let pruned = WindowStatePruning.prune(windows.metadata, registered: snapshot.registeredNoteIDs) {
            windows.metadata = pruned
            metadataDelivery?.submit(.collection(pruned))
        }
        if adoption == .initialRestoration { for note in notes.values { windows?.acceptFileObservation(note) } }
        windows?.adoptRetainedEdits(snapshot.retainedEdits)
        recovery.project(snapshot.recoveryNotices)
        recovery.retainedEdits = snapshot.retainedRecovery
    }
    func reconnectFolder() {
        guard !terminating, !lifecycle.busy else { return }
        guard let store, let folder else { Task { await startStorage() }; return }
        Task {
            do {
                try await lifecycle.transact(.retrying, editors: { self.windows }, captureGeometry: { self.windows?.captureAllGeometry() }, flushMetadata: {}) { [self] in
                    try await store.reconcile(collectionToken: folder.collectionToken)
                    let messages = await store.replayRecovery()
                    let snapshot = await store.collectionReadSnapshot()
                    guard folder.collectionToken == self.folder?.collectionToken else { return }
                    adopt(snapshot, .refresh)
                    defaultFolderCheckStale = true
                    diagnostic.stringValue = messages.joined(separator: "\n")
                    refreshList()
                }
            } catch { diagnostic.stringValue = String(localized: "Folder reconnect failed: \(error.localizedDescription)", comment: "Shown when reconnecting the notes folder fails. The value is the system error") }
        }
    }
    private var retryBatchID: UUID?
    private func resumeDefaultMove() {
        guard !terminating, !lifecycle.busy, let store, let folder, let id = retryBatchID else { return }
        Task {
            defer { updateSettingsStatus() }
            do {
                try await lifecycle.retryDefaultFolder(id, from: folder.collectionToken, using: store,
                    editors: { self.windows }, captureGeometry: { self.windows?.captureAllGeometry() },
                    flushMetadata: { try await self.metadataDelivery?.flush() },
                    willCommit: { self.updateSettingsStatus() },
                    didCommit: { await self.adoptDefaultResult($0, store: store) })
            } catch { diagnostic.stringValue = error.localizedDescription }
        }
    }
    private func adoptDefaultResult(_ result: DefaultFolderChangeResult, store: NoteStore) async {
        folderID = await store.activeFolderIdentity
        adopt(await store.collectionReadSnapshot(), .refresh)
        folder = FolderSelection(url: result.folder, collectionToken: result.collectionToken, notes: Array(notes.values), recoveryDiagnostics: [])
        retryBatchID = await store.retryableDefaultFolderBatch()?.id
        if let batch = result.batch {
            let renames = batch.entries.filter { $0.state == .moved && $0.sourceURL.lastPathComponent != $0.destination.lastPathComponent }
            let failures = batch.entries.filter { $0.state != .moved }.map { String(localized: "\(NoteLocationPresentation.path($0.sourceURL)): \($0.message ?? String(localized: "Pending — continues automatically when RAMnotes is next active.", comment: "Reason shown for a note whose move has not finished yet"))", comment: "One line in the move result: a file path, then the reason it was not moved. Both values are inserted as is") }
            list.showActionResult(([String(localized: "Moved \(batch.entries.filter { $0.state == .moved }.count) of \(batch.entries.count) notes.", comment: "Result of moving notes to a new default folder. First count is notes moved, second is the total. Plural follows the total")] + renames.map { String(localized: "Renamed \(PathIsolation.isolate($0.sourceURL.lastPathComponent)) → \(PathIsolation.isolate($0.destination.lastPathComponent))", comment: "A file was renamed during a move to avoid a name clash. Both values are file names. The arrow separates old and new name") } + failures + [result.error?.localizedDescription].compactMap { $0 }).joined(separator: "\n"))
        }
        refreshList()
    }
    func chooseFolder() {
        guard !terminating, !switchingFolder, fileActions.locationController == nil, let store, let url = FolderAccess.chooseFolder() else { return }
        guard !lifecycle.busy else { return }
        let confirmation = DefaultFolderConfirmation.make(destination: url)
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let moveExisting = confirmation.suppressionButton?.state == .on
        Task {
            defer { updateSettingsStatus() }
            do {
                try await lifecycle.changeDefaultFolder(to: url, moveExisting: moveExisting, using: store,
                    editors: { self.windows }, captureGeometry: { self.windows?.captureAllGeometry() },
                    flushMetadata: { try await self.metadataDelivery?.flush() },
                    willCommit: { self.updateSettingsStatus() },
                    didCommit: { await self.adoptDefaultResult($0, store: store) })
            } catch { diagnostic.stringValue = String(localized: "Folder switch blocked: \(error.localizedDescription). Try again, or export unsaved text.", comment: "Shown when changing the default folder fails. The value is the system error"); showList(nil) }
        }
    }
    private func addExistingFiles(_ sender: Any?) { fileActions.addExistingFiles() }

    private func newNote(_ sender: Any?) {
        guard !terminating, !lifecycle.busy else { return }
        guard let store, let folder else { diagnostic.stringValue = String(localized: "Notes folder is not available yet.", comment: "Shown when the user acts before the notes folder has loaded"); return }
        Task {
            do { let note = try await store.create(in: folder.url, collectionToken: folder.collectionToken)
                guard note.collectionToken == self.folder?.collectionToken else { return }
                folderState.apply(.changed(note)); windows?.open(note, new: true); refreshList() }
            catch {
                let missing = (try? await store.isDefaultFolderMissing(collectionToken: folder.collectionToken)) == true
                guard folder.collectionToken == self.folder?.collectionToken, folder.url == self.folder?.url else { return }
                list.defaultFolderMissing = missing
                diagnostic.stringValue = missing ? "" : String(localized: "Cannot create note: \(error.localizedDescription)", comment: "Shown when a new note cannot be created. The value is the system error")
                showList(nil)
            }
        }
    }
    private func showSettings(_ sender: Any?) { settingsCoordinator.show() }
    private func updateSettingsStatus() { settingsCoordinator.updateStatus() }

    /// The request for a global shortcut or menu-bar gesture. Read when the input arrives, before any reveal activates RAMnotes.
    private var invocationRequest: ToggleRequest {
        ToggleRequest(bringForwardWhenInactive: settings.bringNotesForwardWhenInactive, appActive: NSApp.isActive)
    }
    private func toggleNotes(_ request: ToggleRequest = .toggle) {
        guard storageReady else { revealNotesWhenReady(); return }
        guard let windows else { showList(nil); return }
        if request.hides(groupVisible: windows.anyGroupVisible) { windows.perform(.hide) }
        else { Task { await windows.revealVerified() } }
    }
    private func toggleNotesWithList(_ request: ToggleRequest = .toggle) {
        guard storageReady else { revealNotesWhenReady(withList: true); return }
        if request.hides(groupVisible: windows?.anyGroupVisible == true) { windows?.perform(.hide); return }
        Task { [weak self] in
            guard let self else { return }
            await windows?.revealVerified()
            showList(nil)
        }
    }
    private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}

extension AppCoordinator: SettingsHost {
    var defaultFolderBusy: Bool { lifecycle.busy }
    var defaultFolderMissing: Bool { list.defaultFolderMissing }
    func settingsDidChange(_ settings: AppSettings) {
        windows?.settings = settings
        list.apply(settings)
        recovery.apply(settings)
        menu?.syncShortcuts()
        metadataDelivery?.submit(.settings(settings))
    }
    func shortcutMessageChanged(_ message: String) { list.shortcutLabel.stringValue = message }
    var folderStatus: String {
        let status: String
        if switchingFolder { status = String(localized: "Saving edits and switching folder…", comment: "Settings status while the default folder is being changed") }
        else if let folder { status = String(localized: "Default notes folder: \(NoteLocationPresentation.path(folder.url))", comment: "Settings status. The value is the path of the default notes folder") }
        else { status = String(localized: "Default notes folder: Unavailable — choose a folder.", comment: "Settings status when the default notes folder cannot be reached") }
        return status + (diagnostic.stringValue.isEmpty ? "" : "\n" + diagnostic.stringValue)
    }
}

extension AppCoordinator: RecoveryHost {
    var recoveryNotes: (any RecoveryNotes)? { store }
    var recoveryBlocked: Bool { terminating || lifecycle.busy }
    func showMessage(_ text: String) { list.showActionResult(text) }
    func showList() { showList(nil) }
    func revealNote(_ id: NoteID) {
        showList(nil)
        list.discovery.returnFocus(to: id)
    }
}

extension AppCoordinator: NoteFileActionsHost {
    var locationWorkflow: LocationWorkflow? { locations }
    var fileActionsBlocked: Bool { terminating || lifecycle.busy }
    var noteListWindow: NSWindow? { list.window }
    func refreshListNow() { performRefresh() }
    func adoptRetainedRecovery(_ edits: [RetainedEditSummary]) { recovery.retainedEdits = edits }
}

private struct LoggedDiagnostic {
    let field: NSTextField
    var stringValue: String {
        get { field.stringValue }
        nonmutating set {
            if !newValue.isEmpty { Log.access.notice("diagnostic: \(newValue, privacy: .private)") }
            field.stringValue = newValue
        }
    }
}

extension AppCoordinator: NoteListDelegate {
    func registerFiles(_ urls: [URL]) { fileActions.registerExistingFiles(urls) }
    func addExistingFiles() { fileActions.addExistingFiles() }
    func moveTo(_ note: NoteSnapshot) { fileActions.moveNote(note) }
    func saveCopy(_ note: NoteSnapshot) { fileActions.saveCopy(note) }
    func hasPreservedText(_ id: NoteID) -> Bool { recovery.retainedEdit(for: id) != nil }
    func noteIssue(_ id: NoteID) -> String? { recovery.cardIssue(for: id) }
    func openPreservedText(_ note: NoteSnapshot) {
        guard let record = recovery.retainedEdit(for: note.id) else { return }
        recovery.openRetained(record)
    }
    func showInFinder(_ note: NoteSnapshot) { NSWorkspace.shared.activateFileViewerSelecting([note.fileURL]) }
    func newNote() { newNote(nil) }
    func actionsAllowed() -> Bool {
        commandsAllowed && !recoveryBlocked && store != nil && folder != nil
    }
    func trash(_ note: NoteSnapshot) {
        guard actionsAllowed(), notes[note.id]?.availability == .available else { return }
        windows?.open(note)
        (windows?.windows[note.id]?.window as? GroupWindow)?.deleteRequested?()
    }
    func trashBatch(_ notes: [NoteSnapshot]) {
        guard actionsAllowed(), let window = list.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.window.identifier = NSUserInterfaceItemIdentifier("TrashConfirmation")
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Move \(notes.count) notes to Trash?", comment: "Confirmation title before moving several notes to the Trash")
        alert.informativeText = String(localized: "Each original file will be moved to Trash. You can restore it in Finder.", comment: "Confirmation text before moving several notes to the Trash. Use the system terms for Trash and Finder")
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button that dismisses a dialog without acting"))
        alert.addButton(withTitle: String(localized: "Move to Trash", comment: "Destructive button that moves notes to the Trash. Use the system term for Trash")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.recovery.deleteNotes(notes)
        }
    }
    func dragText(_ note: NoteSnapshot) throws -> String? {
        guard let editor = windows?.windows[note.id]?.editor else { return nil }
        guard !editor.textView.hasMarkedText(), !editor.textView.isWritingToolsActive else {
            throw NoteOperationError.inputOutput(LocalizedStringResource("Finish text composition before dragging.", comment: "Error when dragging a note while the user is still composing text with an input method"))
        }
        return editor.textView.string
    }
    func exportDrag(_ note: NoteSnapshot, text: String?, to url: URL) async throws {
        guard actionsAllowed(), store != nil else { throw NoteOperationError.unavailable }
        #if DEBUG
        await exportPause?.wait()
        #endif
        guard let store else { throw NoteOperationError.unavailable }
        try await store.writeDragCopy(note, text: text, to: url)
    }
    func open(_ note: NoteSnapshot) { openAvailable(note) }
    func openBatch(_ notes: [NoteSnapshot]) {
        guard notes.allSatisfy({ $0.collectionToken == folder?.collectionToken && $0.availability == .available }) else { return }
        Task { await windows?.openBatchVerified(notes) }
    }
    func backgroundTone(_ id: NoteID) -> NoteBackgroundTone? { windows?.metadata.notes[id]?.backgroundTone }
    func isOpen(_ id: NoteID) -> Bool { windows?.metadata.notes[id]?.isOpen == true }
    func location(_ note: NoteSnapshot) { fileActions.showLocation(note) }
    func restoreFileAccess(_ note: NoteSnapshot) { fileActions.allowFolderAccess(note) }
    func locate(_ note: NoteSnapshot) { fileActions.locateNote(note) }
    func removeUnavailable(_ note: NoteSnapshot) { fileActions.removeUnavailable(note) }
    func removeUnavailableBatch(_ notes: [NoteSnapshot]) { fileActions.removeUnavailable(notes) }
}

/// How a toggle command treats a group that is already visible.
enum ToggleRequest: Equatable {
    case toggle
    case bringForward

    /// A global shortcut or menu-bar gesture used while another app is active brings notes forward when the preference allows it.
    init(bringForwardWhenInactive: Bool, appActive: Bool) {
        self = bringForwardWhenInactive && !appActive ? .bringForward : .toggle
    }

    func hides(groupVisible: Bool) -> Bool { self == .toggle && groupVisible }
}
