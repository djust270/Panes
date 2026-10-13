import Foundation

/// Which family of keyboard shortcuts the app uses: Windows' Ctrl-based keys or the Mac's
/// Cmd-based ones. System shortcuts (⌘Q, ⌘H, ⌘,…) work in both.
///
/// Under the Windows scheme every Mac shortcut keeps working as a hidden alternate, so ⌘C
/// still copies; the menus show the Windows keys. Under the Mac scheme only Windows' function
/// keys (F2, F5…) are added.
public enum KeyboardScheme: String, Sendable, CaseIterable, Codable {
    case windows
    case mac

    public static let `default` = KeyboardScheme.windows

    public var title: String {
        switch self {
        case .windows: return "Windows (Ctrl-based)"
        case .mac: return "Mac (Cmd-based)"
        }
    }

    /// The shortcuts for `command`, the one menus display first. Empty if it has none.
    public func shortcuts(for command: ExplorerCommand) -> [KeyShortcut] {
        switch self {
        case .windows:
            let windows = Self.windowsShortcuts(for: command)
            let mac = Self.macShortcuts(for: command).filter { !windows.contains($0) }
            return windows + mac
        case .mac:
            let mac = Self.macShortcuts(for: command)
            let functionKeys = Self.windowsShortcuts(for: command).filter {
                $0.key.isFunctionKey && $0.modifiers.isEmpty && !mac.contains($0)
            }
            return mac + functionKeys
        }
    }

    /// Ctrl+click toggles an item's selection, as on Windows, instead of opening the context menu.
    public var controlClickTogglesSelection: Bool { self == .windows }

    /// Backspace goes back in the folder history (Windows Vista and later).
    public var backspaceGoesBack: Bool { self == .windows }

    // MARK: Tables

