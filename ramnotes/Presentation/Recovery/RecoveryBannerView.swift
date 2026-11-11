import AppKit

/// A recovery banner action. The raw value is the stable internal key that tests and focus
/// restoration use. Only the localized title is shown to the user.
enum RecoveryBannerAction: String, CaseIterable {
    case export = "Export"
    case restoreAccess = "Restore File Access…"
    case locate = "Locate File…"
    case saveCopy = "Save a Copy…"
    case openOriginal = "Open Original"
    case openRecovery = "Open Recovery"
    case closeWithoutSaving = "Close Without Saving…"

    var title: String {
        switch self {
        case .export: String(localized: "Export", comment: "Recovery button that exports the unsaved text to a new file")
        case .restoreAccess: String(localized: "Restore File Access…", comment: "Recovery menu item that asks the user to grant access to the notes folder again")
        case .locate: String(localized: "Locate File…", comment: "Recovery menu item that lets the user pick the file that replaces a missing note")
        case .saveCopy: String(localized: "Save a Copy…", comment: "Recovery menu item that saves the text to a new file")
        case .openOriginal: String(localized: "Open Original", comment: "Recovery menu item that opens the original note file")
        case .openRecovery: String(localized: "Open Recovery", comment: "Recovery menu item that opens the recovery note")
        case .closeWithoutSaving: String(localized: "Close Without Saving…", comment: "Recovery button that closes the note and discards the text that could not be saved")
        }
    }
}

/// The save-status and recovery banner of a note window: warning icon, message, and action buttons.
/// It displays values its controller supplies and reports button presses through `actionRequested`
/// and `dismissRequested`. It never saves, deletes, or promotes notes.
@MainActor
final class RecoveryBannerView: NSStackView {
    override var isFlipped: Bool { true }
    let status = NSTextField(wrappingLabelWithString: "")
    private let warning = NSImageView()
    private let divider = NSBox()
    private let actions = RecoveryActionsView()
    private let dismissButton = NSButton(title: String(localized: "Dismiss", comment: "Button that hides the recovery warning in a note window"), target: nil, action: nil)
    /// Buttons by stable action key.
    private(set) var actionButtons: [String: NSButton] = [:]
    var actionRequested: ((RecoveryBannerAction) -> Void)?
    var dismissRequested: (() -> Void)?

    init() {
        super.init(frame: .zero)
        status.setAccessibilityLabel(String(localized: "Save status", comment: "Accessibility label of the note window's save status text"))
        status.isHidden = true
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Error", comment: "Accessibility description of the warning icon next to a save error"))
        let message = NSStackView(views: [warning, status])
        message.alignment = .top
        message.spacing = 8
        divider.boxType = .custom
        divider.borderWidth = 0
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        addArrangedSubview(divider)
        addArrangedSubview(message)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
        message.widthAnchor.constraint(equalTo: divider.widthAnchor).isActive = true
        warning.widthAnchor.constraint(equalToConstant: 16).isActive = true
        warning.heightAnchor.constraint(equalToConstant: 16).isActive = true
        for (index, action) in RecoveryBannerAction.allCases.enumerated() {
            let button = action == .closeWithoutSaving
                ? DestructiveButton(title: action.title, target: self, action: #selector(buttonPressed(_:)))
                : NSButton(title: action.title, target: self, action: #selector(buttonPressed(_:)))
            button.tag = index
            button.setAccessibilityLabel(action.title)
            button.isHidden = action != .export
            actions.addSubview(button)
            actionButtons[action.rawValue] = button
        }
        if let discard = actionButtons[RecoveryBannerAction.closeWithoutSaving.rawValue] {
            // Destructive: red, and kept apart on the trailing side.
            discard.hasDestructiveAction = true
            actions.trailing = discard
        }
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.setAccessibilityLabel(String(localized: "Dismiss", comment: "Button that hides the recovery warning in a note window"))
        dismissButton.isHidden = true
        actions.addSubview(dismissButton)
        addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: divider.widthAnchor).isActive = true
        actions.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var actionsVisible: Bool {
        get { !actions.isHidden }
        set { actions.isHidden = !newValue }
    }
    var dismissVisible: Bool {
        get { !dismissButton.isHidden }
        set { dismissButton.isHidden = !newValue }
    }
    func setAction(_ action: RecoveryBannerAction, visible: Bool) {
        actionButtons[action.rawValue]?.isHidden = !visible
        actions.actionsChanged()
    }
    func applyErrorColor(_ color: NSColor) {
        status.textColor = color
        warning.contentTintColor = color
        divider.fillColor = color
    }
    /// Re-measures the wrapped button rows, for example after a width or type-size change.
    func actionsChanged() { actions.actionsChanged() }
    /// Hides the message, actions, and Dismiss button.
    func hideAll() {
        status.isHidden = true
        isHidden = true
        actions.isHidden = true
        dismissButton.isHidden = true
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let all = RecoveryBannerAction.allCases
        guard all.indices.contains(sender.tag) else { return }
        actionRequested?(all[sender.tag])
    }
    @objc private func dismiss() { dismissRequested?() }
}
