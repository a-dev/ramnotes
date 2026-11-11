import AppKit
import UniformTypeIdentifiers

@MainActor
final class RecoveryWindowController: NSWindowController {
    let textView = PlainTextView()
    let status = NSTextField(wrappingLabelWithString: "")
    let exportButton = NSButton(title: String(localized: "Export", comment: "Button that exports recovered text to a new file"), target: nil, action: nil)

    private let record: RetainedEditSummary
    private let exporter: (any RecoveryTextExporting)?
    let announcements = AccessibilityAnnouncements()
    private var exportMessage: String?
    private var typography = AppSettings()
    private var fontSizeOverride: Double?

    init(record: RetainedEditSummary, backgroundTone: NoteBackgroundTone? = nil, settings: AppSettings = AppSettings(), fontSize: Double? = nil,
         exporter: (any RecoveryTextExporting)? = nil) {
        self.exporter = exporter
        self.record = record
        typography = EditorTypography.normalized(settings)
        fontSizeOverride = fontSize.flatMap { $0.isFinite ? min(192, max(8, $0)) : nil }
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = String(localized: "Recovery — \(record.originalURL.lastPathComponent)", comment: "Title of the recovery viewer window. The value is the original file name")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 375, height: 260)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.string = record.text
        textView.setAccessibilityLabel(String(localized: "Recovery text", comment: "Accessibility label of the recovered text view"))
        applyTypography(preservingViewport: false)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        let surface = NoteTonePalette.surface(backgroundTone)
        window.backgroundColor = surface
        textView.backgroundColor = surface
        textView.textColor = NoteTonePalette.readable(.textColor, on: surface)
        textView.insertionPointColor = NoteTonePalette.readable(.textColor, on: surface)
        scrollView.backgroundColor = surface
        scrollView.contentView.backgroundColor = surface

        exportButton.target = self
        exportButton.action = #selector(exportRecovery)
        exportButton.setAccessibilityLabel(String(localized: "Export", comment: "Button that exports recovered text to a new file"))
        exportButton.bezelColor = .controlAccentColor
        exportButton.keyEquivalent = "\r"
        status.setAccessibilityLabel(String(localized: "Recovery status", comment: "Accessibility label of the recovery viewer status text"))
        status.stringValue = statusText()

        // Text fills the window. The footer holds Export on the leading side and, 12 pt
        // below it, the explanation.
        let footer = NSStackView(views: [exportButton, status])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        let root = NSStackView(views: [scrollView, footer])
        root.orientation = .vertical
        root.spacing = 0
        window.contentView = root
        InterfaceTypography.apply(to: root, scale: 1.0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            status.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -32),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        window.initialFirstResponder = textView
        window.recalculateKeyViewLoop()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ settings: AppSettings) {
        let normalized = EditorTypography.normalized(settings)
        if normalized.fontSize != typography.fontSize { fontSizeOverride = nil }
        typography = normalized
        applyTypography()
        if let content = window?.contentView {
            InterfaceTypography.apply(to: content, scale: 1.0)
        }
    }

    private func applyTypography(preservingViewport: Bool = true) {
        let origin = (textView.enclosingScrollView as? NSScrollView)?.contentView.bounds.origin
        let selection = textView.selectedRanges
        var settings = typography
        if let fontSizeOverride {
            settings.lineHeight = typography.lineHeight * fontSizeOverride / typography.fontSize
            settings.fontSize = fontSizeOverride
        }
        let font = EditorTypography.font(for: settings)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(settings.lineHeight, font.pointSize)
        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: textView.textColor ?? NSColor.textColor]
        guard preservingViewport else { return }
        textView.selectedRanges = selection
        if let origin, let scrollView = textView.enclosingScrollView {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// The viewer's status text. `progress` replaces the last export result while an export runs.
    private func statusText(progress: String? = nil) -> String {
        let path = PathIsolation.isolate(NoteLocationPresentation.path(record.originalURL))
        guard let tail = progress ?? exportMessage else {
            return String(localized: "The original note is at \(path). This window keeps text loaded from the local recovery journal.", comment: "Status text of the recovery viewer window. The value is the file path of the original note")
        }
        return String(localized: "The original note is at \(path). This window keeps text loaded from the local recovery journal. \(tail)", comment: "Status text of the recovery viewer window with an export result. First value is the file path of the original note, second is the export status sentence")
    }

    @objc private func exportRecovery() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let base = record.originalURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = String(localized: "\(base) Recovery", comment: "Suggested filename for an exported recovery; value is the original name without extension") + ".txt"
        panel.message = String(localized: "Export a verified UTF-8 copy. Export leaves the original note and recovery record unchanged.", comment: "Message in the save panel for exporting recovered text. Keep UTF-8 unchanged")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    func export(to url: URL) {
        let data = Data(record.text.utf8)
        status.stringValue = statusText(progress: String(localized: "Exporting…", comment: "Recovery viewer status while a verified export is running"))
        // The task keeps this window alive until the export is verified, even if its owner
        // is released. No callback holds that owner.
        Task { [self] in
            do {
                guard let exporter else { throw NoteOperationError.unavailable }
                try await exporter.exportRecoveryText(data, to: url)
                self.announcements.update(nil, for: "export")
                self.exportMessage = String(localized: "Exported and verified at \(PathIsolation.isolate(NoteLocationPresentation.path(url))).", comment: "Recovery viewer status after a successful export. The value is the file path of the export")
                self.status.stringValue = self.statusText()
            } catch {
                self.exportMessage = String(localized: "Export failed: \(error.localizedDescription). The text remains available in this window.", comment: "Recovery viewer status after a failed export. The value is the system error")
                self.status.stringValue = self.statusText()
                self.announcements.update(self.exportMessage, for: "export")
            }
        }
    }
}
