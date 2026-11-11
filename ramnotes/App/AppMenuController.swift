import AppKit
#if !APP_STORE
import Sparkle
#endif

/// Commands the application menu and its shortcut monitor send to the app coordinator.
@MainActor
struct AppMenuCommands {
    var showSettings: () -> Void
    var quit: () -> Void
    var searchNotes: () -> Void
    var newNote: () -> Void
    var addExistingFiles: () -> Void
    var trashActiveNote: () -> Void
    var showList: () -> Void
    var nextNote: () -> Void
    var previousNote: () -> Void
    var toggleNotes: () -> Void
    var showCommands: () -> Void
    /// Steps the active note's font size by the value; zero restores the default.
    var changeFontSize: (Int) -> Void
    /// Applies the tint of a Background Tint item, tagged by tone index.
    var changeTint: (NSMenuItem) -> Void
}

/// The values menu validation and shortcut routing read. The app coordinator supplies them.
struct AppMenuState {
    var commandsAllowed = false
    var canAddNotes = false
    var canTrash = false
    /// Notes selected in the note list while it is the key window, otherwise zero.
    var selectedListNotes = 0
    /// The key note window's tint: nil when no note window is active, `.some(nil)` for no tint.
    var activeNoteTone: NoteBackgroundTone?? = nil
    var noteWindowCount = 0
}

/// Builds the main menu, keeps command shortcuts in sync with settings, validates items,
/// and routes in-app command shortcuts. It owns no note state; it sends commands back.
@MainActor
final class AppMenuController: NSObject, NSMenuItemValidation {
    private let commands: AppMenuCommands
    private let state: () -> AppMenuState
    private let settings: () -> AppSettings
    private weak var updateTarget: AnyObject?
    private var navigationMonitor: Any?
    private var openLinkMenuItem: NSMenuItem?
    private var noteListMenuItem: NSMenuItem?
    private var toggleNotesMenuItem: NSMenuItem?
    private var commandItems: [AppShortcut: NSMenuItem] = [:]

