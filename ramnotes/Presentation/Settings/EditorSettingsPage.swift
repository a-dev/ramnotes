import AppKit

/// Validated editor typography from the Appearance page's fields.
struct EditorTypographyEdit: Equatable {
    var fontFamily: String
    var fontWeight: String
    var fontSize: Double
    var lineHeight: Double
}

/// Appearance settings: editor typography and color theme. It displays values, validates the
/// numeric fields, and emits edits. `SettingsCoordinator` owns the accepted settings.
@MainActor
final class EditorSettingsPage: NSObject, NSTextFieldDelegate {
    private let family = NSPopUpButton()
    private let weight = NSPopUpButton()
    private let size = NSTextField()
    private let height = NSTextField()
    private let sizeStepper = NSStepper()
    private let heightStepper = NSStepper()
    private let theme = NSPopUpButton()
    let error = NSTextField(wrappingLabelWithString: "")
    private var systemFontRow: NSView!
    /// The family whose weights the weight pop-up lists, and the last accepted font size.
    private var listedFamily: String
    private var acceptedFontSize: Double
    private(set) var view: NSView!

    var typographyChanged: ((EditorTypographyEdit) -> Void)?
    var appearanceChanged: ((AppearancePreference) -> Void)?

    init(settings: AppSettings, layout: SettingsPageLayout) {
        listedFamily = settings.fontFamily
        acceptedFontSize = settings.fontSize
        super.init()
        family.setRawItems(["System"] + NSFontManager.shared.availableFontFamilies.sorted(), title: EditorTypography.familyTitle)
        for item in family.itemArray {
            let previewFont = (item.representedObject as? String) == "System" ? nil : NSFontManager.shared.font(
                withFamily: item.title, traits: [], weight: 5, size: 16
            )
            item.attributedTitle = NSAttributedString(
                string: item.title, attributes: [.font: previewFont ?? NSFont.systemFont(ofSize: 16)]
            )
        }
        // Hide System from the list. Code can still select it, and the button below does.
        family.rawItem("System")?.isHidden = true
        family.usesItemFromMenu = false
        for (control, label) in [(family as NSControl, String(localized: "Font family", comment: "Settings label and accessibility label for the font family pop-up")), (weight as NSControl, String(localized: "Font weight", comment: "Settings label and accessibility label for the font weight pop-up")), (size as NSControl, String(localized: "Font size", comment: "Settings label and accessibility label for the font size field")), (height as NSControl, String(localized: "Line spacing", comment: "Settings label and accessibility label for the line height field"))] {
            control.setAccessibilityLabel(label)
            control.target = self; control.action = #selector(update)
        }
        error.setAccessibilityIdentifier("Typography validation")
        error.isHidden = true
        size.delegate = self; height.delegate = self
        theme.addItems(withTitles: [
            String(localized: "System", comment: "Settings appearance choice that follows the macOS light or dark setting"),
            String(localized: "Light", comment: "Settings appearance choice: light mode"),
            String(localized: "Dark", comment: "Settings appearance choice: dark mode")])
        theme.target = self
        theme.action = #selector(changeTheme)
        theme.setAccessibilityLabel(String(localized: "Color theme", comment: "Accessibility label for the appearance pop-up"))
        let systemFontRow = NSStackView(views: [NSView(), ActionButton(String(localized: "Use system font", comment: "Settings button that switches the editor to the system font")) { [weak self] in self?.useSystemFont() }])
        self.systemFontRow = systemFontRow
        show(settings)
        view = layout.page(String(localized: "Appearance", comment: "Settings category and page title"), sections: [
            layout.section(String(localized: "Font", comment: "Settings section title"), [
                layout.row(String(localized: "Font family", comment: "Settings label and accessibility label for the font family pop-up"), family),
                systemFontRow,
                layout.row(String(localized: "Font weight", comment: "Settings label and accessibility label for the font weight pop-up"), weight),
                layout.row(String(localized: "Font size", comment: "Settings label and accessibility label for the font size field"), numericControl(size, stepper: sizeStepper, label: String(localized: "Font size", comment: "Settings label and accessibility label for the font size field"), layout: layout)),
                layout.row(String(localized: "Line spacing", comment: "Settings label and accessibility label for the line height field"), numericControl(height, stepper: heightStepper, label: String(localized: "Line spacing", comment: "Settings label and accessibility label for the line height field"), layout: layout)),
                error]),
            layout.section(String(localized: "Color Theme", comment: "Settings section title"), [layout.row(String(localized: "Appearance", comment: "Settings category and page title"), theme)])])
    }

