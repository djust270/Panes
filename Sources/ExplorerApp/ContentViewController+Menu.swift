import AppKit
import ExplorerCore

/// Right-click menus, laid out like Windows 11's: a row of icons for Cut, Copy, Rename, Share
/// and Delete, then the main commands, with the rest under "Show more options". Right-clicking
/// an unselected item selects it, and right-clicking the background clears the selection, as
/// in Windows. Actions travel up the responder chain to the tab, which also validates them.
/// The Details header has its own menu: Size column to fit, and the column chooser.
extension ContentViewController: NSMenuDelegate {
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.headerView?.menu {
            updateHeaderMenu(menu)
        } else if menu === tableView.menu || menu === collectionView.menu {
            updateContextMenu(menu)
        }
    }

    /// The item under the right-click, after making the selection match it.
    private func prepareClickedItem(for menu: NSMenu) -> FileItem? {
        let clicked: FileItem?
        if menu === tableView.menu {
            clicked = listContent.item(atRow: tableView.clickedRow)
        } else {
            clicked = collectionView.clickedIndexPath.flatMap {
                listContent.item(section: $0.section, index: $0.item)
            }
        }
        if let clicked {
            if !selectedURLs.contains(clicked.url.standardizedFileURL) {
                setSelection([clicked.url.standardizedFileURL], scroll: false)
            }
        } else {
            selectNone()
        }
        return clicked
    }

    private func updateContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        finishRenaming(commit: true)
        let onItem = prepareClickedItem(for: menu) != nil
        let selection = selectedItems
        let hasFolders = selection.contains(where: \.isFolder)

        switch (mode, onItem) {
        case (.folder, true), (.search, true), (.home, true):
            addFolderItemCommands(to: menu, hasFolders: hasFolders, files: selection.filter { !$0.isFolder })
        case (.search, false):
            addViewItems(to: menu)
            menu.items.last.map(menu.removeItem)
        case (.home, false):
            menu.add("Refresh", #selector(ExplorerTabController.refresh(_:)), command: .refresh)
        case (.folder, false):
            addViewItems(to: menu)
            menu.add("Paste", #selector(NSText.paste(_:)), command: .paste)
            if let undo = view.window?.undoManager, undo.canUndo {
                let title = undo.undoActionName.isEmpty ? "Undo" : "Undo \(undo.undoActionName)"
                menu.add(title, Selector(("undo:")), command: .undo)
            }
            menu.addItem(.separator())
            menu.addItem(MainMenu.newSubmenuItem())
            menu.addItem(.separator())
            menu.add("Open in Terminal", #selector(ExplorerTabController.openInTerminal(_:)), modifiers: [])
            menu.add("Copy as path", #selector(ExplorerTabController.copyAsPath(_:)), command: .copyAsPath)
            menu.add("Properties", #selector(ExplorerTabController.showProperties(_:)), command: .properties)
        case (.recycleBin, true):
            menu.add("Restore", #selector(ExplorerTabController.restoreSelection(_:)))
            menu.addItem(.separator())
            menu.add("Cut", #selector(NSText.cut(_:)), command: .cut)
            menu.add("Delete", #selector(ExplorerTabController.delete(_:)), command: .delete)
            menu.addItem(.separator())
            menu.add("Properties", #selector(ExplorerTabController.showProperties(_:)), command: .properties)
        case (.recycleBin, false):
            addViewItems(to: menu)
            menu.add("Empty Recycle Bin", #selector(ExplorerTabController.emptyRecycleBin(_:)))
            menu.add("Restore all items", #selector(ExplorerTabController.restoreAll(_:)))
        case (.volumes, _), (.network, _):
            addDriveCommands(to: menu, onItem: onItem, volumes: selection.compactMap(\.volume))
        }
    }

    /// This PC's and Network's menus: Open, Eject or Disconnect, Map network drive, Properties.
    private func addDriveCommands(to menu: NSMenu, onItem: Bool, volumes: [MountedVolume]) {
        if onItem {
            menu.add("Open", #selector(ExplorerTabController.openSelection(_:)), command: .open)
            if mode == .volumes {
                menu.add("Open in new tab", #selector(ExplorerTabController.openInNewTab(_:)), modifiers: [])
                menu.add("Open in new window", #selector(ExplorerTabController.openInNewWindow(_:)), modifiers: [])
            }
            menu.addItem(.separator())
        } else {
            addViewItems(to: menu)
        }
        if volumes.contains(where: \.canEject) {
            let network = volumes.allSatisfy { $0.kind == .network }
            menu.add(network ? "Disconnect" : "Eject", #selector(ExplorerTabController.ejectSelection(_:)),
                     modifiers: [])
        }
        menu.add("Map network drive…", #selector(ExplorerTabController.mapNetworkDrive(_:)), modifiers: [])
        if mode == .volumes, onItem {
            menu.addItem(.separator())
            menu.add("Properties", #selector(ExplorerTabController.showProperties(_:)), command: .properties)
        }
    }

    /// Windows 11's item menu: the icon row, Open (in a new tab or window, or with an app),
    /// Open file location (search results, Home), Quick access and Favorites, Compress, Copy as
    /// path, and "Show more options".
    private func addFolderItemCommands(to menu: NSMenu, hasFolders: Bool, files: [FileItem]) {
        menu.addItem(ContextMenuIconRow.item(buttons: [
            .init(symbol: "scissors", title: "Cut", action: #selector(NSText.cut(_:))),
            .init(symbol: "doc.on.doc", title: "Copy", action: #selector(NSText.copy(_:))),
            .init(symbol: "character.cursor.ibeam", title: "Rename",
                  action: #selector(ExplorerTabController.renameSelection(_:))),
            .init(symbol: "square.and.arrow.up", title: "Share",
                  action: #selector(ExplorerTabController.shareSelection(_:))),
            .init(symbol: "trash", title: "Delete", action: #selector(ExplorerTabController.delete(_:))),
        ], from: activeView))
        menu.addItem(.separator())
        menu.add("Open", #selector(ExplorerTabController.openSelection(_:)), command: .open)
        if hasFolders {
            menu.add("Open in new tab", #selector(ExplorerTabController.openInNewTab(_:)), modifiers: [])
            menu.add("Open in new window", #selector(ExplorerTabController.openInNewWindow(_:)), modifiers: [])
        }
        if !files.isEmpty {
            menu.addItem(openWithItem(for: files.map(\.url)))
        }
        if mode == .search || mode == .home {
            menu.add("Open file location", #selector(ExplorerTabController.openFileLocation(_:)), modifiers: [])
        }
        let selection = selectedItems
        if selection.count == 1, let only = selection.first {
            if only.kind == .file, Archive.isExtractable(only.url), mode != .home {
                menu.add("Extract All…", #selector(ExplorerTabController.extractAll(_:)), modifiers: [])
            }
            if only.isFolder {
                menu.add("Open in Terminal", #selector(ExplorerTabController.openInTerminal(_:)), modifiers: [])
            }
        }
        menu.addItem(.separator())
        addQuickAccessItems(to: menu)
        if mode == .folder {
            menu.add("Compress to ZIP file", #selector(ExplorerTabController.compressSelection(_:)), modifiers: [])
        }
        menu.add("Copy as path", #selector(ExplorerTabController.copyAsPath(_:)), command: .copyAsPath)
        menu.add("Properties", #selector(ExplorerTabController.showProperties(_:)), command: .properties)
        menu.addItem(.separator())
        menu.addItem(moreOptionsItem())
    }

    /// Where to anchor a popover for the selection (e.g. the share sheet), in `activeView`.
    func anchorRectForSelection() -> NSRect {
        guard let url = selectedURLs.first else { return NSRect(origin: .zero, size: NSSize(width: 1, height: 1)) }
        if isDetailsMode, let row = listContent.row(of: url) {
            let rect = tableView.rect(ofRow: row)
            return NSRect(x: rect.minX + 20, y: rect.minY, width: min(rect.width, 200), height: rect.height)
        }
        if let position = listContent.position(of: url),
           let item = collectionView.item(at: IndexPath(item: position.index, section: position.section)) {
            return item.view.frame
        }
        return collectionView.visibleRect.insetBy(dx: collectionView.visibleRect.width / 2 - 1, dy: 0)
    }

    /// Pin to / Unpin from Quick access (folders), Add to / Remove from Favorites (files), and
    /// on Home, Remove from Quick access (frequent folders) and Remove from Recent. Items that
    /// don't apply to the selection are left out rather than disabled.
    private func addQuickAccessItems(to menu: NSMenu) {
        let selection = selectedItems
        let store = QuickAccess.store
        let folders = selection.filter(\.isFolder)
        let files = selection.filter { !$0.isFolder }
        let before = menu.numberOfItems
        if !folders.isEmpty, folders.count == selection.count {
            if folders.allSatisfy({ store.isPinned($0.url) }) {
                menu.add("Unpin from Quick access", #selector(ExplorerTabController.unpinFromQuickAccess(_:)),
                         modifiers: [])
            } else {
                menu.add("Pin to Quick access", #selector(ExplorerTabController.pinToQuickAccess(_:)), modifiers: [])
            }
        }
        if !files.isEmpty, files.count == selection.count {
            if files.allSatisfy({ store.isFavorite($0.url) }) {
                menu.add("Remove from Favorites", #selector(ExplorerTabController.removeFromFavorites(_:)),
                         modifiers: [])
            } else {
                menu.add("Add to Favorites", #selector(ExplorerTabController.addToFavorites(_:)), modifiers: [])
            }
        }
        let sections = Set(selection.compactMap(homeSection(of:)))
        if sections == [.quickAccess], !folders.contains(where: { store.isPinned($0.url) }) {
            menu.add("Remove from Quick access", #selector(ExplorerTabController.removeFromFrequent(_:)),
                     modifiers: [])
        }
        if sections == [.recent] {
            menu.add("Remove from Recent", #selector(ExplorerTabController.removeFromRecent(_:)), modifiers: [])
        }
        if menu.numberOfItems > before { menu.addItem(.separator()) }
    }

    /// Windows' background menu starts with View ▸, Sort by ▸, Group by ▸ and Refresh.
    private func addViewItems(to menu: NSMenu) {
        menu.addItem(MainMenu.viewSubmenuItem())
        menu.addItem(MainMenu.sortBySubmenuItem())
        menu.addItem(MainMenu.groupBySubmenuItem())
        menu.add("Refresh", #selector(ExplorerTabController.refresh(_:)), command: .refresh)
        menu.addItem(.separator())
    }

    /// "Open with ▸ <default app> / other apps / Choose another app…".
    private func openWithItem(for files: [URL]) -> NSMenuItem {
        let submenu = NSMenu(title: "Open with")
        let apps = ExplorerTabController.apps(toOpen: files)
        func addApp(_ url: URL) {
            let name = FileManager.default.displayName(atPath: url.path)
            let title = (name as NSString).deletingPathExtension
            let item = submenu.add(title, #selector(ExplorerTabController.openWith(_:)), modifiers: [])
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if let defaultApp = apps.default {
            addApp(defaultApp)
            if !apps.others.isEmpty { submenu.addItem(.separator()) }
        }
        apps.others.prefix(30).forEach(addApp)
        submenu.addItem(.separator())
        submenu.add("Choose another app…", #selector(ExplorerTabController.openWithOtherApp(_:)), modifiers: [])
        let item = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// "Show more options ▸": the classic commands, including Send to.
    private func moreOptionsItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Show more options")
        submenu.addItem(sendToItem())
        submenu.addItem(.separator())
        submenu.add("Cut", #selector(NSText.cut(_:)), command: .cut)
        submenu.add("Copy", #selector(NSText.copy(_:)), command: .copy)
        submenu.addItem(.separator())
        submenu.add("Delete", #selector(ExplorerTabController.delete(_:)), command: .delete)
        submenu.add("Rename", #selector(ExplorerTabController.renameSelection(_:)), command: .rename)
        if AppSettings.dualPane {
            submenu.addItem(.separator())
            submenu.add("Copy to other pane", #selector(ExplorerTabController.copyToOtherPane(_:)), modifiers: [])
            submenu.add("Move to other pane", #selector(ExplorerTabController.moveToOtherPane(_:)), modifiers: [])
        }
        if let tab = dropHandler as? ExplorerTabController, tab.canCopyAsWindowsPath {
            submenu.addItem(.separator())
            submenu.add("Copy as Windows path", #selector(ExplorerTabController.copyAsWindowsPath(_:)), modifiers: [])
        }
        let item = NSMenuItem(title: "Show more options", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "ellipsis.rectangle", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    /// "Send to ▸ Desktop, Documents, Downloads, Mail recipient, <removable drives>": copies there.
    private func sendToItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Send to")
        let fileManager = FileManager.default
        let folders: [(String, FileManager.SearchPathDirectory)] = [
            ("Desktop", .desktopDirectory), ("Documents", .documentDirectory), ("Downloads", .downloadsDirectory),
        ]
        for (title, directory) in folders {
            guard let url = fileManager.urls(for: directory, in: .userDomainMask).first else { continue }
            let item = submenu.add(title, #selector(ExplorerTabController.sendTo(_:)), modifiers: [])
            item.representedObject = url
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        let mail = submenu.add("Mail recipient", #selector(ExplorerTabController.sendToMail(_:)), modifiers: [])
        mail.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)
        let drives = VolumeLister.mountedVolumes().filter { !$0.isInternal }
        if !drives.isEmpty { submenu.addItem(.separator()) }
        for drive in drives {
            let item = submenu.add(drive.name, #selector(ExplorerTabController.sendTo(_:)), modifiers: [])
            item.representedObject = drive.url
            item.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        }
        let item = NSMenuItem(title: "Send to", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: Header menu

    private func updateHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        var clicked: FileColumn?
        if let header = tableView.headerView, let event = NSApp.currentEvent {
            let index = header.column(at: header.convert(event.locationInWindow, from: nil))
            if index >= 0 { clicked = FileColumn(rawValue: tableView.tableColumns[index].identifier.rawValue) }
        }

        let fit = menu.add("Size Column to Fit", #selector(sizeColumnToFitFromMenu(_:)))
        fit.target = self
        fit.representedObject = clicked?.rawValue
        fit.isEnabled = clicked != nil
        menu.add("Size All Columns to Fit", #selector(sizeAllColumnsToFit(_:))).target = self
        menu.addItem(.separator())

        for column in FileColumn.available(in: listKind) {
            let item = menu.add(column.title, #selector(toggleColumn(_:)), modifiers: [])
            item.target = self
            item.representedObject = column.rawValue
            item.state = settings.columns.contains(column) ? NSControl.StateValue.on : .off
            item.isEnabled = column != .name
        }
        menu.addItem(.separator())
        menu.addItem(MainMenu.groupBySubmenuItem())
    }

    @objc private func sizeColumnToFitFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = FileColumn(rawValue: raw) else { return }
        sizeColumnToFit(column)
    }

    @objc private func sizeAllColumnsToFit(_ sender: Any?) {
        settings.columns.forEach(sizeColumnToFit)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = FileColumn(rawValue: raw) else { return }
        updateSettings { settings in
            if let index = settings.columns.firstIndex(of: column) {
                settings.columns.remove(at: index)
            } else {
                settings.columns.append(column)
            }
        }
    }
}

extension NSMenu {
    @discardableResult
    func add(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }
}
