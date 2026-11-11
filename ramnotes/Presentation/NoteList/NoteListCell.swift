import ramnotesDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers


/// Built once and reused. A 1,000-row list must not rebuild its views on each reload.
@MainActor
final class NoteListCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("NoteListCell")
    fileprivate let toneIndicator = NoteListToneIndicator()
    fileprivate let preview = NoteListLabel(wrappingLabelWithString: "")
    fileprivate let date = NoteListLabel(labelWithString: "")
    private let rowView = NSStackView()
    private let warning = NoteListWarningIcon()
    /// A problem that belongs to this note, shown on the line below its title.
    let issue = NSTextField(labelWithString: "")
    private let titleLine = NSStackView()
    private let titleBlock = NSStackView()
    private var footer: NSStackView!
    private let actionsButton = NoteListActionsButton(title: String(localized: "Actions…", comment: "Button in a note row that has a problem. Opens the same menu as right-clicking the row"), target: nil, action: nil)
    private var showActions: ((NSView) -> Void)?
    private let locationButton = LocationButton("") {}
    private var scale: CGFloat = 1
    private var previewHeightConstraint: NSLayoutConstraint!
    private var titleHeightConstraint: NSLayoutConstraint!
    static let issueGap: CGFloat = 6
    static func titleLineHeight(scale: CGFloat) -> CGFloat { NSFont.systemFont(ofSize: 13 * scale).boundingRectForFont.height }
    static func issueLineHeight(scale: CGFloat) -> CGFloat { NSFont.systemFont(ofSize: 12 * scale).boundingRectForFont.height }
    /// Room for a two-line title, or a one-line title, a gap, and a problem line, whichever is taller.
    static func titleBlockHeight(scale: CGFloat) -> CGFloat {
        let title = titleLineHeight(scale: scale)
        return max(2 * title + 4, title + 4 + issueGap + issueLineHeight(scale: scale))
    }
    private var trailingPaddingConstraint: NSLayoutConstraint!
    private let text = NSStackView()
    private var defaultLocationWidth: NSLayoutConstraint!
    private(set) var opened = false
    private var trashed = false

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        preview.maximumNumberOfLines = 2
        preview.cell?.wraps = true
        preview.cell?.usesSingleLineMode = false
        preview.lineBreakMode = .byTruncatingTail
        // Keep the default truncating style. A character-wrap style clips the second line
        // instead of drawing an ellipsis.
        preview.font = .systemFont(ofSize: 13)
        date.font = .systemFont(ofSize: 11)
        date.textColor = NoteTonePalette.readable(.secondaryLabelColor, on: .controlBackgroundColor)
        toneIndicator.setAccessibilityElement(false)
        toneIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
        toneIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true
        // The spacer yields first, so the path keeps every point it needs before it truncates.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [date, locationButton, spacer, toneIndicator, actionsButton])
        actionsButton.bezelStyle = .rounded
        actionsButton.controlSize = .small
        actionsButton.target = self
        actionsButton.action = #selector(showActionsMenu)
        // With the custom cell, AppKit exposed no button role and hit-tested past the button,
        // so VoiceOver and UI tests could not press it. Mark it as a button explicitly.
        actionsButton.setAccessibilityElement(true)
        actionsButton.setAccessibilityRole(.button)
        actionsButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        actionsButton.isHidden = true
        self.footer = footer
        footer.distribution = .fill
        footer.alignment = .centerY
        footer.spacing = 10
        // Truncate the path before the date.
        date.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        date.lineBreakMode = .byTruncatingTail
        let locationTarget = locationButton.target
        let locationAction = locationButton.action
        locationButton.cell = LocationButtonCell(textCell: "")
        locationButton.target = locationTarget
        locationButton.action = locationAction
        locationButton.setButtonType(.momentaryPushIn)
        locationButton.setAccessibilityElement(true)
        locationButton.setAccessibilityRole(.button)
        locationButton.bezelStyle = .rounded
        locationButton.isBordered = true
        locationButton.showsBorderOnlyWhileMouseInside = true
        locationButton.alignment = .natural
        locationButton.font = .systemFont(ofSize: 11)
        locationButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        locationButton.imagePosition = .imageLeading
        locationButton.cell?.lineBreakMode = .byTruncatingMiddle
        locationButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        defaultLocationWidth = locationButton.widthAnchor.constraint(equalToConstant: 32)
        issue.font = .systemFont(ofSize: 12)
        issue.textColor = NoteTonePalette.readable(.systemRed, on: .controlBackgroundColor)
        issue.lineBreakMode = .byTruncatingTail
        issue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        issue.isHidden = true
        // The warning sits on the title line, so the metadata row starts at the card's leading edge.
        titleLine.orientation = .horizontal
        titleLine.alignment = .top
        titleLine.spacing = 10
        titleLine.addArrangedSubview(preview)
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = Self.issueGap
        for child in [titleLine, issue] { titleBlock.addArrangedSubview(child) }
        for child in [titleBlock, footer] { text.addArrangedSubview(child) }
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "File unavailable")
        warning.contentTintColor = NoteTonePalette.readable(.systemRed, on: .controlBackgroundColor)
        warning.widthAnchor.constraint(equalToConstant: 16).isActive = true
        warning.heightAnchor.constraint(equalToConstant: 16).isActive = true
        rowView.addArrangedSubview(text)
        rowView.distribution = .fill
        rowView.alignment = .top
        rowView.spacing = 10
        rowView.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in [preview, date] {
            label.setAccessibilityElement(true)
            label.setAccessibilityRole(.staticText)
        }
        setAccessibilityChildren([preview, date])
        rowView.translatesAutoresizingMaskIntoConstraints = false
        previewHeightConstraint = titleBlock.heightAnchor.constraint(equalToConstant: Self.titleBlockHeight(scale: 1))
        // The title keeps two lines unless a problem takes the second one.
        titleHeightConstraint = preview.heightAnchor.constraint(equalToConstant: 2 * Self.titleLineHeight(scale: 1) + 4)
        addSubview(rowView)
        trailingPaddingConstraint = rowView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            titleLine.widthAnchor.constraint(equalTo: text.widthAnchor),
            issue.widthAnchor.constraint(equalTo: text.widthAnchor),
            footer.widthAnchor.constraint(equalTo: text.widthAnchor),
            previewHeightConstraint, titleHeightConstraint,
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            trailingPaddingConstraint,
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        trailingPaddingConstraint.constant = -noteCardTrailingPadding
        super.layout()
        alignLocationWithTitle()
    }

    @objc private func showActionsMenu() { showActions?(actionsButton) }

    /// When the date is hidden, align the folder icon with the card's leading content edge.
    /// Subtract the button's padding.
    private func alignLocationWithTitle() {
        var shift: CGFloat = 0
        if date.isHidden, let cell = locationButton.cell, locationButton.bounds.width > 0 {
            let image = cell.imageRect(forBounds: locationButton.bounds.insetBy(dx: 8, dy: 2))
            // The button's alignment rect leads the footer content, so this does not depend on the current shift.
            shift = -(image.minX - locationButton.bounds.minX - locationButton.alignmentRectInsets.left)
        }
        guard shift.isFinite, abs(footer.edgeInsets.left - shift) > 0.5 else { return }
        footer.edgeInsets.left = shift
        needsLayout = true
    }

    func configure(excerpt: String, updated: String, opened: Bool, tone: NoteBackgroundTone?,
                   unavailableDetail: String?, issue issueText: String? = nil, trashed: Bool = false, failureTitle: String = String(localized: "File unavailable…", comment: "Row title for a note whose file cannot be used"), path: String, locationTitle: String,
                   locationAction: @escaping () -> Void, actions: ((NSView) -> Void)? = nil) {
        self.trashed = trashed
        showActions = actions
        let customLocation = locationTitle != "default"
        let unavailable = unavailableDetail != nil
        if unavailable, warning.superview == nil { titleLine.insertArrangedSubview(warning, at: 0) }
        if !unavailable, warning.superview != nil {
            titleLine.removeArrangedSubview(warning)
            warning.removeFromSuperview()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        locationButton.attributedTitle = NSAttributedString(string: customLocation ? locationTitle : "", attributes: [
            .font: NSFont.systemFont(ofSize: 11 * scale),
            .foregroundColor: unavailable ? NoteTonePalette.readable(.systemRed, on: .controlBackgroundColor) : NoteTonePalette.readable(.secondaryLabelColor, on: .controlBackgroundColor),
            .paragraphStyle: paragraph
        ])
        defaultLocationWidth.isActive = !customLocation
        locationButton.imagePosition = customLocation ? .imageLeading : .imageOnly
        locationButton.alignment = customLocation ? .natural : .center
        locationButton.invalidateIntrinsicContentSize()
        locationButton.needsDisplay = true
        locationButton.configureTint(customLocation: customLocation, unavailable: unavailable)
        locationButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        locationButton.toolTip = path
        locationButton.setAccessibilityLabel(String(localized: "Change note location: \(PathIsolation.isolate(path))", comment: "Accessibility label of the location button in a note row. The value is a file path"))
        locationButton.onAction = locationAction
        let title = trashed ? failureTitle : unavailable ? failureTitle + (excerpt == NoteSnapshot.emptyPreview || issueText != nil ? "" : "\n" + excerpt) : excerpt
        preview.stringValue = title
        // A problem takes the second line: the title keeps one line.
        preview.maximumNumberOfLines = issueText == nil ? 2 : 1
        issue.stringValue = issueText ?? ""
        issue.isHidden = issueText == nil
        titleHeightConstraint.constant = CGFloat(preview.maximumNumberOfLines) * Self.titleLineHeight(scale: scale) + 4
        issue.setAccessibilityLabel(issueText)
        preview.setAccessibilityLabel(title)
        date.stringValue = updated
        date.isHidden = updated.isEmpty
        date.setAccessibilityLabel(String(localized: "Last updated: \(updated)", comment: "Accessibility label of the date in a note row. The value is a formatted date and time"))
        apply(opened: opened, tone: tone)
        rowView.toolTip = unavailableDetail
        let problem = unavailable || trashed
        actionsButton.isHidden = !problem || actions == nil
        actionsButton.font = .systemFont(ofSize: 11 * scale)
        let titleChildren: [NSView] = (unavailable ? [warning, preview] : [preview]) + (issueText == nil ? [] : [issue])
        setAccessibilityChildren(titleChildren + (problem ? [date, locationButton, actionsButton] : [date, locationButton]))
    }

    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        preview.font = .systemFont(ofSize: 13 * scale)
        date.font = .systemFont(ofSize: 11 * scale)
        locationButton.font = .systemFont(ofSize: 11 * scale)
        issue.font = .systemFont(ofSize: 12 * scale)
        previewHeightConstraint.constant = Self.titleBlockHeight(scale: scale)
        titleHeightConstraint.constant = CGFloat(preview.maximumNumberOfLines) * Self.titleLineHeight(scale: scale) + 4
        if locationButton.attributedTitle.length > 0 {
            let title = NSMutableAttributedString(attributedString: locationButton.attributedTitle)
            title.addAttribute(.font, value: NSFont.systemFont(ofSize: 11 * scale), range: NSRange(location: 0, length: title.length))
            locationButton.attributedTitle = title
        }
        needsLayout = true
    }

    func apply(opened: Bool, tone: NoteBackgroundTone?) {
        self.opened = opened
        preview.textColor = NoteTonePalette.readable(trashed ? .systemRed : opened ? .controlAccentColor : .labelColor, on: .controlBackgroundColor)
        toneIndicator.image = tone.map { NoteTonePalette.image($0) }
        toneIndicator.isHidden = tone == nil
        let tintName = NoteBackgroundTone.localizedName(tone)
        let tintDescription = String(localized: "Background tint: \(tintName)", comment: "VoiceOver description of a note row's tint; value is the color name")
        setAccessibilityHelp(tintDescription)
        preview.setAccessibilityHelp(opened
            ? String(localized: "Open note. Background tint: \(tintName)", comment: "VoiceOver help of an open note row; value is the tint color name")
            : String(localized: "Closed note. Background tint: \(tintName)", comment: "VoiceOver help of a closed note row; value is the tint color name"))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            preview.textColor = NoteTonePalette.readable(trashed ? .systemRed : opened ? .controlAccentColor : .labelColor, on: .controlBackgroundColor)
            date.textColor = NoteTonePalette.readable(.secondaryLabelColor, on: .controlBackgroundColor)
        }
    }
}