    init(commands: AppMenuCommands, state: @escaping () -> AppMenuState, settings: @escaping () -> AppSettings, updateTarget: AnyObject?) {
        self.commands = commands
        self.state = state
        self.settings = settings
        self.updateTarget = updateTarget
    }
    func stop() {
        if let navigationMonitor { NSEvent.removeMonitor(navigationMonitor) }
        navigationMonitor = nil
    }
    /// Builds the main menu and starts routing configured command shortcuts.
    func install() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.title = "RAMnotes"
        appMenu.addItem(withTitle: String(localized: "About RAMnotes", comment: "App menu item that shows the About panel. Keep the product name RAMnotes unchanged."), action: #selector(showAbout(_:)), keyEquivalent: "").target = self
#if !APP_STORE
        do {
            let updateItem = appMenu.addItem(withTitle: String(localized: "Check for Updates…", comment: "App menu item that checks for a new version of the app"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = updateTarget
            if updateTarget == nil { updateItem.action = nil; updateItem.isEnabled = false }
        }
#endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…", comment: "App menu item that opens the Settings window. Use the system term for Settings."), action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        let services = NSMenu(title: String(localized: "Services", comment: "App menu submenu title for macOS Services. Use the system term."))
        let servicesItem = NSMenuItem(title: String(localized: "Services", comment: "App menu submenu title for macOS Services. Use the system term."), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide RAMnotes", comment: "App menu item that hides the app. Keep the product name RAMnotes unchanged."), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others", comment: "App menu item that hides all other apps. Use the system term."), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All", comment: "App menu item that shows all hidden apps. Use the system term."), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit RAMnotes", comment: "App menu item that quits the app. Keep the product name RAMnotes unchanged."), action: #selector(quit(_:)), keyEquivalent: "q").target = self
        let searchNotes = appMenu.addItem(withTitle: String(localized: "Search Notes", comment: "App menu item that opens the note list and focuses its search field"), action: #selector(searchNotes(_:)), keyEquivalent: "f")
        searchNotes.keyEquivalentModifierMask = [.command, .shift]
        searchNotes.target = self
        appItem.title = "RAMnotes"
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileMenu = NSMenu(title: String(localized: "File", comment: "Top-level menu title"))
        fileMenu.addItem(withTitle: String(localized: "New Note", comment: "File menu item that creates a note"), action: #selector(newNote(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: String(localized: "Add Existing Files…", comment: "File menu item that adds existing text files from disk to the note collection"), action: #selector(addExistingFiles(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: String(localized: "Close", comment: "File menu item that closes the front window (verb)"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        commandItems[.moveToTrash] = fileMenu.addItem(withTitle: String(localized: "Move to Trash…", comment: "File menu item that moves the active note's file to the Trash. Use the system term for Trash."), action: #selector(trashActiveNote(_:)), keyEquivalent: "")
        commandItems[.moveToTrash]?.target = self
        menu.addItem(withTitle: String(localized: "File", comment: "Top-level menu title"), action: nil, keyEquivalent: "").submenu = fileMenu
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit", comment: "Top-level menu title"))
        for (title, action, key) in [(String(localized: "Undo", comment: "Edit menu item"), Selector(("undo:")), "z"), (String(localized: "Redo", comment: "Edit menu item"), Selector(("redo:")), "Z"),
            (String(localized: "Cut", comment: "Edit menu item"), #selector(NSText.cut(_:)), "x"), (String(localized: "Copy", comment: "Edit menu item"), #selector(NSText.copy(_:)), "c"),
            (String(localized: "Paste", comment: "Edit menu item"), #selector(NSText.paste(_:)), "v"), (String(localized: "Select All", comment: "Edit menu item"), #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        openLinkMenuItem = editMenu.addItem(withTitle: String(localized: "Open Link", comment: "Edit menu item that opens the link under the cursor in the note"), action: #selector(PlainTextView.openLink(_:)), keyEquivalent: "")
        let findItem = NSMenuItem(title: String(localized: "Find", comment: "Find menu title, inside the Edit menu"), action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: String(localized: "Find", comment: "Find menu title, inside the Edit menu"))
        for (title, action, key, modifiers) in [
            (String(localized: "Find…", comment: "Find menu item that shows the find bar"), NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command),
            (String(localized: "Find Next", comment: "Find menu item"), .nextMatch, "g", .command),
            (String(localized: "Find Previous", comment: "Find menu item"), .previousMatch, "g", [.command, .shift]),
            (String(localized: "Use Selection for Find", comment: "Find menu item that uses the selected text as the search string"), .setSearchString, "e", .command)
        ] {
            let item = findMenu.addItem(withTitle: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.tag = action.rawValue
            item.keyEquivalentModifierMask = modifiers
        }
        findItem.submenu = findMenu
        editMenu.addItem(findItem)
        editItem.title = String(localized: "Edit", comment: "Top-level menu title")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let viewMenu = NSMenu(title: String(localized: "View", comment: "Top-level menu title"))
        for (command, title, tag) in [(AppShortcut.increaseFont, String(localized: "Increase Font Size", comment: "View menu item"), 1), (.decreaseFont, String(localized: "Decrease Font Size", comment: "View menu item"), -1), (.resetFont, String(localized: "Reset Font Size", comment: "View menu item that restores the default font size"), 0)] {
            let item = viewMenu.addItem(withTitle: title, action: #selector(changeFont(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            commandItems[command] = item
        }
        let tintMenu = NSMenu(title: String(localized: "Background Tint", comment: "View submenu title for choosing the note's background color"))
        for (index, title) in ([NoteBackgroundTone.noColorName] + NoteBackgroundTone.allCases.map(\.localizedName)).enumerated() {
            let item = tintMenu.addItem(withTitle: title, action: #selector(changeTint(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
        }
        viewMenu.addItem(withTitle: String(localized: "Background Tint", comment: "View submenu title for choosing the note's background color"), action: nil, keyEquivalent: "").submenu = tintMenu
        viewMenu.addItem(.separator())
        noteListMenuItem = viewMenu.addItem(withTitle: String(localized: "Note list", comment: "View menu item that shows the note list window"), action: #selector(showList(_:)), keyEquivalent: "")
        noteListMenuItem?.target = self
        commandItems[.noteList] = noteListMenuItem
        for (command, title, action) in [(AppShortcut.nextNote, String(localized: "Next Note", comment: "View menu item that moves focus to the next open note"), #selector(nextNote(_:))), (.previousNote, String(localized: "Previous Note", comment: "View menu item that moves focus to the previous open note"), #selector(previousNote(_:)))] {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            commandItems[command] = item
        }
        toggleNotesMenuItem = viewMenu.addItem(withTitle: String(localized: "Toggle Notes", comment: "View menu item that shows or hides all open notes"), action: #selector(toggleNotes(_:)), keyEquivalent: "")
        toggleNotesMenuItem?.target = self
        menu.addItem(withTitle: String(localized: "View", comment: "Top-level menu title"), action: nil, keyEquivalent: "").submenu = viewMenu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window", comment: "Top-level menu title"))
        windowMenu.addItem(withTitle: String(localized: "Next Window", comment: "Window menu item that moves focus to the next window"), action: #selector(nextWindow(_:)), keyEquivalent: "`")
        let previousWindow = windowMenu.addItem(withTitle: String(localized: "Previous Window", comment: "Window menu item that moves focus to the previous window"), action: #selector(previousWindow(_:)), keyEquivalent: "`")
        previousWindow.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.items.forEach { $0.target = self }
        windowItem.title = String(localized: "Window", comment: "Top-level menu title")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        let help = NSMenu(title: String(localized: "Help", comment: "Top-level menu title"))
        help.addItem(withTitle: String(localized: "RAMnotes Help", comment: "Help menu item. Keep the product name RAMnotes unchanged."), action: #selector(showHelp(_:)), keyEquivalent: "").target = self
        let commands = help.addItem(withTitle: String(localized: "Commands", comment: "Help menu item that pops up a menu of all commands"), action: #selector(showCommands(_:)), keyEquivalent: "?")
        commands.target = self
        commands.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: String(localized: "Help", comment: "Top-level menu title"), action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
        syncShortcuts()
        navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.state().commandsAllowed, NSApp.keyWindow != nil else { return false }
                if event.keyCode == 44, event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift] {
                    self.commands.showCommands()
                    return true
                }
                let chord = ShortcutChord(event: event)
                switch AppShortcut.allCases.first(where: { self.settings().chord(for: $0) == chord }) {
                case .nextNote: self.commands.nextNote()
                case .previousNote: self.commands.previousNote()
                case .noteList: self.commands.showList()
                case .moveToTrash:
                    guard self.state().canTrash else { return false }
                    self.commands.trashActiveNote()
                default: return false
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Keep menu equivalents synchronized with configured chords and their conflicts.
    func syncShortcuts() {
        let settings = settings()
        for (command, item) in commandItems {
            let chord = settings.chord(for: command)
            item.keyEquivalent = chord.menuKeyEquivalent
            item.keyEquivalentModifierMask = chord.menuModifierMask
            item.title = commandMenuTitle(command)
            let base = item.title
            if item.keyEquivalent.isEmpty { item.title = String(localized: "\(base) (\(chord.title))", comment: "Menu item title followed by its configured shortcut in parentheses. First value is the localized menu item title, second is the shortcut such as ⌃⌥Space") }
        }
        toggleNotesMenuItem?.title = String(localized: "Toggle Notes (\((ShortcutChord(storedValue: settings.shortcut) ?? .default).title))", comment: "View menu item that shows or hides all notes. The value is the configured global shortcut, such as ⌃⌥Space")
        openLinkMenuItem?.keyEquivalent = settings.openLinkChord == nil ? "" : "\r"
        openLinkMenuItem?.keyEquivalentModifierMask = [.command, .option]
    }
    private func commandMenuTitle(_ command: AppShortcut) -> String {
        switch command {
        case .moveToTrash: String(localized: "Move to Trash…", comment: "File menu item that moves the active note's file to the Trash. Use the system term for Trash.")
        case .noteList: String(localized: "Note list", comment: "View menu item that shows the note list window")
        case .nextNote: String(localized: "Next Note", comment: "View menu item that moves focus to the next open note")
        case .previousNote: String(localized: "Previous Note", comment: "View menu item that moves focus to the previous open note")
        case .increaseFont: String(localized: "Increase Font Size", comment: "View menu item")
        case .decreaseFont: String(localized: "Decrease Font Size", comment: "View menu item")
        case .resetFont: String(localized: "Reset Font Size", comment: "View menu item that restores the default font size")
        }
    }
    @objc private func showAbout(_ sender: Any?) { NSApp.orderFrontStandardAboutPanel(sender) }
    @objc private func showHelp(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://ramnotes.com/help")!) }
    @objc private func showSettings(_ sender: Any?) { commands.showSettings() }
    @objc private func quit(_ sender: Any?) { commands.quit() }
    @objc private func searchNotes(_ sender: Any?) { commands.searchNotes() }
    @objc private func newNote(_ sender: Any?) { commands.newNote() }
    @objc private func addExistingFiles(_ sender: Any?) { commands.addExistingFiles() }
    @objc private func trashActiveNote(_ sender: Any?) { commands.trashActiveNote() }
    @objc private func changeFont(_ sender: NSMenuItem) { commands.changeFontSize(sender.tag) }
    @objc private func changeTint(_ sender: NSMenuItem) { commands.changeTint(sender) }
    @objc private func showList(_ sender: Any?) { commands.showList() }
    @objc private func nextNote(_ sender: Any?) { commands.nextNote() }
    @objc private func previousNote(_ sender: Any?) { commands.previousNote() }
    @objc private func toggleNotes(_ sender: Any?) { commands.toggleNotes() }
    @objc private func showCommands(_ sender: Any?) { commands.showCommands() }
    @objc private func nextWindow(_ sender: Any?) { cycleAppWindow(backward: false) }
    @objc private func previousWindow(_ sender: Any?) { cycleAppWindow(backward: true) }
    private func cycleAppWindow(backward: Bool) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey && !$0.isMiniaturized }
            .sorted { $0.windowNumber < $1.windowNumber }
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0 === NSApp.keyWindow } ?? 0
        let offset = backward ? candidates.count - 1 : 1
        candidates[(current + offset) % candidates.count].makeKeyAndOrderFront(nil)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let state = state()
        switch item.action {
        case #selector(newNote(_:)), #selector(addExistingFiles(_:)): return state.canAddNotes
        case #selector(trashActiveNote(_:)):
            item.title = state.selectedListNotes > 1
                ? String(localized: "Move \(state.selectedListNotes) Notes to Trash…", comment: "File menu: move several selected notes to the Trash") : "Move to Trash…"
            return state.canTrash
        case #selector(changeFont(_:)): return state.activeNoteTone != nil
        case #selector(changeTint(_:)):
            let tone = item.tag == 0 ? nil : NoteBackgroundTone.allCases[item.tag - 1]
            item.state = state.activeNoteTone == .some(tone) ? .on : .off
            return state.activeNoteTone != nil
        case #selector(nextNote(_:)), #selector(previousNote(_:)):
            return state.commandsAllowed && state.noteWindowCount > 1
        case #selector(nextWindow(_:)), #selector(previousWindow(_:)):
            return state.commandsAllowed && NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }.count > 1
        default: return state.commandsAllowed
        }
    }
}