    // swiftlint:disable:next cyclomatic_complexity
    private static func windowsShortcuts(for command: ExplorerCommand) -> [KeyShortcut] {
        let ctrl: KeyShortcut.Modifiers = .control
        switch command {
        case .newWindow: return [.init("n", ctrl)]
        case .newTab: return [.init("t", ctrl)]
        case .closeTab: return [.init("w", ctrl), .init(.f4, ctrl)]
        case .nextTab: return [.init(.tab, ctrl)]
        case .previousTab: return [.init(.tab, [.control, .shift])]
        case .selectTab(let index): return (1...9).contains(index) ? [.init("\(index)", ctrl)] : []
        case .newFolder: return [.init("n", [.control, .shift])]
        case .newTextDocument: return []
        case .open: return []
        case .copyAsPath: return [.init("c", [.control, .shift])]
        case .cut: return [.init("x", ctrl)]
        case .copy: return [.init("c", ctrl)]
        case .paste: return [.init("v", ctrl)]
        case .undo: return [.init("z", ctrl)]
        case .redo: return [.init("y", ctrl), .init("z", [.control, .shift])]
        case .rename: return [.init(.f2)]
        // Del itself is handled by the file views, so it never reaches text fields' menus.
        case .delete: return [.init("d", ctrl)]
        case .deletePermanently: return [.init(.forwardDelete, .shift)]
        case .selectAll: return [.init("a", ctrl)]
        case .selectNone: return [.init("a", [.control, .option])]
        case .invertSelection: return [.init("i", [.control, .shift])]
        case .back: return [.init(.leftArrow, .option)]
        case .forward: return [.init(.rightArrow, .option)]
        case .up: return [.init(.upArrow, .option)]
        case .refresh: return [.init(.f5), .init("r", ctrl)]
        case .focusAddressBar: return [.init("l", ctrl), .init("d", .option), .init(.f4)]
        case .search: return [.init("f", ctrl), .init("e", ctrl), .init(.f3)]
        case .previewPane: return [.init("p", .option)]
        case .detailsPane: return [.init("p", [.option, .shift])]
        case .navigationPane: return []
        case .hiddenFiles: return [.init(".", [.control, .shift])]
        case .viewMode(let index): return (1...8).contains(index) ? [.init("\(index)", [.control, .shift])] : []
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func macShortcuts(for command: ExplorerCommand) -> [KeyShortcut] {
        let cmd: KeyShortcut.Modifiers = .command
        switch command {
        case .newWindow: return [.init("n", cmd)]
        case .newTab: return [.init("t", cmd)]
        case .closeTab: return [.init("w", cmd)]
        case .nextTab: return [.init(.tab, .control), .init("]", [.command, .shift])]
        case .previousTab: return [.init(.tab, [.control, .shift]), .init("[", [.command, .shift])]
        case .selectTab: return []
        case .newFolder: return [.init("n", [.command, .shift])]
        case .newTextDocument: return [.init("n", [.command, .option])]
        case .open: return [.init("o", cmd), .init(.downArrow, cmd)]
        case .copyAsPath: return [.init("c", [.command, .option])]
        case .cut: return [.init("x", cmd)]
        case .copy: return [.init("c", cmd)]
        case .paste: return [.init("v", cmd)]
        case .undo: return [.init("z", cmd)]
        case .redo: return [.init("z", [.command, .shift])]
        case .rename: return [.init(.f2)]
        case .delete: return [.init(.backspace, cmd)]
        case .deletePermanently: return [.init(.backspace, [.command, .option])]
        case .selectAll: return [.init("a", cmd)]
        case .selectNone: return [.init("a", [.command, .option])]
        case .invertSelection: return [.init("i", [.command, .shift])]
        case .back: return [.init("[", cmd)]
        case .forward: return [.init("]", cmd)]
        case .up: return [.init(.upArrow, cmd)]
        case .refresh: return [.init("r", cmd)]
        case .focusAddressBar: return [.init("l", cmd), .init("g", [.command, .shift])]
        case .search: return [.init("f", cmd)]
        case .previewPane: return [.init("p", [.command, .option])]
        case .detailsPane: return [.init("p", [.command, .option, .shift])]
        case .navigationPane: return [.init("s", [.command, .control])]
        case .hiddenFiles: return [.init(".", [.command, .shift])]
        case .viewMode(let index): return (1...8).contains(index) ? [.init("\(index)", cmd)] : []
        }
    }
}

/// A command that can have a keyboard shortcut.
public enum ExplorerCommand: Hashable, Sendable {
    case newWindow, newTab, closeTab, nextTab, previousTab
    /// Ctrl+1…9 under the Windows scheme; 9 selects the last tab.
    case selectTab(Int)
    case newFolder, newTextDocument, open
    case cut, copy, paste, undo, redo, copyAsPath
    case rename, delete, deletePermanently
    case selectAll, selectNone, invertSelection
    case back, forward, up, refresh, focusAddressBar, search
    case previewPane, detailsPane, navigationPane, hiddenFiles
    /// Layout 1…8, in `ViewMode.allCases` order.
    case viewMode(Int)

    public static var allCases: [ExplorerCommand] {
        [
            .newWindow, .newTab, .closeTab, .nextTab, .previousTab,
            .newFolder, .newTextDocument, .open, .cut, .copy, .paste, .undo, .redo, .copyAsPath,
            .rename, .delete, .deletePermanently, .selectAll, .selectNone, .invertSelection,
            .back, .forward, .up, .refresh, .focusAddressBar, .search,
            .previewPane, .detailsPane, .navigationPane, .hiddenFiles,
        ] + (1...9).map(ExplorerCommand.selectTab) + (1...8).map(ExplorerCommand.viewMode)
    }
}

/// A key plus modifiers, independent of AppKit.
public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        /// A printable character, lowercase.
        case character(String)
        case f2, f3, f4, f5
        case leftArrow, rightArrow, upArrow, downArrow
        case backspace, forwardDelete, tab

        public var isFunctionKey: Bool {
            switch self {
            case .f2, .f3, .f4, .f5: return true
            default: return false
            }
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ character: String, _ modifiers: Modifiers = []) {
        self.init(.character(character.lowercased()), modifiers)
    }

    /// Mac-style notation, e.g. "⌃⇧N", for tooltips.
    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += character.uppercased()
        case .f2: text += "F2"
        case .f3: text += "F3"
        case .f4: text += "F4"
        case .f5: text += "F5"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .backspace: text += "⌫"
        case .forwardDelete: text += "⌦"
        case .tab: text += "⇥"
        }
        return text
    }
}
