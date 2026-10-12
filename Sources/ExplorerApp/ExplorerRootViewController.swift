import AppKit
import ExplorerCore

/// Window layout: navigation pane | content | preview/details pane, with a status bar along
/// the bottom.
@MainActor
final class ExplorerRootViewController: NSViewController {
    let navigationPane = NavigationPaneViewController()
    let content = ContentViewController()
    let sidePane = SidePaneViewController()
    let statusBar = StatusBarView()
    private let splitViewController = NSSplitViewController()
    private var sidePaneItem: NSSplitViewItem?

    override func loadView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: navigationPane)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300

        let paneItem = NSSplitViewItem(viewController: sidePane)
        paneItem.minimumThickness = 200
        paneItem.maximumThickness = 600
        paneItem.canCollapse = true
        paneItem.holdingPriority = .defaultLow + 10
        sidePaneItem = paneItem

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.autosaveName = "ExplorerSplitView"
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.addSplitViewItem(paneItem)
        addChild(splitViewController)

        let splitView = splitViewController.view
        let container = NSView()
        for subview in [splitView, statusBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])

        view = container
        showSidePane(SidePaneViewController.savedPane, animated: false)
    }

    /// Shows the Preview or Details pane, or hides it (`.none`).
    func showSidePane(_ pane: SidePaneViewController.Pane, animated: Bool = true) {
        SidePaneViewController.savedPane = pane
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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
