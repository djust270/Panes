import AppKit
import ExplorerCore

/// The row under the tabs: Back, Forward, Up and Refresh, then the breadcrumb address bar.
/// Right-clicking Back or Forward lists the history, as on Windows.
@MainActor
final class AddressBarView: NSView {
    let breadcrumbBar = BreadcrumbBarView()

    var onGoBack: ((Int) -> Void)?
    var onGoForward: ((Int) -> Void)?
    var onUp: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// Supplies fresh history menu contents right before each menu opens.
    var backList: (() -> [ExplorerLocation])?
    var forwardList: (() -> [ExplorerLocation])?
    var onNavigate: ((ExplorerLocation) -> Void)? {
        didSet { breadcrumbBar.onNavigate = onNavigate }
    }
    var onNetworkPath: ((NetworkPath) -> Void)? {
        didSet { breadcrumbBar.onNetworkPath = onNetworkPath }
    }
    var onEndEditing: (() -> Void)? {
        didSet { breadcrumbBar.onEndEditing = onEndEditing }
    }

    private let backButton = FluentButton(symbol: "arrow.left", toolTip: "Back")
    private let forwardButton = FluentButton(symbol: "arrow.right", toolTip: "Forward")
    private let upButton = FluentButton(symbol: "arrow.up", toolTip: "Up")
    private let refreshButton = FluentButton(symbol: "arrow.clockwise", toolTip: "Refresh")
    private let addressField = LayerView(color: Theme.fieldColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for (button, action) in [
            (backButton, #selector(goBack)),
            (forwardButton, #selector(goForward)),
            (upButton, #selector(goUp)),
            (refreshButton, #selector(refresh)),
        ] {
            button.target = self
            button.action = action
        }
        for button in [backButton, forwardButton] {
            let menu = NSMenu()
            menu.delegate = self
            button.menu = menu
        }

        addressField.wantsLayer = true
        addressField.layer?.cornerRadius = Theme.controlCornerRadius
        addressField.layer?.borderWidth = 1
        addressField.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        addressField.addSubview(breadcrumbBar)

        let buttons = NSStackView(views: [backButton, forwardButton, upButton, refreshButton])
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        addSubview(addressField)

        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            addressField.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 32),
            breadcrumbBar.leadingAnchor.constraint(equalTo: addressField.leadingAnchor, constant: 4),
            breadcrumbBar.trailingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: -4),
            breadcrumbBar.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
        ])
        updateTooltips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            addressField.layer?.borderColor = Theme.dividerColor.cgColor
        }
    }

    /// Shows the scheme's shortcuts in the buttons' tooltips.
    func updateTooltips() {
        backButton.toolTip = KeyboardShortcuts.toolTip("Back", .back)
        forwardButton.toolTip = KeyboardShortcuts.toolTip("Forward", .forward)
        upButton.toolTip = KeyboardShortcuts.toolTip("Up to the parent folder", .up)
        refreshButton.toolTip = KeyboardShortcuts.toolTip("Refresh", .refresh)
    }

    /// Called after every navigation to refresh enabled state and the breadcrumb.
    func update(location: ExplorerLocation, history: NavigationHistory) {
        backButton.isEnabled = history.canGoBack
        forwardButton.isEnabled = history.canGoForward
        upButton.isEnabled = location.parent != nil
        breadcrumbBar.setLocation(location)
    }

    /// Switches the breadcrumb to an editable path (Ctrl+L, Alt+D, F4).
    func beginEditing() {
        breadcrumbBar.beginEditing()
    }

    @objc private func goBack() {
        onGoBack?(1)
    }

    @objc private func goForward() {
        onGoForward?(1)
    }

    @objc private func goUp() {
        onUp?()
    }

    @objc private func refresh() {
        onRefresh?()
    }

    @objc private func historyMenuItemSelected(_ sender: NSMenuItem) {
        guard let steps = sender.representedObject as? Int else { return }
        if sender.menu === backButton.menu {
            onGoBack?(steps)
        } else if sender.menu === forwardButton.menu {
            onGoForward?(steps)
        }
    }
}

extension AddressBarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let entries: [ExplorerLocation]
        if menu === backButton.menu {
            entries = backList?() ?? []
        } else if menu === forwardButton.menu {
            entries = forwardList?() ?? []
        } else {
            return
        }

        for (index, location) in entries.enumerated() {
            let item = NSMenuItem(
                title: location.displayName,
                action: #selector(historyMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = index + 1
            menu.addItem(item)
        }
    }
}