@MainActor
private final class NoteListLabel: NSTextField {
    private static let paragraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }()
    private var cached: (key: [AnyHashable], excerpt: NSAttributedString)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cached = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = font ?? NSFont.systemFont(ofSize: 13), color = textColor ?? NSColor.labelColor
        let key: [AnyHashable] = [stringValue, font, color]
        let excerpt: NSAttributedString
        if let cached, cached.key == key { excerpt = cached.excerpt } else {
            excerpt = NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: Self.paragraph])
            cached = (key, excerpt)
        }
        excerpt.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
extension NSView {
    var noteCardTrailingPadding: CGFloat {
        guard let scroll = enclosingScrollView, scroll.scrollerStyle == .legacy,
              let scroller = scroll.verticalScroller, !scroller.isHidden else { return 12 }
        return max(0, 12 - scroller.frame.width)
    }
}

@MainActor
private final class LocationButton: ActionButton {
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private var customLocation = false
    private var unavailable = false

    // NSButton subtracts the rounded bezel's alignment insets from cellSize, but this cell
    // draws its own padding inside the frame, so the full cellSize width is needed.
    override var intrinsicContentSize: NSSize {
        NSSize(width: cell?.cellSize.width ?? super.intrinsicContentSize.width, height: super.intrinsicContentSize.height)
    }

