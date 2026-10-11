import AppKit
import ExplorerCore

/// Window layout: navigation pane | content, with a status bar along the bottom.
@MainActor
final class ExplorerRootViewController: NSViewController {
    let navigationPane = NavigationPaneViewController()
    let content = ContentViewController()
    let statusBar = StatusBarView()
    private let splitViewController = NSSplitViewController()

    override func loadView() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: navigationPane)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 300

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.autosaveName = "ExplorerSplitView"
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
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
    }
}

/// Bottom status bar ("N items | M items selected 1.2 MB").
@MainActor
final class StatusBarView: NSView {
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
