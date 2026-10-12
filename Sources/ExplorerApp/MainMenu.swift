import AppKit
import ExplorerCore

/// Builds the menu bar in code (there is no nib/storyboard in a SwiftPM app).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu: appMenu())
        mainMenu.addItem(submenu: fileMenu())
        mainMenu.addItem(submenu: editMenu())
        mainMenu.addItem(submenu: viewMenu())

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
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
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

    /// Key equivalents for keys without a printable character.
    static let f2Key = String(UnicodeScalar(UInt16(NSF2FunctionKey)).map(Character.init) ?? " ")
    static let backspaceKey = "\u{8}"

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        menu.addItem(newSubmenuItem())
        menu.addItem(.separator())
        menu.add("Open", #selector(ExplorerWindowController.openSelection(_:)), key: "o")
        menu.addItem(.separator())
        menu.add("Restore", #selector(ExplorerWindowController.restoreSelection(_:)))
        menu.add("Empty Recycle Bin…", #selector(ExplorerWindowController.emptyRecycleBin(_:)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    /// "New ▸ Folder / Text Document", shared by the File menu and the background context menu.
    static func newSubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "New")
        submenu.add("Folder", #selector(ExplorerWindowController.newFolder(_:)), key: "n",
                    modifiers: [.command, .shift])
        submenu.add("Text Document", #selector(ExplorerWindowController.newTextDocument(_:)), key: "n",
                    modifiers: [.command, .option])
        let item = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.add("Rename", #selector(ExplorerWindowController.renameSelection(_:)), key: f2Key, modifiers: [])
        menu.add("Delete", #selector(ExplorerWindowController.delete(_:)), key: backspaceKey)
        menu.add("Delete Permanently…", #selector(ExplorerWindowController.deletePermanently(_:)), key: backspaceKey,
                 modifiers: [.command, .option])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.add("Select None", #selector(ExplorerWindowController.selectNone(_:)), key: "a",
                 modifiers: [.command, .option])
        menu.add("Invert Selection", #selector(ExplorerWindowController.invertSelection(_:)), key: "i",
                 modifiers: [.command, .shift])
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        viewModeItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(sortBySubmenuItem())
        menu.addItem(groupBySubmenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Navigation Pane",
                     action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        menu.add("Preview Pane", #selector(ExplorerWindowController.togglePreviewPane(_:)), key: "p",
                 modifiers: [.command, .option])
        menu.add("Details Pane", #selector(ExplorerWindowController.toggleDetailsPane(_:)), key: "p",
                 modifiers: [.command, .option, .shift])
        menu.add("Item Check Boxes", #selector(ExplorerWindowController.toggleItemCheckboxes(_:)))
        menu.addItem(withTitle: "Show Hidden Files",
                     action: #selector(AppDelegate.toggleHiddenFiles(_:)), keyEquivalent: ".")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.add("Apply View to All Folders", #selector(ExplorerWindowController.applyViewToAllFolders(_:)))
        menu.add("Reset All Folders…", #selector(ExplorerWindowController.resetAllFolders(_:)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refresh(_:)), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    /// The eight layouts, ⌘1…⌘8 (Windows uses Ctrl+Shift+1…8; ⌘⇧3–5 are taken by
    /// screenshots on the Mac). The tag is the mode's index in `ViewMode.allCases`.
    static func viewModeItems() -> [NSMenuItem] {
        ViewMode.allCases.enumerated().map { index, mode in
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(ExplorerWindowController.chooseViewMode(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.tag = index
            return item
        }
    }

    /// "View ▸" for the background context menu.
    static func viewSubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "View")
        viewModeItems().forEach(submenu.addItem)
        return submenuItem(submenu)
    }

    /// "Sort by ▸ Name, Date modified, … / Ascending, Descending". Recycle Bin–only keys are
    /// hidden elsewhere during validation.
    static func sortBySubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Sort by")
        for key in FileItemSortKey.allCases {
            let item = submenu.add(key.title, #selector(ExplorerWindowController.sortBy(_:)), modifiers: [])
            item.representedObject = key.rawValue
        }
        submenu.addItem(.separator())
        submenu.add("Ascending", #selector(ExplorerWindowController.setSortOrder(_:)), modifiers: []).tag = 1
        submenu.add("Descending", #selector(ExplorerWindowController.setSortOrder(_:)), modifiers: []).tag = 0
        return submenuItem(submenu)
    }

    /// "Group by ▸ Name, Date modified, … / (None) / Ascending, Descending".
    static func groupBySubmenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Group by")
        for key in FileGroupKey.allCases {
            let item = submenu.add(key.title, #selector(ExplorerWindowController.groupBy(_:)), modifiers: [])
            item.representedObject = key.rawValue
        }
        submenu.add("(None)", #selector(ExplorerWindowController.groupBy(_:)), modifiers: [])
        submenu.addItem(.separator())
        submenu.add("Ascending", #selector(ExplorerWindowController.setGroupOrder(_:)), modifiers: []).tag = 1
        submenu.add("Descending", #selector(ExplorerWindowController.setGroupOrder(_:)), modifiers: []).tag = 0
        return submenuItem(submenu)
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
