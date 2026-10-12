import AppKit

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
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Show Navigation Pane",
                     action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Hidden Files",
                     action: #selector(AppDelegate.toggleHiddenFiles(_:)), keyEquivalent: ".")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refresh(_:)), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        return menu
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
