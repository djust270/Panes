import AppKit
import ExplorerCore

/// Applies the keyboard scheme (`KeyboardScheme` in ExplorerCore) to menus, and makes
/// Ctrl+click toggle selection under the Windows scheme.
@MainActor
enum KeyboardShortcuts {
    static var scheme: KeyboardScheme { AppSettings.keyboardScheme }

    /// The shortcut a menu shows for `command`, e.g. for tooltips: "Copy (⌃C)".
    static func toolTip(_ title: String, _ command: ExplorerCommand) -> String {
        guard let shortcut = scheme.shortcuts(for: command).first else { return title }
        return "\(title) (\(shortcut))"
    }

    static func keyEquivalent(for key: KeyShortcut.Key) -> String {
        if case .character(let character) = key { return character }
        return specialKeys[key] ?? ""
    }

    /// Key equivalents for keys without a printable character.
    private static let specialKeys: [KeyShortcut.Key: String] = {
        func character(_ code: Int) -> String { String(Character(UnicodeScalar(UInt16(code))!)) }
        return [
            .f2: character(NSF2FunctionKey),
            .f4: character(NSF4FunctionKey),
            .f5: character(NSF5FunctionKey),
            .leftArrow: character(NSLeftArrowFunctionKey),
            .rightArrow: character(NSRightArrowFunctionKey),
            .upArrow: character(NSUpArrowFunctionKey),
            .downArrow: character(NSDownArrowFunctionKey),
            .backspace: "\u{8}",
            .forwardDelete: character(NSDeleteFunctionKey),
            .tab: "\t",
        ]
    }()

    static func modifierFlags(for modifiers: KeyShortcut.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    static func apply(_ shortcut: KeyShortcut?, to item: NSMenuItem) {
        guard let shortcut else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = keyEquivalent(for: shortcut.key)
        item.keyEquivalentModifierMask = modifierFlags(for: shortcut.modifiers)
    }

    // MARK: Event monitors

    private static var mouseMonitor: Any?
    private static var keyMonitor: Any?

    static func installEventMonitors() {
        installControlClickMonitor()
        installShiftedKeyMonitor()
    }

    /// AppKit's key-equivalent matching is unreliable once Shift is involved: it matches
    /// against the *shifted* character, so Ctrl+Shift+1 arrives as "⌃⇧!" and misses "⌃⇧1"; for
    /// digits and symbols it ignores the Shift bit, so plain Ctrl+1 triggers "⌃⇧1"; and with
    /// Control or Option, even Shift+letter misses. So any shortcut with Shift, or with a digit
    /// or symbol, is looked up here by unshifted key (from the current keyboard layout) and
    /// exact modifiers. Other keys are left to AppKit.
    private static func installShiftedKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { result = performExactKeyEquivalent(event) ? nil : event }
            return result
        }
    }

    /// Returns `true` if the event matched a menu item exactly (and was performed, or refused
    /// with a beep if the item is disabled).
    private static func performExactKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard NSApp.modalWindow == nil,
              !flags.isDisjoint(with: [.command, .control, .option]),
              let key = event.characters(byApplyingModifiers: []), let scalar = key.unicodeScalars.first,
              flags.contains(.shift) || !CharacterSet.letters.contains(scalar),
              let mainMenu = NSApp.mainMenu,
              let (menu, index) = findItem(in: mainMenu, key: key.lowercased(), modifiers: flags) else { return false }
        menu.update()
        if menu.items[index].isEnabled {
            menu.performActionForItem(at: index)
        } else {
            NSSound.beep()
        }
        return true
    }

    private static func findItem(
        in menu: NSMenu,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if let submenu = item.submenu {
                if let found = findItem(in: submenu, key: key, modifiers: modifiers) { return found }
            } else if item.keyEquivalent == key,
                      item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == modifiers {
                return (menu, index)
            }
        }
        return nil
    }

    /// Under the Windows scheme, turns Ctrl+click in the file views into ⌘-click, which they
    /// treat as "toggle this item". (On the Mac, Ctrl+click is otherwise a right-click, and it
    /// still is everywhere else, e.g. on tabs.) Ctrl+drag still copies: drop handling reads the
    /// live modifier keys.
    private static func installControlClickMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { event in
            nonisolated(unsafe) var translated = event
            MainActor.assumeIsolated { translated = translateControlClick(translated) }
            return translated
        }
    }

    private static func isOverFileView(_ event: NSEvent) -> Bool {
        guard let frameView = event.window?.contentView?.superview else { return false }
        var view = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is FileTableView || current is FileCollectionView { return true }
            view = current.superview
        }
        return false
    }

    private static func translateControlClick(_ event: NSEvent) -> NSEvent {
        guard scheme.controlClickTogglesSelection,
              event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.command),
              event.window?.windowController is ExplorerWindowController,
              isOverFileView(event) else { return event }
        var flags = event.modifierFlags
        flags.remove(.control)
        flags.insert(.command)
        return NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) ?? event
    }
}

@MainActor
extension NSMenu {
    /// Adds an item with the current scheme's shortcut for `command`. In the main menu
    /// (`alternates: true`), the scheme's other shortcuts are added as hidden items with the
    /// same action, which still respond to their keys.
    @discardableResult
    func add(
        _ title: String,
        _ action: Selector,
        command: ExplorerCommand,
        alternates: Bool = false,
        configure: ((NSMenuItem) -> Void)? = nil
    ) -> NSMenuItem {
        let shortcuts = KeyboardShortcuts.scheme.shortcuts(for: command)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        KeyboardShortcuts.apply(shortcuts.first, to: item)
        configure?(item)
        addItem(item)
        guard alternates else { return item }
        for shortcut in shortcuts.dropFirst() {
            let alternate = NSMenuItem(title: title, action: action, keyEquivalent: "")
            KeyboardShortcuts.apply(shortcut, to: alternate)
            configure?(alternate)
            alternate.isHidden = true
            alternate.allowsKeyEquivalentWhenHidden = true
            addItem(alternate)
        }
        return item
    }
}
