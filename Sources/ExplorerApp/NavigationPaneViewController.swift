import AppKit
import ExplorerCore

/// Navigation pane: Home, the Quick access pins (by default the well-known folders), This PC
/// (lazily expanded to mounted volumes), Network and the Recycle Bin. Folders and the Recycle
/// Bin accept drops. Pins follow Quick access changes made anywhere in the app.
@MainActor
final class NavigationPaneViewController: NSViewController {
    var onSelect: ((ExplorerLocation) -> Void)?
    /// "Open in new tab" or middle-click on a location.
    var onOpenInNewTab: ((ExplorerLocation) -> Void)?
    weak var dropHandler: FileDropHandling?

    private let outlineView = NavigationOutlineView()
    private let scrollView = NSScrollView()
    private var childrenCache: [String: [SidebarItem]] = [:]
    private var roots = SidebarTree.roots(pinnedFolders: QuickAccess.store.pinnedFolders)
    private var quickAccessObserver: NSObjectProtocol?
    private var driveObserver: NSObjectProtocol?
    /// The location last passed to `select(_:)`, to re-select after the pins change.
    private var selectedLocation: ExplorerLocation?
    /// Set while `select(_:)` is driving the selection programmatically, so
    /// `outlineViewSelectionDidChange` doesn't re-navigate to where we already are.
    private var isProgrammaticSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.backgroundColor = Theme.bodyColor
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = Theme.navigationRowHeight
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 14
        outlineView.menu = makeContextMenu()
        outlineView.onMiddleClick = { [weak self] row in
            guard let self, let location = location(atRow: row) else { return }
            onOpenInNewTab?(location)
        }
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autosaveExpandedItems = true
        outlineView.autosaveName = "NavigationPaneOutline"
        outlineView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false

        let container = NSView()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        outlineView.reloadData()
        for root in roots where root.isExpandable {
            outlineView.expandItem(root)
        }
        quickAccessObserver = QuickAccess.observe { [weak self] in self?.reloadPins() }
        driveObserver = DriveCenter.observe { [weak self] in self?.reloadDrives() }
    }

    /// Stops following Quick access and drives. Called when the tab closes.
    func close() {
        for observer in [quickAccessObserver, driveObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        quickAccessObserver = nil
        driveObserver = nil
    }

    /// Re-reads This PC's volumes after a mount, unmount or drive-letter change.
    private func reloadDrives() {
        guard let thisPC = roots.first(where: { $0.id == SidebarTree.thisPCID }) else { return }
        childrenCache[thisPC.id] = nil
        outlineView.reloadItem(thisPC, reloadChildren: true)
        if let selectedLocation { select(selectedLocation) }
    }

    /// Rebuilds the roots if Quick access's pins changed.
    private func reloadPins() {
        let updated = SidebarTree.roots(pinnedFolders: QuickAccess.store.pinnedFolders)
        guard updated != roots else { return }
        roots = updated
        outlineView.reloadData()
        if let selectedLocation { select(selectedLocation) }
    }

    /// Highlights the sidebar row for `location`, expanding This PC if needed. Deselects if
    /// `location` isn't one of the ~15 nodes this pane knows about (most locations aren't,
    /// in Phase 1 — that's a known limitation, not a bug).
    func select(_ location: ExplorerLocation) {
        guard isViewLoaded else { return }
        selectedLocation = location
        isProgrammaticSelection = true
        defer { isProgrammaticSelection = false }

        if let root = roots.first(where: { $0.location == location }) {
            selectRow(for: root)
            return
        }

        if let thisPC = roots.first(where: { $0.id == SidebarTree.thisPCID }) {
            let children = children(of: thisPC)
            if let child = children.first(where: { $0.location == location }) {
                outlineView.expandItem(thisPC)
                selectRow(for: child)
                return
            }
        }

        outlineView.deselectAll(nil)
    }

    private func selectRow(for item: SidebarItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func children(of item: SidebarItem) -> [SidebarItem] {
        if let cached = childrenCache[item.id] { return cached }
        var names: [URL: String] = [:]
        for (volume, letter) in DriveCenter.volumes() {
            names[volume.url.standardizedFileURL] = DriveCenter.displayName(volume, letter: letter)
        }
        let children = SidebarTree.children(of: item, names: names)
        childrenCache[item.id] = children
        return children
    }
}

extension NavigationPaneViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return roots.count }
        guard let sidebarItem = item as? SidebarItem else { return 0 }
        return children(of: sidebarItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return roots[index] }
        let sidebarItem = item as! SidebarItem // swiftlint:disable:this force_cast
        return children(of: sidebarItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        (item as? SidebarItem)?.id
    }

    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let id = object as? String else { return nil }
        return roots.first { $0.id == id }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard index == NSOutlineViewDropOnItemIndex,
              let location = dropLocation(for: item),
              let urls = ContentViewController.fileURLs(in: info.draggingPasteboard) else { return [] }
        return dropHandler?.dropOperation(for: urls, into: location, sourceMask: info.draggingSourceOperationMask) ?? []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let dropHandler,
              let location = dropLocation(for: item),
              let urls = ContentViewController.fileURLs(in: info.draggingPasteboard) else { return false }
        let mask = info.draggingSourceOperationMask
        let operation = dropHandler.dropOperation(for: urls, into: location, sourceMask: mask)
        guard !operation.isEmpty else { return false }
        dropHandler.performDrop(of: urls, into: location, operation: operation)
        return true
    }

    /// Rows that accept drops: real folders (including volumes) and the Recycle Bin.
    private func dropLocation(for item: Any?) -> ExplorerLocation? {
        guard let location = (item as? SidebarItem)?.location else { return nil }
        switch location {
        case .folder, .recycleBin: return location
        default: return nil
        }
    }
}

