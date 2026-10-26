import AppKit
import ExplorerCore

/// App-wide preferences, stored in `UserDefaults`. Changes post `didChangeNotification`.
@MainActor
enum AppSettings {
    static let didChangeNotification = Notification.Name("AppSettingsDidChange")

    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return "Use system setting"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    /// The look of the window: today's Windows 11, or Windows 98's grey 3D one.
    enum VisualStyle: String, CaseIterable {
        case fluent, classic

        var title: String {
            switch self {
            case .fluent: return "Windows 11"
            case .classic: return "Windows 98"
            }
        }
    }

    /// Windows' "Open File Explorer to": where new windows and tabs start.
    enum StartLocation: String, CaseIterable {
        case home, thisPC, homeFolder

        var title: String {
            switch self {
            case .home: return "Home"
            case .thisPC: return "This PC"
            case .homeFolder: return "Your home folder"
            }
        }

        var location: ExplorerLocation {
            switch self {
            case .home: return .home
            case .thisPC: return .thisPC
            case .homeFolder: return .folder(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
            }
        }
    }

    private enum Key {
        static let keyboardScheme = "KeyboardScheme"
        static let appearance = "Appearance"
        static let visualStyle = AppSettings.visualStyleKey
        static let accent = "AccentColor"
        static let captionButtons = "WindowsCaptionButtons"
        static let hiddenFiles = "ShowHiddenFiles"
        static let fileExtensions = "ShowFileExtensions"
        static let compactView = "CompactView"
        static let startLocation = "StartLocation"
        static let driveLetters = "ShowDriveLetters"
        static let dualPane = "DualPane"
        static let crashReports = "OfferCrashReports"
        static let classicContextMenu = "ClassicContextMenu"
        static let cloudDeleteWarning = "WarnBeforeCloudDelete"
    }

    /// Read by colour providers off the main thread (`Theme.isClassic`).
    nonisolated static let visualStyleKey = "VisualStyle"

    /// Read by the updater off the main thread.
    nonisolated static let betaUpdatesKey = "BetaUpdates"

    private static var defaults: UserDefaults { .standard }

    static var keyboardScheme: KeyboardScheme {
        get { defaults.string(forKey: Key.keyboardScheme).flatMap(KeyboardScheme.init) ?? .default }
        set { set(newValue.rawValue, for: Key.keyboardScheme) }
    }

    static var appearance: Appearance {
        get { defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system }
        set { set(newValue.rawValue, for: Key.appearance) }
    }

    static var visualStyle: VisualStyle {
        get { defaults.string(forKey: Key.visualStyle).flatMap(VisualStyle.init) ?? .fluent }
        set { set(newValue.rawValue, for: Key.visualStyle) }
    }

    static var accent: AccentChoice {
        get { defaults.string(forKey: Key.accent).flatMap(AccentChoice.init) ?? .system }
        set { set(newValue.rawValue, for: Key.accent) }
    }

    /// Windows-style minimise / maximise / close buttons on the right of the tab strip,
    /// instead of the traffic lights.
    static var windowsCaptionButtons: Bool {
        get { defaults.bool(forKey: Key.captionButtons) }
        set { set(newValue, for: Key.captionButtons) }
    }

    /// Windows' View › Show › Hidden items; app-wide, as on Windows.
    static var showsHiddenFiles: Bool {
        get { defaults.bool(forKey: Key.hiddenFiles) }
        set { set(newValue, for: Key.hiddenFiles) }
    }

    /// Windows' View › Show › File name extensions. Off by default, as on Windows: known
    /// extensions are hidden from names (and kept when renaming).
    static var showsFileExtensions: Bool {
        get { defaults.bool(forKey: Key.fileExtensions) }
        set { set(newValue, for: Key.fileExtensions) }
    }

    /// The Windows 10-style right-click menu, every command at once, instead of Windows 11's
    /// compact one with "Show more options". Off by default.
    static var classicContextMenu: Bool {
        get { defaults.bool(forKey: Key.classicContextMenu) }
        set { set(newValue, for: Key.classicContextMenu) }
    }

    /// Windows' View › Compact view: tighter rows in Details and the navigation pane.
    static var compactView: Bool {
        get { defaults.bool(forKey: Key.compactView) }
        set { set(newValue, for: Key.compactView) }
    }

    static var startLocation: StartLocation {
        get { defaults.string(forKey: Key.startLocation).flatMap(StartLocation.init) ?? .home }
        set { set(newValue.rawValue, for: Key.startLocation) }
    }

    /// Drive letters after volume names ("Macintosh HD (C:)"), as on Windows. Off by default.
    static var showsDriveLetters: Bool {
        get { defaults.bool(forKey: Key.driveLetters) }
        set { set(newValue, for: Key.driveLetters) }
    }

    /// A second, independent pane beside the current tab, for copying between folders.
    static var dualPane: Bool {
        get { defaults.bool(forKey: Key.dualPane) }
        set { set(newValue, for: Key.dualPane) }
    }

    /// Offer to report a crash on the next launch (on by default).
    static var offersCrashReports: Bool {
        get { defaults.object(forKey: Key.crashReports) as? Bool ?? true }
        set { set(newValue, for: Key.crashReports) }
    }

    /// Warn that deleting from a cloud folder deletes in the cloud too, until "Don't show this
    /// again" (on by default).
    static var warnsBeforeCloudDelete: Bool {
        get { defaults.object(forKey: Key.cloudDeleteWarning) as? Bool ?? true }
        set { set(newValue, for: Key.cloudDeleteWarning) }
    }

    /// Updates from the beta channel as well as stable releases.
    static var receivesBetaUpdates: Bool {
        get { defaults.bool(forKey: betaUpdatesKey) }
        set { set(newValue, for: betaUpdatesKey) }
    }

    private static func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Calls `body` now and after every settings change, until the returned token is released.
    static func observe(_ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        body()
        return NotificationCenter.default.addObserver(forName: didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
}

/// Windows' accent colour choices, or the Mac's own accent colour.
enum AccentChoice: String, CaseIterable {
    case system, blue, navy, purple, plum, red, orange, gold, green, teal, graphite

    var title: String {
        switch self {
        case .system: return "Match macOS"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// The colour, from the Windows accent palette (hex values from Settings › Personalization).
    var color: NSColor {
        switch self {
        case .system: return .controlAccentColor
        case .blue: return NSColor(hex: 0x0078D4)
        case .navy: return NSColor(hex: 0x0063B1)
        case .purple: return NSColor(hex: 0x744DA9)
        case .plum: return NSColor(hex: 0x881798)
        case .red: return NSColor(hex: 0xE81123)
        case .orange: return NSColor(hex: 0xF7630C)
        case .gold: return NSColor(hex: 0xFFB900)
        case .green: return NSColor(hex: 0x107C10)
        case .teal: return NSColor(hex: 0x00B7C3)
        case .graphite: return NSColor(hex: 0x7A7574)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A colour that resolves differently in light and dark appearances.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
