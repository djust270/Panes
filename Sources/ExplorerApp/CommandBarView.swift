import AppKit
import ExplorerCore

/// Windows 11's command bar: New ▾ | Cut, Copy, Paste, Rename, Share, Delete | Sort ▾ View ▾ |
/// Filter ▾ ⋯, with Details on the right. Buttons act on the tab (`target`) and are enabled
/// by the same validation as the menus. When the window is narrow, less important buttons
/// drop out; their commands stay in the menus.
@MainActor
final class CommandBarView: NSView {
    /// The tab the buttons act on.
    weak var target: ExplorerTabController? {
        didSet { validate() }
    }

    private let newButton = FluentButton(symbol: "plus.circle", title: "New", toolTip: "Create a new item")
    private let cutButton = FluentButton(symbol: "scissors", toolTip: "Cut")
    private let copyButton = FluentButton(symbol: "doc.on.doc", toolTip: "Copy")
    private let pasteButton = FluentButton(symbol: "doc.on.clipboard", toolTip: "Paste")
    private let renameButton = FluentButton(symbol: "character.cursor.ibeam", toolTip: "Rename")
    private let shareButton = FluentButton(symbol: "square.and.arrow.up", toolTip: "Share")
    private let deleteButton = FluentButton(symbol: "trash", toolTip: "Delete")
    private let sortButton = FluentButton(symbol: "arrow.up.arrow.down", title: "Sort", toolTip: "Sort and group")
    private let viewButton = FluentButton(
        symbol: "rectangle.grid.2x2",
        title: "View",
        toolTip: "Layout and view options"
    )
    private let filterButton = FluentButton(
        symbol: "line.3.horizontal.decrease",
        title: "Filter",
        toolTip: "Show only some kinds of items"
    )
    private let moreButton = FluentButton(symbol: "ellipsis", toolTip: "See more")
    private let detailsButton = FluentButton(symbol: "sidebar.right", title: "Details", toolTip: "Details pane")

    /// In Tab order (buttons take focus only with Full Keyboard Access).
    var keyViews: [NSView] {
        [newButton, cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton,
         sortButton, viewButton, filterButton, moreButton, detailsButton]
    }