extension NavigationPaneViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar-row")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.symbolConfiguration = .init(scale: .small)
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.font = Theme.font(ofSize: 12)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = sidebarItem.title
        cell.imageView?.image = NSImage(systemSymbolName: sidebarItem.symbolName, accessibilityDescription: nil)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ExplorerRowView()
        row.usesNeutralSelection = true
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        onSelect?(item.location)
    }
}

// MARK: - Context menu, theme

extension NavigationPaneViewController: NSMenuDelegate {
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = outlineView.clickedRow
        guard let location = location(atRow: clickedRow) else { return }
        let newTab = menu.addItem(withTitle: "Open in new tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
        newTab.target = self
        newTab.representedObject = location
        let newWindow = menu.addItem(withTitle: "Open in new window", action: #selector(openInNewWindow(_:)),
                                     keyEquivalent: "")
        newWindow.target = self
        newWindow.representedObject = location
        if location == .thisPC || location == .network {
            menu.addItem(.separator())
            // No target: travels the responder chain to the tab.
            menu.addItem(withTitle: "Map network drive…", action: #selector(ExplorerTabController.mapNetworkDrive(_:)),
                         keyEquivalent: "")
        }

        guard let folder = location.fileURL else { return }
        let volume = VolumeLister.volume(at: folder)
        if ExplorerLocation.isVolumeRoot(folder), volume.canEject {
            menu.addItem(.separator())
            let eject = menu.addItem(withTitle: volume.kind == .network ? "Disconnect" : "Eject",
                                     action: #selector(ejectVolume(_:)), keyEquivalent: "")
            eject.target = self
            eject.representedObject = folder
        }
        menu.addItem(.separator())
        let isPinned = (outlineView.item(atRow: clickedRow) as? SidebarItem)?.isPinnedFolder == true
            || QuickAccess.store.isPinned(folder)
        let pin = menu.addItem(
            withTitle: isPinned ? "Unpin from Quick access" : "Pin to Quick access",
            action: #selector(togglePin(_:)),
            keyEquivalent: ""
        )
        pin.target = self
        pin.representedObject = folder
        pin.tag = isPinned ? 1 : 0
        menu.addItem(.separator())
        let properties = menu.addItem(withTitle: "Properties", action: #selector(showProperties(_:)), keyEquivalent: "")
        properties.target = self
        properties.representedObject = folder
    }

    @objc private func showProperties(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        PropertiesWindowController.show([folder])
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        QuickAccess.change { store in
            if sender.tag == 1 {
                store.unpin(folder)
            } else {
                store.pin(folder)
            }
        }
    }

    @objc private func ejectVolume(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? URL else { return }
        DriveCenter.eject(at: volume, from: view.window)
    }

    fileprivate func location(atRow row: Int) -> ExplorerLocation? {
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? SidebarItem)?.location
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? ExplorerLocation else { return }
        onOpenInNewTab?(location)
    }

    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? ExplorerLocation else { return }
        AppDelegate.shared.openWindow(at: location)
    }

    /// Re-applies Compact view and colours after settings change.
    func applyTheme() {
        guard isViewLoaded else { return }
        outlineView.rowHeight = Theme.navigationRowHeight
        outlineView.backgroundColor = Theme.bodyColor
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outlineView.numberOfRows))
        outlineView.needsDisplay = true
    }
}

/// The navigation pane's outline: middle-click opens a location in a new tab.
final class NavigationOutlineView: NSOutlineView {
    var onMiddleClick: ((Int) -> Void)?

    override func otherMouseUp(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0 {
            onMiddleClick?(row)
        } else {
            super.otherMouseUp(with: event)
        }
    }
}
