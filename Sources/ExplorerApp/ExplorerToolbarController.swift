import AppKit
import ExplorerCore

/// Back/Forward (with history dropdowns), Up, Refresh, and the breadcrumb address bar, all
/// living in the window's unified toolbar.
@MainActor
final class ExplorerToolbarController: NSObject, NSToolbarDelegate {
    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let up = NSToolbarItem.Identifier("up")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let breadcrumb = NSToolbarItem.Identifier("breadcrumb")
    }

    let toolbar = NSToolbar(identifier: "ExplorerToolbar")
    let breadcrumbBar = BreadcrumbBarView()

    var onGoBack: ((Int) -> Void)?
    var onGoForward: ((Int) -> Void)?
    var onUp: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// Supplies fresh dropdown contents right before each menu opens.
    var backList: (() -> [ExplorerLocation])?
    var forwardList: (() -> [ExplorerLocation])?
    var onNavigate: ((ExplorerLocation) -> Void)? {
        didSet { breadcrumbBar.onNavigate = onNavigate }
    }

    private let backItem = NSMenuToolbarItem(itemIdentifier: Item.back)
    private let forwardItem = NSMenuToolbarItem(itemIdentifier: Item.forward)

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly

        backItem.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backItem.target = self
        backItem.action = #selector(goBack)
        backItem.menu.delegate = self

        forwardItem.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardItem.target = self
        forwardItem.action = #selector(goForward)
        forwardItem.menu.delegate = self
    }

    /// Called after every navigation to refresh enabled state, dropdown contents, and the
    /// breadcrumb.
    func update(location: ExplorerLocation, history: NavigationHistory) {
        backItem.isEnabled = history.canGoBack
        forwardItem.isEnabled = history.canGoForward
        breadcrumbBar.setLocation(location)
    }

    @objc private func goBack() {
        onGoBack?(1)
    }

    @objc private func goForward() {
        onGoForward?(1)
    }

    @objc private func up() {
        onUp?()
    }

    @objc private func refresh() {
        onRefresh?()
    }

    @objc private func historyMenuItemSelected(_ sender: NSMenuItem) {
        guard let steps = sender.representedObject as? Int else { return }
        if sender.menu === backItem.menu {
            onGoBack?(steps)
        } else if sender.menu === forwardItem.menu {
            onGoForward?(steps)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.back, Item.forward, Item.up, Item.refresh, .flexibleSpace, Item.breadcrumb]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Item.back:
            return backItem
        case Item.forward:
            return forwardItem
        case Item.up:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Up")
            item.target = self
            item.action = #selector(up)
            item.label = "Up"
            return item
        case Item.refresh:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refresh)
            item.label = "Refresh"
            return item
        case Item.breadcrumb:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = breadcrumbBar
            item.label = "Address"
            breadcrumbBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            return item
        default:
            return nil
        }
    }
}

extension ExplorerToolbarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let entries: [ExplorerLocation]
        if menu === backItem.menu {
            entries = backList?() ?? []
        } else if menu === forwardItem.menu {
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
