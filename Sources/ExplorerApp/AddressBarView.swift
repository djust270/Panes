import AppKit
import ExplorerCore

/// The row under the tabs: Back, Forward, Up and Refresh, the breadcrumb address bar, and the
/// search box. Right-clicking Back or Forward lists the history, as on Windows.
@MainActor
final class AddressBarView: NSView, StyleObserving {
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
    /// The search text changed as the user typed.
    var onSearchChange: ((String) -> Void)?
    /// Return in the search box.
    var onSearchSubmit: ((String) -> Void)?
    /// Escape, or the search box was cleared.
    var onSearchCancel: (() -> Void)?
    /// ↓ in the search box: on to the results.
    var onSearchMoveDown: (() -> Void)?

    private let backButton = FluentButton(symbol: "arrow.left", toolTip: "Back")
    private let forwardButton = FluentButton(symbol: "arrow.right", toolTip: "Forward")
    private let upButton = FluentButton(symbol: "arrow.up", toolTip: "Up")
    private let refreshButton = FluentButton(symbol: "arrow.clockwise", toolTip: "Refresh")
    private let addressField = LayerView(color: Theme.fieldColor)
    private let searchBox = LayerView(color: Theme.fieldColor)
    private let searchField = SearchField()
    private var fieldHeights: [NSLayoutConstraint] = []

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

        for box in [addressField, searchBox] {
            box.wantsLayer = true
            box.translatesAutoresizingMaskIntoConstraints = false
        }
        configureSearchField()
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        addressField.addSubview(breadcrumbBar)

        let buttons = NSStackView(views: [backButton, forwardButton, upButton, refreshButton])
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        addSubview(addressField)
        addSubview(searchBox)

        activateConstraints(buttons: buttons)
        updateTooltips()
        styleDidChange()
    }

    private func activateConstraints(buttons: NSView) {
        let searchWidth = searchBox.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.28)
        searchWidth.priority = .defaultHigh
        fieldHeights = [addressField, searchBox].map { $0.heightAnchor.constraint(equalToConstant: Theme.fieldHeight) }
        NSLayoutConstraint.activate(fieldHeights)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: centerYAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: addressField.leadingAnchor, constant: 4),
            breadcrumbBar.trailingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: -4),
            breadcrumbBar.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),

            searchBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchWidth,
            searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            searchBox.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
        ])
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

    /// Windows 11's rounded, outlined boxes, or Windows 98's square ones in a sunken frame
    /// (drawn by `draw(_:)`, around the boxes).
    func styleDidChange() {
        let classic = Theme.isClassic
        for box in [addressField, searchBox] {
            box.layer?.cornerRadius = Theme.controlCornerRadius
            box.layer?.borderWidth = classic ? 0 : 1
        }
        for constraint in fieldHeights { constraint.constant = Theme.fieldHeight }
        searchField.font = Theme.font(ofSize: 13)
        // The magnifier keeps its position from the old height unless its cell is reset.
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.resetSearchButtonCell()
            cell.resetCancelButtonCell()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard Theme.isClassic else { return }
        for box in [addressField, searchBox] {
            let inset = -Bevel.sunkenField.width
            Bevel.sunkenField.draw(in: box.frame.insetBy(dx: inset, dy: inset), flipped: isFlipped)
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            addressField.layer?.borderColor = Theme.dividerColor.cgColor
            searchBox.layer?.borderColor = Theme.dividerColor.cgColor
        }
    }

    private func configureSearchField() {
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = Theme.font(ofSize: 13)
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(searchField)
    }

    /// Shows `query` (unless the user is typing) and "Search <place>".
    func setSearch(query: String, placeholder: String, isEnabled: Bool) {
        searchField.placeholderString = placeholder
        searchField.isEnabled = isEnabled
        searchBox.alphaValue = isEnabled ? 1 : 0.6
        if searchField.currentEditor() == nil {
            searchField.stringValue = query
        }
    }

    /// Ctrl+F, Ctrl+E, F3.
    func focusSearch() {
        guard searchField.isEnabled else { return }
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Sent on Return (handled by the delegate instead) and by the clear button.
    @objc private func searchFieldAction() {
        if searchField.stringValue.isEmpty { onSearchCancel?() }
    }

    /// Shows the scheme's shortcuts in the buttons' tooltips.
    func updateTooltips() {
        backButton.toolTip = KeyboardShortcuts.toolTip("Back", .back)
        forwardButton.toolTip = KeyboardShortcuts.toolTip("Forward", .forward)
        upButton.toolTip = KeyboardShortcuts.toolTip("Up to the parent folder", .up)
        refreshButton.toolTip = KeyboardShortcuts.toolTip("Refresh", .refresh)
        searchField.toolTip = KeyboardShortcuts.toolTip("Search", .search)
            + "\nFilters: kind:picture  date:\"last week\"  size:>10MB  ext:pdf"
    }

    /// Called after every navigation to refresh enabled state and the breadcrumb.
    func update(location: ExplorerLocation, history: NavigationHistory) {
        backButton.isEnabled = history.canGoBack
        forwardButton.isEnabled = history.canGoForward
        upButton.isEnabled = location.parent != nil
        breadcrumbBar.setLocation(location)
    }

    /// Switches the breadcrumb to an editable path (Ctrl+L, Alt+D, F4).
    /// In Tab order: the navigation buttons (with Full Keyboard Access), address, search.
    var keyViews: [NSView] { [backButton, forwardButton, upButton, refreshButton, breadcrumbBar, searchField] }

    /// The search box, when searching is possible here.
    var searchKeyView: NSView? { searchField.isEnabled ? searchField : nil }

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

extension AddressBarView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onSearchChange?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearchSubmit?(searchField.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            onSearchCancel?()
            onSearchMoveDown?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            onSearchMoveDown?()
            return true
        default:
            return false
        }
    }
}

/// The address bar's search box, drawn without a bezel inside a Windows-style rounded box.
private final class SearchField: NSSearchField {
    override static var cellClass: AnyClass? {
        get { SearchFieldCell.self }
        set { _ = newValue }
    }
}

/// Without a bezel, `NSSearchFieldCell` edits across its whole width, so typed text runs under
/// the magnifying glass; keep editing within the text area, as drawing does.
private final class SearchFieldCell: NSSearchFieldCell {
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
