import AppKit

/// The About page: app identity, links, optional update controls, and the copyright line.
@MainActor
enum AboutSettingsPage {
    static func make(version: String, copyright: String, updateControls: NSView?, layout: SettingsPageLayout) -> NSView {
        layout.page(String(localized: "About", comment: "Settings category and page title"), sections: [layout.section("", [
            header(version: version),
            layout.caption(String(localized: "A simple place for plain-text notes. Keep notes in a folder you choose, open them in separate windows, and bring them back with a global shortcut or a menu bar gesture.", comment: "About page description")),
            links(layout)] + (updateControls.map { [$0] } ?? []) + [copyrightLine(copyright)])])
    }

    private static func header(version: String) -> NSStackView {
        // AboutIcon has flat light and dark renders of AppIcon.icon. applicationIconName shows a
        // placeholder grid until Icon Services renders it, and it has no dark variant.
        let image = NSImage(named: "AboutIcon") ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(String(localized: "RAMnotes app icon", comment: "Accessibility label for the app icon on the About page. Keep the product name RAMnotes unchanged."))
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "RAMnotes")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let text = NSStackView(views: [name, NSTextField(labelWithString: String(localized: "Version \(version)", comment: "About page. The value is the app version number, such as 1.4"))])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let header = NSStackView(views: [icon, text])
        header.spacing = 12
        header.alignment = .centerY
        return header
    }
    private static func links(_ layout: SettingsPageLayout) -> NSStackView {
        let links = [("ramnotes.com", "https://ramnotes.com"), (String(localized: "Privacy Policy", comment: "About page link title"), "https://ramnotes.com/privacy"),
                     (String(localized: "Support", comment: "About page link title"), "https://ramnotes.com/support")].map(link)
        let stack = NSStackView(views: links)
        stack.spacing = 16
        layout.adaptive(stack)
        return stack
    }
    private static func copyrightLine(_ copyright: String) -> NSStackView {
        // The bundle string ends with the author's name, which links to their GitHub profile.
        let author = "a-dev"
        let prefix = copyright.hasSuffix(author) ? String(copyright.dropLast(author.count)) : copyright + " "
        let label = NSTextField(labelWithString: prefix)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        let name = link(author, "https://github.com/a-dev")
        name.font = label.font
        let line = NSStackView(views: [label, name])
        line.spacing = 0
        line.alignment = .firstBaseline
        return line
    }
    private static func link(_ title: String, _ address: String) -> NSButton {
        let url = URL(string: address)!
        let button = ActionButton(title) { NSWorkspace.shared.open(url) }
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.toolTip = address
        return button
    }
}
