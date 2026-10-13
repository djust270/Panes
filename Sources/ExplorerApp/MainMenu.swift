import AppKit
import ExplorerCore

/// Builds the menu bar in code (there is no nib/storyboard in a SwiftPM app). Shortcuts come
/// from the keyboard scheme; the menu bar is rebuilt when the scheme changes.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu: appMenu())
        mainMenu.addItem(submenu: fileMenu())
        mainMenu.addItem(submenu: editMenu())
        mainMenu.addItem(submenu: viewMenu())
        mainMenu.addItem(submenu: goMenu())

        let window = windowMenu()
        mainMenu.addItem(submenu: window)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        mainMenu.addItem(submenu: help)
        NSApp.helpMenu = help

        return mainMenu
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu: services)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others",
                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.add("New Window", #selector(AppDelegate.newWindow(_:)), command: .newWindow, alternates: true)
        menu.add("New Tab", #selector(ExplorerWindowController.newTab(_:)), command: .newTab, alternates: true)
        let new = NSMenu(title: "New")
        for item in newItems(alternates: true) { new.addItem(item) }
        menu.addItem(submenu: new)
        menu.addItem(.separator())
        menu.add("Open", #selector(ExplorerTabController.openSelection(_:)), command: .open, alternates: true)
        menu.add("Open in New Tab", #selector(ExplorerTabController.openInNewTab(_:)), modifiers: [])
        menu.add("Open in New Window", #selector(ExplorerTabController.openInNewWindow(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Compress to ZIP File", #selector(ExplorerTabController.compressSelection(_:)), modifiers: [])
        menu.add("Extract All…", #selector(ExplorerTabController.extractAll(_:)), modifiers: [])
        menu.add("Open in Terminal", #selector(ExplorerTabController.openInTerminal(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Properties", #selector(ExplorerTabController.showProperties(_:)), command: .properties,
                 alternates: true)
        menu.addItem(.separator())
        menu.add("Restore", #selector(ExplorerTabController.restoreSelection(_:)))
        menu.add("Empty Recycle Bin…", #selector(ExplorerTabController.emptyRecycleBin(_:)))
        menu.addItem(.separator())
        menu.add("Close Tab", #selector(ExplorerWindowController.closeTab(_:)), command: .closeTab, alternates: true)
        menu.add("Close Window", #selector(NSWindow.performClose(_:)), key: "w", modifiers: [.command, .shift])
        return menu
    }

    /// "Folder / Text Document", for File › New, the command bar's New ▾ and the background
    /// context menu.
    static func newItems(alternates: Bool = false) -> [NSMenuItem] {
        let menu = NSMenu()
        menu.add("Folder", #selector(ExplorerTabController.newFolder(_:)), command: .newFolder, alternates: alternates)
        menu.add("Text Document", #selector(ExplorerTabController.newTextDocument(_:)), command: .newTextDocument,
                 alternates: alternates)
        return menu.detachItems()
    }

    /// "New ▸", for the background context menu.
    static func newSubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "New")
        newItems().forEach(submenu.addItem)
        return submenuItem(submenu)
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.add("Undo", Selector(("undo:")), command: .undo, alternates: true)
        menu.add("Redo", Selector(("redo:")), command: .redo, alternates: true)
        menu.addItem(.separator())
        menu.add("Cut", #selector(NSText.cut(_:)), command: .cut, alternates: true)
        menu.add("Copy", #selector(NSText.copy(_:)), command: .copy, alternates: true)
        menu.add("Paste", #selector(NSText.paste(_:)), command: .paste, alternates: true)
        menu.add("Copy as Path", #selector(ExplorerTabController.copyAsPath(_:)), command: .copyAsPath,
                 alternates: true)
        menu.add("Copy as Windows Path", #selector(ExplorerTabController.copyAsWindowsPath(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Copy to Other Pane", #selector(ExplorerTabController.copyToOtherPane(_:)), modifiers: [])
        menu.add("Move to Other Pane", #selector(ExplorerTabController.moveToOtherPane(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Rename", #selector(ExplorerTabController.renameSelection(_:)), command: .rename, alternates: true)
        menu.add("Delete", #selector(ExplorerTabController.delete(_:)), command: .delete, alternates: true)
        menu.add("Delete Permanently…", #selector(ExplorerTabController.deletePermanently(_:)),
                 command: .deletePermanently, alternates: true)
        menu.addItem(.separator())
        menu.add("Select All", #selector(NSText.selectAll(_:)), command: .selectAll, alternates: true)
        menu.add("Select None", #selector(ExplorerTabController.selectNone(_:)), command: .selectNone,
                 alternates: true)
        menu.add("Invert Selection", #selector(ExplorerTabController.invertSelection(_:)),
                 command: .invertSelection, alternates: true)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        viewModeItems(alternates: true).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(sortBySubmenuItem())
        menu.addItem(groupBySubmenuItem())
        let filter = NSMenu(title: "Filter")
        filterItems().forEach(filter.addItem)
        menu.addItem(submenuItem(filter))
        menu.addItem(.separator())
        menu.add("Navigation Pane", #selector(ExplorerTabController.toggleNavigationPane(_:)),
                 command: .navigationPane, alternates: true)
        menu.add("Preview Pane", #selector(ExplorerTabController.togglePreviewPane(_:)), command: .previewPane,
                 alternates: true)
        menu.add("Details Pane", #selector(ExplorerTabController.toggleDetailsPane(_:)), command: .detailsPane,
                 alternates: true)
        menu.add("Dual Pane", #selector(AppDelegate.toggleDualPane(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Compact View", #selector(AppDelegate.toggleCompactView(_:)), modifiers: [])
        menu.add("Item Check Boxes", #selector(ExplorerTabController.toggleItemCheckboxes(_:)), modifiers: [])
        menu.add("Hidden Items", #selector(AppDelegate.toggleHiddenFiles(_:)), command: .hiddenFiles,
                 alternates: true)
        menu.addItem(.separator())
        menu.add("Apply View to All Folders", #selector(ExplorerTabController.applyViewToAllFolders(_:)),
                 modifiers: [])
        menu.add("Reset All Folders…", #selector(ExplorerTabController.resetAllFolders(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Refresh", #selector(ExplorerTabController.refresh(_:)), command: .refresh, alternates: true)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.add("Back", #selector(ExplorerTabController.goBack(_:)), command: .back, alternates: true)
        menu.add("Forward", #selector(ExplorerTabController.goForward(_:)), command: .forward, alternates: true)
        menu.add("Up", #selector(ExplorerTabController.goUp(_:)), command: .up, alternates: true)
        menu.addItem(.separator())
        menu.add("Edit Address", #selector(ExplorerTabController.editAddress(_:)), command: .focusAddressBar,
                 alternates: true)
        menu.add("Search", #selector(ExplorerTabController.focusSearch(_:)), command: .search, alternates: true)
        menu.add("Switch to Other Pane", #selector(ExplorerTabController.switchPane(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Home", #selector(ExplorerTabController.goHome(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.add("Map Network Drive…", #selector(ExplorerTabController.mapNetworkDrive(_:)), modifiers: [])
        return menu
    }

    /// The eight layouts: Ctrl+Shift+1…8 as on Windows, or ⌘1…8 under the Mac scheme (where
    /// ⌘⇧3–5 are screenshots). The tag is the mode's index in `ViewMode.allCases`.
    static func viewModeItems(alternates: Bool = false) -> [NSMenuItem] {
        let menu = NSMenu()
        for (index, mode) in ViewMode.allCases.enumerated() {
            menu.add(mode.title, #selector(ExplorerTabController.chooseViewMode(_:)), command: .viewMode(index + 1),
                     alternates: alternates) { $0.tag = index }
        }
        return menu.detachItems()
    }

    /// "View ▸" for the background context menu.
    static func viewSubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "View")
        viewModeItems().forEach(submenu.addItem)
        return submenuItem(submenu)
    }

    /// "Name, Date modified, … / Ascending, Descending". Recycle Bin–only keys are hidden
    /// elsewhere during validation.
    static func sortItems() -> [NSMenuItem] {
        let menu = NSMenu()
        for key in FileItemSortKey.allCases {
            let item = menu.add(key.title, #selector(ExplorerTabController.sortBy(_:)), modifiers: [])
            item.representedObject = key.rawValue
        }
        menu.addItem(.separator())
        menu.add("Ascending", #selector(ExplorerTabController.setSortOrder(_:)), modifiers: []).tag = 1
        menu.add("Descending", #selector(ExplorerTabController.setSortOrder(_:)), modifiers: []).tag = 0
        return menu.detachItems()
    }

    /// "Sort by ▸".
    static func sortBySubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Sort by")
        sortItems().forEach(submenu.addItem)
        return submenuItem(submenu)
    }

    /// "Group by ▸ Name, Date modified, … / (None) / Ascending, Descending".
    static func groupBySubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Group by")
        for key in FileGroupKey.allCases {
            let item = submenu.add(key.title, #selector(ExplorerTabController.groupBy(_:)), modifiers: [])
            item.representedObject = key.rawValue
        }
        submenu.add("(None)", #selector(ExplorerTabController.groupBy(_:)), modifiers: [])
        submenu.addItem(.separator())
        submenu.add("Ascending", #selector(ExplorerTabController.setGroupOrder(_:)), modifiers: []).tag = 1
        submenu.add("Descending", #selector(ExplorerTabController.setGroupOrder(_:)), modifiers: []).tag = 0
        return submenuItem(submenu)
    }

    /// "Folders, Documents, … / Clear filter".
    static func filterItems() -> [NSMenuItem] {
        let menu = NSMenu()
        for kind in FileKind.allCases {
            let item = menu.add(kind.title, #selector(ExplorerTabController.filterByKind(_:)), modifiers: [])
            item.representedObject = kind.rawValue
        }
        menu.addItem(.separator())
        menu.add("Clear filter", #selector(ExplorerTabController.filterByKind(_:)), modifiers: [])
        return menu.detachItems()
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.add("Show Next Tab", #selector(ExplorerWindowController.showNextTab(_:)), command: .nextTab,
                 alternates: true)
        menu.add("Show Previous Tab", #selector(ExplorerWindowController.showPreviousTab(_:)), command: .previousTab,
                 alternates: true)
        for index in 1...9 where !KeyboardShortcuts.scheme.shortcuts(for: .selectTab(index)).isEmpty {
            let item = menu.add("Show Tab \(index)", #selector(ExplorerWindowController.showTabAtIndex(_:)),
                                command: .selectTab(index)) { $0.tag = index }
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        menu.add("Duplicate Tab", #selector(ExplorerWindowController.duplicateTab(_:)), modifiers: [])
        menu.add("Move Tab to New Window", #selector(ExplorerWindowController.moveTabToNewWindow(_:)), modifiers: [])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension NSMenu {
    /// Removes and returns all items, for building item lists with the `add` helpers.
    func detachItems() -> [NSMenuItem] {
        let detached = items
        removeAllItems()
        return detached
    }
}
