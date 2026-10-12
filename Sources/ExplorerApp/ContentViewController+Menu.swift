import AppKit
import ExplorerCore

/// Right-click menus. Right-clicking an unselected item selects it, and right-clicking the
/// background clears the selection, as in Windows. Actions travel up the responder chain to
/// `ExplorerWindowController`, which also validates them. The Details header has its own
/// menu: Size column to fit, and the column chooser.
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

        switch (mode, onItem) {
        case (.folder, true):
            menu.add("Open", #selector(ExplorerWindowController.openSelection(_:)))
            menu.addItem(.separator())
            menu.add("Cut", #selector(NSText.cut(_:)), key: "x")
            menu.add("Copy", #selector(NSText.copy(_:)), key: "c")
            menu.addItem(.separator())
            menu.add("Rename", #selector(ExplorerWindowController.renameSelection(_:)),
                     key: MainMenu.f2Key, modifiers: [])
            menu.add("Delete", #selector(ExplorerWindowController.delete(_:)), key: MainMenu.backspaceKey)
        case (.folder, false):
            addViewItems(to: menu)
            menu.add("Paste", #selector(NSText.paste(_:)), key: "v")
            menu.addItem(.separator())
            menu.addItem(MainMenu.newSubmenuItem())
        case (.recycleBin, true):
            menu.add("Restore", #selector(ExplorerWindowController.restoreSelection(_:)))
            menu.addItem(.separator())
            menu.add("Cut", #selector(NSText.cut(_:)), key: "x")
            menu.add("Delete", #selector(ExplorerWindowController.delete(_:)), key: MainMenu.backspaceKey)
        case (.recycleBin, false):
            addViewItems(to: menu)
            menu.add("Empty Recycle Bin", #selector(ExplorerWindowController.emptyRecycleBin(_:)))
            menu.add("Restore all items", #selector(ExplorerWindowController.restoreAll(_:)))
        case (.volumes, true):
            menu.add("Open", #selector(ExplorerWindowController.openSelection(_:)))
        case (.volumes, false):
            addViewItems(to: menu)
        }
    }

    /// Windows' background menu starts with View ▸, Sort by ▸, Group by ▸ and Refresh.
    private func addViewItems(to menu: NSMenu) {
        menu.addItem(MainMenu.viewSubmenuItem())
        menu.addItem(MainMenu.sortBySubmenuItem())
        menu.addItem(MainMenu.groupBySubmenuItem())
        menu.add("Refresh", #selector(AppDelegate.refresh(_:)), key: "r")
        menu.addItem(.separator())
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

        for column in FileColumn.available(inRecycleBin: mode == .recycleBin) {
            let item = menu.add(column.title, #selector(toggleColumn(_:)), modifiers: [])
            item.target = self
            item.representedObject = column.rawValue
            item.state = settings.columns.contains(column) ? .on : .off
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