    /// Displays accepted settings. Call with normalized typography.
    func show(_ settings: AppSettings) {
        listedFamily = settings.fontFamily
        acceptedFontSize = settings.fontSize
        theme.selectItem(at: AppearancePreference.allValues.firstIndex(of: settings.appearance) ?? 0)
        family.selectRawValue(settings.fontFamily)
        syncFontFamilyTitle()
        weight.setRawItems(EditorTypography.weights(for: settings.fontFamily)) { EditorTypography.weightTitle($0, family: settings.fontFamily) }
        weight.selectRawValue(settings.fontWeight)
        size.stringValue = Self.format(settings.fontSize)
        height.stringValue = Self.format(settings.lineHeight)
        syncSteppers(lineHeight: settings.lineHeight)
    }

    private static func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0)).grouping(.never)) }

    private func numericControl(_ field: NSTextField, stepper: NSStepper, label: String, layout: SettingsPageLayout) -> NSView {
        // Numbers align to the trailing edge, which is the left edge in right-to-left layouts.
        field.alignment = NSApp.userInterfaceLayoutDirection == .rightToLeft ? .left : .right
        layout.scaled(field.widthAnchor.constraint(equalToConstant: 64), base: 64)
        stepper.controlSize = .small
        stepper.minValue = field === size ? 8 : acceptedFontSize
        stepper.maxValue = field === size ? 192 : 384
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.doubleValue = field.doubleValue
        stepper.target = self
        stepper.action = #selector(stepTypography(_:))
        stepper.setAccessibilityLabel(label)
        let unit = NSTextField(labelWithString: String(localized: "pt", comment: "Unit after the font size field: abbreviation for points"))
        unit.textColor = .secondaryLabelColor
        let control = NSStackView(views: [field, stepper, unit])
        control.alignment = .centerY
        control.spacing = 4
        return control
    }
    private func syncSteppers(lineHeight: Double) {
        sizeStepper.doubleValue = acceptedFontSize
        heightStepper.minValue = acceptedFontSize
        heightStepper.doubleValue = lineHeight
    }
    @objc private func stepTypography(_ sender: NSStepper) {
        // Commit any typed value before applying the stepper's selected value.
        let value = sender.doubleValue
        sender.window?.makeFirstResponder(sender)
        if sender === sizeStepper {
            size.stringValue = Self.format(value)
            if let spacing = TypographyNumber.parse(height.stringValue), spacing < value { height.stringValue = Self.format(value) }
        } else {
            height.stringValue = Self.format(value)
        }
        update()
    }
    private func syncFontFamilyTitle() {
        // A separate display item keeps the preview fonts out of the closed pop-up.
        let systemTitle = String(localized: "System font", comment: "Closed font family pop-up title when the system font is chosen")
        (family.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(
            title: family.selectedRawValue.map { $0 == "System" ? systemTitle : $0 } ?? systemTitle,
            action: nil, keyEquivalent: ""
        )
        systemFontRow?.isHidden = family.selectedRawValue == "System"
    }
    private func useSystemFont() {
        family.selectRawValue("System")
        update()
    }
    @objc private func changeTheme() { appearanceChanged?(AppearancePreference.allValues[theme.indexOfSelectedItem]) }
    @objc private func update() {
        syncFontFamilyTitle()
        guard let fontSize = TypographyNumber.parse(size.stringValue), fontSize.isFinite, (8...192).contains(fontSize),
              let lineHeight = TypographyNumber.parse(height.stringValue), lineHeight.isFinite, (fontSize...384).contains(lineHeight) else {
            error.stringValue = String(localized: "Font size must be 8–192 points. Line spacing must be at least the font size and at most 384 points.", comment: "Validation error under the typography fields")
            error.isHidden = false
            return
        }
        let selectedFamily = family.selectedRawValue ?? "System"
        if selectedFamily != listedFamily {
            weight.setRawItems(EditorTypography.weights(for: selectedFamily)) { EditorTypography.weightTitle($0, family: selectedFamily) }
            listedFamily = selectedFamily
        }
        acceptedFontSize = fontSize
        syncSteppers(lineHeight: lineHeight)
        error.stringValue = ""
        error.isHidden = true
        typographyChanged?(EditorTypographyEdit(fontFamily: selectedFamily, fontWeight: weight.selectedRawValue ?? "Regular", fontSize: fontSize, lineHeight: lineHeight))
    }
    func controlTextDidEndEditing(_ obj: Notification) { update() }
}
