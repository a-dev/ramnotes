import AppKit

/// Shared builders for settings pages. It records the rows and widths that follow the interface
/// scale, so `SettingsController` can adapt every page at once.
@MainActor
final class SettingsPageLayout {
    private(set) var adaptiveRows: [NSStackView] = []
    private(set) var scaledWidths: [(NSLayoutConstraint, CGFloat)] = []
    /// Checkboxes whose long translated titles wrap inside their section.
    private var wrappingCheckboxes: [NSButton] = []

    func adaptive(_ row: NSStackView) { adaptiveRows.append(row) }
    func scaled(_ constraint: NSLayoutConstraint, base: CGFloat) {
        constraint.isActive = true
        scaledWidths.append((constraint, base))
    }
    func wraps(_ checkboxes: NSButton...) { wrappingCheckboxes += checkboxes }

    func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }
    func row(_ title: String, _ control: NSView) -> NSStackView {
        let row = NSStackView(views: [NSTextField(wrappingLabelWithString: title), NSView(), control])
        adaptive(row)
        row.spacing = 16
        if let field = control as? NSTextField, field.isEditable {
            control.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        if control is NSPopUpButton { scaled(control.widthAnchor.constraint(equalToConstant: 220), base: 220) }
        return row
    }
    func section(_ title: String, _ views: [NSView]) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        for view in (title.isEmpty ? [] : [heading]) + views {
            content.addArrangedSubview(view)
            if let checkbox = view as? NSButton, wrappingCheckboxes.contains(where: { $0 === checkbox }) {
                // Long translated checkbox titles wrap instead of clipping at the section edge.
                checkbox.lineBreakMode = .byWordWrapping
                checkbox.cell?.wraps = true
                checkbox.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32).isActive = true
            } else if !(view is NSButton) && !(view is NSProgressIndicator) {
                view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
            }
        }
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])
        return box
    }
    /// A scrolling page with a large title and its sections.
    func page(_ title: String, sections: [NSView]) -> NSScrollView {
        let stack = SettingsStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(heading)
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }
}

@MainActor
private final class SettingsStack: NSStackView {
    override var isFlipped: Bool { true }
}
