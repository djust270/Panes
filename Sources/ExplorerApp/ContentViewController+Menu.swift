import AppKit

/// Right-click menu. Right-clicking an unselected row selects it, and right-clicking the
/// background clears the selection, as in Windows. Actions travel up the responder chain to
/// `ExplorerWindowController`, which also validates them.
extension ContentViewController: NSMenuDelegate {
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }
        menu.removeAllItems()
        finishRenaming(commit: true)

        let row = tableView.clickedRow
        if row >= 0 {
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            tableView.deselectAll(nil)
        }

        switch (mode, row >= 0) {
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
            menu.add("Paste", #selector(NSText.paste(_:)), key: "v")
            menu.addItem(.separator())
            menu.addItem(MainMenu.newSubmenuItem())
            menu.addItem(.separator())
            menu.add("Refresh", #selector(AppDelegate.refresh(_:)), key: "r")
        case (.recycleBin, true):
            menu.add("Restore", #selector(ExplorerWindowController.restoreSelection(_:)))
            menu.addItem(.separator())
            menu.add("Cut", #selector(NSText.cut(_:)), key: "x")
            menu.add("Delete", #selector(ExplorerWindowController.delete(_:)), key: MainMenu.backspaceKey)
        case (.recycleBin, false):
            menu.add("Empty Recycle Bin", #selector(ExplorerWindowController.emptyRecycleBin(_:)))
            menu.add("Restore all items", #selector(ExplorerWindowController.restoreAll(_:)))
            menu.addItem(.separator())
            menu.add("Refresh", #selector(AppDelegate.refresh(_:)), key: "r")
        case (.volumes, true):
            menu.add("Open", #selector(ExplorerWindowController.openSelection(_:)))
        case (.volumes, false):
            menu.add("Refresh", #selector(AppDelegate.refresh(_:)), key: "r")
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