    /// Buttons that send a tab action, validated like menu items.
    private var actionButtons: [(FluentButton, Selector)] {
        [
            (cutButton, #selector(ExplorerTabController.cut(_:))),
            (copyButton, #selector(ExplorerTabController.copy(_:))),
            (pasteButton, #selector(ExplorerTabController.paste(_:))),
            (renameButton, #selector(ExplorerTabController.renameSelection(_:))),
            (shareButton, #selector(ExplorerTabController.shareSelection(_:))),
            (deleteButton, #selector(ExplorerTabController.delete(_:))),
            (detailsButton, #selector(ExplorerTabController.toggleDetailsPane(_:))),
        ]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (index, (button, _)) in actionButtons.enumerated() {
            button.target = self
            button.action = #selector(performButtonAction(_:))
            button.tag = index
        }
        detailsButton.setButtonType(.pushOnPushOff)

        newButton.dropDownMenu = makeMenu { MainMenu.newItems() }
        sortButton.dropDownMenu = makeMenu { MainMenu.sortItems() + [.separator(), MainMenu.groupBySubmenuItem()] }
        viewButton.dropDownMenu = makeMenu { MainMenu.viewModeItems() + [.separator()] + Self.showItems() }
        filterButton.dropDownMenu = makeMenu { MainMenu.filterItems() }
        moreButton.dropDownMenu = makeMenu { [weak self] in self?.moreItems() ?? [] }
        for button in [newButton, sortButton, viewButton, filterButton] {
            button.showsMenuIndicator = true
        }

        let leading = NSStackView(views: [
            newButton, Self.separator(),
            cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton, Self.separator(),
            sortButton, viewButton, Self.separator(),
            filterButton, moreButton,
        ])
        leading.spacing = 2
        leading.detachesHiddenViews = true
        // Narrow windows drop Share, Filter and the separators first, then Sort and View.
        for view in leading.arrangedSubviews {
            let priority: NSStackView.VisibilityPriority
            switch view {
            case moreButton, newButton, cutButton, copyButton, pasteButton, renameButton, deleteButton:
                priority = .mustHold
            case sortButton, viewButton:
                priority = NSStackView.VisibilityPriority(rawValue: 500)
            default:
                priority = NSStackView.VisibilityPriority(rawValue: 250)
            }
            leading.setVisibilityPriority(priority, for: view)
        }
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        leading.setClippingResistancePriority(.defaultLow, for: .horizontal)

        for subview in [leading, detailsButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -8),
            detailsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTooltips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the scheme's shortcuts in the tooltips.
    func updateTooltips() {
        cutButton.toolTip = KeyboardShortcuts.toolTip("Cut", .cut)
        copyButton.toolTip = KeyboardShortcuts.toolTip("Copy", .copy)
        pasteButton.toolTip = KeyboardShortcuts.toolTip("Paste", .paste)
        renameButton.toolTip = KeyboardShortcuts.toolTip("Rename", .rename)
        deleteButton.toolTip = KeyboardShortcuts.toolTip("Delete", .delete)
        detailsButton.toolTip = KeyboardShortcuts.toolTip("Details pane", .detailsPane)
    }

    /// Enables the buttons that apply to the current location and selection.
    func validate() {
        updateTooltips()
        guard let target else { return }
        for (button, action) in actionButtons {
            let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
            button.isEnabled = target.validateMenuItem(probe)
            if button === detailsButton { button.state = probe.state }
        }
        let inFolder = target.currentFolder != nil
        newButton.isEnabled = inFolder || target.inRemote
        filterButton.isEnabled = inFolder || target.inRemote
        filterButton.contentTintColor = target.content.kindFilter.isEmpty ? .labelColor : Theme.accent
    }

    @objc private func performButtonAction(_ sender: FluentButton) {
        guard let target, actionButtons.indices.contains(sender.tag) else { return }
        let action = actionButtons[sender.tag].1
        NSApp.sendAction(action, to: target, from: sender)
    }

    // MARK: Menus

    /// A drop-down menu whose items are rebuilt each time it opens, so they reflect the
    /// keyboard scheme. Items without a target travel the responder chain to the tab.
    private func makeMenu(_ items: @escaping @MainActor () -> [NSMenuItem]) -> NSMenu {
        DynamicMenu(build: items)
    }

    /// View ▾'s "Compact view" and "Show ▸".
    private static func showItems() -> [NSMenuItem] {
        let compact = NSMenuItem(title: "Compact view", action: #selector(AppDelegate.toggleCompactView(_:)),
                                 keyEquivalent: "")
        let show = NSMenu(title: "Show")
        show.add("Navigation pane", #selector(ExplorerTabController.toggleNavigationPane(_:)), command: .navigationPane)
        show.add("Details pane", #selector(ExplorerTabController.toggleDetailsPane(_:)), command: .detailsPane)
        show.add("Preview pane", #selector(ExplorerTabController.togglePreviewPane(_:)), command: .previewPane)
        show.add("Dual pane", #selector(AppDelegate.toggleDualPane(_:)), modifiers: [])
        show.addItem(.separator())
        show.add("Item check boxes", #selector(ExplorerTabController.toggleItemCheckboxes(_:)), modifiers: [])
        show.add("File name extensions", #selector(AppDelegate.toggleFileExtensions(_:)), modifiers: [])
        show.add("Hidden items", #selector(AppDelegate.toggleHiddenFiles(_:)), command: .hiddenFiles)
        let showItem = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        showItem.submenu = show
        return [compact, showItem]
    }

    private func moreItems() -> [NSMenuItem] {
        Self.moreItems(
            inCloud: target?.selectionIsInCloud == true,
            providerItems: target?.providerActionItems() ?? []
        )
    }

    /// ⋯: Undo, selection, Copy as path, Download now, Free up space and the provider's commands
    /// (in cloud folders), folder view options and Settings.
    private static func moreItems(inCloud: Bool, providerItems: [NSMenuItem]) -> [NSMenuItem] {
        let menu = NSMenu()
        menu.add("Undo", Selector(("undo:")), command: .undo)
        menu.add("Redo", Selector(("redo:")), command: .redo)
        menu.addItem(.separator())
        menu.add("Select all", #selector(NSText.selectAll(_:)), command: .selectAll)
        menu.add("Select none", #selector(ExplorerTabController.selectNone(_:)), command: .selectNone)
        menu.add("Invert selection", #selector(ExplorerTabController.invertSelection(_:)), command: .invertSelection)
        menu.addItem(.separator())
        menu.add("Copy as path", #selector(ExplorerTabController.copyAsPath(_:)), command: .copyAsPath)
        menu.add("Compress to ZIP file", #selector(ExplorerTabController.compressSelection(_:)), modifiers: [])
        menu.add("Extract all", #selector(ExplorerTabController.extractAll(_:)), modifiers: [])
        menu.add("Open in Terminal", #selector(ExplorerTabController.openInTerminal(_:)), modifiers: [])
        if inCloud {
            menu.addItem(.separator())
            menu.add("Download now", #selector(ExplorerTabController.downloadNow(_:)), modifiers: [])
            menu.add("Free up space", #selector(ExplorerTabController.freeUpSpace(_:)), modifiers: [])
            providerItems.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.add("Apply view to all folders", #selector(ExplorerTabController.applyViewToAllFolders(_:)), modifiers: [])
        menu.add("Reset all folders…", #selector(ExplorerTabController.resetAllFolders(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Map network drive…", #selector(ExplorerTabController.mapNetworkDrive(_:)), modifiers: [])
        menu.add("Connect to SSH Server…", #selector(ExplorerTabController.connectToSSHServer(_:)), modifiers: [])
        menu.add("Properties", #selector(ExplorerTabController.showProperties(_:)), command: .properties)
        menu.add("Options…", #selector(AppDelegate.showSettings(_:)), modifiers: [])
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    private static func separator() -> NSView {
        let line = ToolbarSeparator()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }
}

/// A thin vertical line between groups of buttons; etched in Windows 98 style.
final class ToolbarSeparator: NSView, StyleObserving {
    private lazy var width = widthAnchor.constraint(equalToConstant: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        styleDidChange()
        width.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func styleDidChange() {
        width.constant = Theme.isClassic ? 2 : 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if Theme.isClassic {
            Bevel.etchedLine(in: bounds, vertical: true, flipped: isFlipped)
        } else {
            Theme.dividerColor.setFill()
            bounds.fill()
        }
    }
}

/// A menu that rebuilds its items from a closure every time it opens.
@MainActor
final class DynamicMenu: NSMenu, NSMenuDelegate {
    private let build: @MainActor () -> [NSMenuItem]

    init(build: @escaping @MainActor () -> [NSMenuItem]) {
        self.build = build
        super.init(title: "")
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        build().forEach(addItem)
    }
}
