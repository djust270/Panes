import AppKit
import ExplorerCore

/// One tab's layout, as in Windows 11 Explorer: the address bar and command bar on the
/// header layer; below them the navigation pane | content | preview/details pane; and a
/// status bar along the bottom.
@MainActor
final class ExplorerRootViewController: NSViewController {
    let navigationPane = NavigationPaneViewController()
    let content = ContentViewController()
    let sidePane = SidePaneViewController()
    let addressBar = AddressBarView()
    let commandBar = CommandBarView()
    let statusBar = StatusBarView()
    private let splitViewController = NSSplitViewController()
    private var navigationItem: NSSplitViewItem?
    private var sidePaneItem: NSSplitViewItem?

    private static let navigationPaneKey = "NavigationPaneHidden"

    /// The second pane in dual-pane mode: no navigation pane or side pane, and its toggles
    /// don't change the app-wide choices.
    var isCompanion = false

    override func loadView() {
        let navigationItem = NSSplitViewItem(viewController: navigationPane)
        navigationItem.minimumThickness = 180
        navigationItem.maximumThickness = 400
        navigationItem.canCollapse = true
        navigationItem.holdingPriority = .defaultLow + 20
        navigationItem.isCollapsed = isCompanion || UserDefaults.standard.bool(forKey: Self.navigationPaneKey)
        self.navigationItem = navigationItem

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300

        let paneItem = NSSplitViewItem(viewController: sidePane)
        paneItem.minimumThickness = 200
        paneItem.maximumThickness = 600
        paneItem.canCollapse = true
        paneItem.holdingPriority = .defaultLow + 10
        sidePaneItem = paneItem

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        // The companion's pane widths aren't remembered: restoring the shared layout would
        // bring its navigation pane back.
        if !isCompanion { splitViewController.splitView.autosaveName = "ExplorerSplitView" }
        splitViewController.addSplitViewItem(navigationItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.addSplitViewItem(paneItem)
        addChild(splitViewController)

        view = makeLayout()
        showSidePane(isCompanion ? .none : SidePaneViewController.savedPane, animated: false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // After the window has shown: it computes a key view loop of its own the first time,
        // replacing links made earlier.
        linkKeyViews()
    }

    /// Tab order: address bar row, command bar, navigation pane, file list, status bar buttons,
    /// and round again. Buttons only take part with Full Keyboard Access on, and hidden views
    /// (the collapsed navigation pane, whichever file view isn't showing) are skipped.
    private func linkKeyViews() {
        let views = addressBar.keyViews + commandBar.keyViews
            + [navigationPane.keyView, content.tableView, content.collectionView] + statusBar.keyViews
        for (view, next) in zip(views, views.dropFirst() + [views[0]]) {
            view.nextKeyView = next
        }
    }

    /// F6's stops: address bar, search box, navigation pane and file list (those showing).
    var focusRegions: [NSView] {
        [addressBar.breadcrumbBar, addressBar.searchKeyView, isNavigationPaneShown ? navigationPane.keyView : nil,
         content.activeView].compactMap(\.self)
    }

    /// Header layer (address and command bars) over the body (panes and status bar).
    private func makeLayout() -> NSView {
        let header = LayerView(color: Theme.headerColor)
        header.drawsBottomDivider = true
        let body = LayerView(color: Theme.bodyColor)

        let splitView = splitViewController.view
        let container = NSView()
        for subview in [header, body, addressBar, commandBar, splitView, statusBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: commandBar.bottomAnchor),

            addressBar.topAnchor.constraint(equalTo: container.topAnchor),
            addressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: Theme.addressBarHeight),

            commandBar.topAnchor.constraint(equalTo: addressBar.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: Theme.commandBarHeight),

            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            splitView.topAnchor.constraint(equalTo: header.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        return container
    }

    var isNavigationPaneShown: Bool { navigationItem?.isCollapsed == false }

    /// View › Show › Navigation pane; app-wide, as on Windows.
    func toggleNavigationPane() {
        guard let navigationItem, !isCompanion else { return }
        let collapse = !navigationItem.isCollapsed
        navigationItem.animator().isCollapsed = collapse
        UserDefaults.standard.set(collapse, forKey: Self.navigationPaneKey)
    }

    /// Shows the Preview or Details pane, or hides it (`.none`).
    func showSidePane(_ pane: SidePaneViewController.Pane, animated: Bool = true) {
        if !isCompanion { SidePaneViewController.savedPane = pane }
        sidePane.show(pane)
        guard let sidePaneItem else { return }
        let collapse = pane == .none
        if animated {
            sidePaneItem.animator().isCollapsed = collapse
        } else {
            sidePaneItem.isCollapsed = collapse
        }
    }
}

/// Bottom status bar: "N items | M items selected 1.2 MB" on the left, and Windows' Details /
/// Large icons layout buttons on the right.
@MainActor
final class StatusBarView: NSView {
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var onViewMode: ((ViewMode) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let detailsButton = StatusBarView.modeButton("list.bullet", "Details")
    private let iconsButton = StatusBarView.modeButton("square.grid.2x2", "Large icons")
    var keyViews: [NSView] { [detailsButton, iconsButton] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Theme.font(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        detailsButton.target = self
        detailsButton.action = #selector(showDetails)
        iconsButton.target = self
        iconsButton.action = #selector(showIcons)
        for subview in [label, detailsButton, iconsButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -8),
            iconsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            iconsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: iconsButton.leadingAnchor, constant: -4),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Highlights the button for the current layout.
    func setViewMode(_ mode: ViewMode) {
        detailsButton.state = mode == .details ? .on : .off
        iconsButton.state = mode == .largeIcons ? .on : .off
    }

    private static func modeButton(_ symbol: String, _ title: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.toolTip = title
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.controlSize = .small
        return button
    }

    @objc private func showDetails() {
        onViewMode?(.details)
    }

    @objc private func showIcons() {
        onViewMode?(.largeIcons)
    }
}
