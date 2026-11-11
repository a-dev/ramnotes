import AppKit

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var windows: [NSWindow] = []
    private var editors: [NSTextView] = []
    private let sampleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ramnotes-native-probe-samples", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let startHidden = ProcessInfo.processInfo.arguments.contains("--hidden")
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Simulate External Reload", action: #selector(simulateReload(_:)), keyEquivalent: "r")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit NativeProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        spellingMenu.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSTextView.showGuessPanel(_:)), keyEquivalent: ":")
        spellingMenu.addItem(withTitle: "Check Document Now", action: #selector(NSTextView.checkSpelling(_:)), keyEquivalent: ";")
        spellingMenu.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spellingMenu.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu

        for index in 0..<10 {
            let width = CGFloat(320 + index * 25)
            let height = CGFloat(220 + index * 18)
            let origin = NSPoint(x: CGFloat(80 + index * 28), y: CGFloat(130 + index * 18))
            let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "NativeProbe \(index + 1)"
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else {
                fatalError("NSTextView.scrollableTextView did not provide a text view")
            }
            textView.isRichText = false
            textView.allowsUndo = true
            textView.font = NSFont.systemFont(ofSize: 20)
            textView.delegate = self
            textView.string = "Native plain-text probe \(index + 1)\nTry paste, undo, spelling, grammar, Services, and Command-click: https://example.com\n"
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let range = NSRange(location: 0, length: (textView.string as NSString).length)
                for match in detector.matches(in: textView.string, range: range) {
                    if let url = match.url {
                        textView.textStorage?.addAttribute(.link, value: url, range: match.range)
                    }
                }
            }
            textView.isContinuousSpellCheckingEnabled = true
            textView.isGrammarCheckingEnabled = true
            textView.isAutomaticLinkDetectionEnabled = true
            window.contentView = scrollView
            if !startHidden { window.makeKeyAndOrderFront(nil) }
            windows.append(window)
            editors.append(textView)
            persistSample(for: textView)
        }
        if !startHidden { NSApp.activate(ignoringOtherApps: true) }
    }

    private var frontEditor: NSTextView? {
        guard let index = windows.firstIndex(where: { $0 == NSApp.keyWindow }) else { return nil }
        return editors[index]
    }

    private func persistSample(for editor: NSTextView) {
        guard !editor.hasMarkedText(), !editor.isWritingToolsActive,
              let index = editors.firstIndex(of: editor) else { return }
        let url = sampleDirectory.appendingPathComponent("window-\(index + 1).txt")
        do {
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
            try Data(editor.string.utf8).write(to: url, options: .atomic)
            NSLog("NativeProbe autosaved UTF-8 sample: %@", url.path)
        } catch {
            NSLog("NativeProbe sample write failed: %@", String(describing: error))
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView else { return }
        persistSample(for: editor)
    }

    @objc private func simulateReload(_ sender: Any?) {
        guard let editor = frontEditor else { return }
        // A real store must defer replacement during composition and Writing Tools.
        // This action makes the marked-text condition observable without discarding input.
        let hasMarkedText = editor.hasMarkedText()
        let writingToolsActive = editor.isWritingToolsActive
        NSLog("NativeProbe reload requested; markedText=%@; writingToolsActive=%@; selectedRange=%@", String(hasMarkedText), String(writingToolsActive), NSStringFromRange(editor.selectedRange()))
        if hasMarkedText || writingToolsActive {
            NSSound.beep()
            return
        }
        let selection = editor.selectedRange()
        editor.string = editor.string + "\n[External reload simulated]\n"
        editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0))
    }

    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        NSLog("NativeProbe Writing Tools began")
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        NSLog("NativeProbe Writing Tools ended")
        persistSample(for: textView)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = ProbeDelegate()
application.delegate = delegate
application.run()