    func configureTint(customLocation: Bool, unavailable: Bool) {
        self.customLocation = customLocation
        self.unavailable = unavailable
        updateTint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        isHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateTint()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateTint()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateTint()
    }

    private func updateTint() {
        if unavailable {
            contentTintColor = NoteTonePalette.readable(.systemRed, on: .controlBackgroundColor)
        } else if customLocation || isHovered {
            contentTintColor = NoteTonePalette.readable(.systemBlue, on: .controlBackgroundColor)
        } else {
            contentTintColor = .tertiaryLabelColor
        }
    }
}

/// The red unavailable-file icon. Selected rows ask for the emphasized style, which draws symbols white.
@MainActor
final class NoteListWarningIcon: NSImageView {
    override class var cellClass: AnyClass? {
        get { NormalStyleImageCell.self }
        set {}
    }
}

/// The Actions… button. A selected row asks for the emphasized style, which draws the title white on the light card.
@MainActor
final class NoteListActionsButton: NSButton {
    override class var cellClass: AnyClass? {
        get { NormalStyleButtonCell.self }
        set {}
    }
}

private final class NormalStyleButtonCell: NSButtonCell {
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }
}

/// Ignores the selected row's emphasized style so the tint color still applies.
private final class NormalStyleImageCell: NSImageCell {
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }
}

/// Keep metadata colors independent of AppKit's emphasized selection text style.
@MainActor
private final class LocationButtonCell: NSButtonCell {
    override var cellSize: NSSize {
        var size = super.cellSize
        size.height += 4
        size.width += 16 + (imagePosition == .imageLeading ? 4 : 0)
        return size
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 2),
                   in: controlView)
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect,
                            in controlView: NSView) -> NSRect {
        let gap: CGFloat = imagePosition == .imageLeading ? 4 : 0
        let height = title.size().height
        let centeredFrame = NSRect(x: frame.minX + gap,
                                   y: controlView.bounds.midY - height / 2,
                                   width: frame.width, height: height) // cellSize already reserves the gap
        // Use draw(in:) for middle truncation. The default draws a truncated tail.
        title.draw(in: centeredFrame)
        return centeredFrame
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }
}

/// Shifts the swatch to line up with the visible text in the metadata row.
@MainActor
private final class NoteListToneIndicator: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = bounds.offsetBy(dx: 0, dy: isFlipped ? 1 : -1)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}
