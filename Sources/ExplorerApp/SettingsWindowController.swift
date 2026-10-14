import AppKit
import ExplorerCore
import SwiftUI

/// Settings (⌘,): General (keyboard scheme, start location, login item, default browser),
/// View (theme, accent, layout and what names show) and Privacy & Updates.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ViewSettings()
                .tabItem { Label("View", systemImage: "eye") }
            PrivacySettings()
                .tabItem { Label("Privacy & Updates", systemImage: "lock.shield") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
}

/// A binding that also writes the new value through `save`.
@MainActor
private func bind<Value: Equatable>(_ state: Binding<Value>, save: @escaping (Value) -> Void) -> Binding<Value> {
    Binding(
        get: { state.wrappedValue },
        set: { value in
            guard value != state.wrappedValue else { return }
            state.wrappedValue = value
            save(value)
        }
    )
}

private struct Caption: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @State private var scheme = AppSettings.keyboardScheme
    @State private var startLocation = AppSettings.startLocation
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var defaultBrowser = SystemIntegration.isDefaultFileBrowser
    @State private var defaultBrowserError: String?

    var body: some View {
        Form {
            Section {
                Picker("Keyboard shortcuts:", selection: bind($scheme) { AppSettings.keyboardScheme = $0 }) {
                    ForEach(KeyboardScheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Caption(scheme == .windows
                        ? "Ctrl+C, Ctrl+V, Ctrl+Z… as on Windows. Ctrl+click selects; ⌘ shortcuts keep working."
                        : "⌘C, ⌘V, ⌘Z… as in Finder. Ctrl+click opens the context menu. F2 and F5 still work.")
            }
            Section {
                Picker("Open \(AppInfo.name) to:", selection: bind($startLocation) { AppSettings.startLocation = $0 }) {
                    ForEach(AppSettings.StartLocation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Start \(AppInfo.name) when you sign in", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        launchAtLoginError = LaunchAtLogin.setEnabled(value)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                .disabled(!LaunchAtLogin.isAvailable)
                if LaunchAtLogin.needsApproval {
                    HStack {
                        Caption("Turned off in System Settings › General › Login Items.")
                        Spacer()
                        Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                    }
                } else {
                    Caption(launchAtLoginError ?? (LaunchAtLogin.isAvailable
                        ? "Mapped network drives set to reconnect are reconnected when you sign in."
                        : "Available when \(AppInfo.name) runs from its app bundle."),
                            isError: launchAtLoginError != nil)
                }
                Toggle("Open folders and “Show in Finder” in \(AppInfo.name)", isOn: Binding(
                    get: { defaultBrowser },
                    set: { value in
                        defaultBrowser = value
                        Task { @MainActor in
                            defaultBrowserError = await SystemIntegration.setDefaultFileBrowser(value)
                            defaultBrowser = SystemIntegration.isDefaultFileBrowser
                        }
                    }
                ))
                .disabled(!SystemIntegration.canBeDefault)
                Caption(defaultBrowserError ?? (SystemIntegration.canBeDefault
                    ? "Makes \(AppInfo.name) the default file browser for every app. Finder still shows the Desktop."
                    : "Available when \(AppInfo.name) runs from its app bundle."), isError: defaultBrowserError != nil)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.didChangeNotification)) { _ in
            // Picks up changes made from menus while the window is open.
            scheme = AppSettings.keyboardScheme
            startLocation = AppSettings.startLocation
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

private struct ViewSettings: View {
    @State private var style = AppSettings.visualStyle
    @State private var appearance = AppSettings.appearance
    @State private var accent = AppSettings.accent
    @State private var captionButtons = AppSettings.windowsCaptionButtons
    @State private var compactView = AppSettings.compactView
    @State private var classicMenu = AppSettings.classicContextMenu
    @State private var hiddenFiles = AppSettings.showsHiddenFiles
    @State private var fileExtensions = AppSettings.showsFileExtensions
    @State private var driveLetters = AppSettings.showsDriveLetters

    var body: some View {
        Form {
            Section {
                Picker("Style:", selection: bind($style) { AppSettings.visualStyle = $0 }) {
                    ForEach(AppSettings.VisualStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Theme:", selection: bind($appearance) { AppSettings.appearance = $0 }) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(style == .classic)
                LabeledContent("Accent colour:") {
                    AccentPicker(selection: bind($accent) { AppSettings.accent = $0 })
                }
                .disabled(style == .classic)
                if style == .classic {
                    Caption("Windows 98 is always light, with navy selection.")
                }
                Toggle("Window buttons on the right (Windows style)",
                       isOn: bind($captionButtons) { AppSettings.windowsCaptionButtons = $0 })
                Toggle("Compact view", isOn: bind($compactView) { AppSettings.compactView = $0 })
                Toggle("Classic context menu (Windows 10 style)",
                       isOn: bind($classicMenu) { AppSettings.classicContextMenu = $0 })
                Caption("Shows every command when you right-click, without “Show more options”. "
                        + "Holding Shift while right-clicking shows it either way.")
            }
            Section {
                Toggle("Show file name extensions",
                       isOn: bind($fileExtensions) { AppSettings.showsFileExtensions = $0 })
                Toggle("Show hidden items", isOn: bind($hiddenFiles) { AppSettings.showsHiddenFiles = $0 })
                Toggle("Show drive letters (C:, D:…)",
                       isOn: bind($driveLetters) { AppSettings.showsDriveLetters = $0 })
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.didChangeNotification)) { _ in
            style = AppSettings.visualStyle
            appearance = AppSettings.appearance
            accent = AppSettings.accent
            captionButtons = AppSettings.windowsCaptionButtons
            compactView = AppSettings.compactView
            classicMenu = AppSettings.classicContextMenu
            hiddenFiles = AppSettings.showsHiddenFiles
            fileExtensions = AppSettings.showsFileExtensions
            driveLetters = AppSettings.showsDriveLetters
        }
    }
}

private struct PrivacySettings: View {
    @State private var fullDiskAccess = FullDiskAccess.status()
    @State private var automaticChecks = Updater.shared.automaticallyChecks
    @State private var automaticDownloads = Updater.shared.automaticallyDownloads
    @State private var betaUpdates = AppSettings.receivesBetaUpdates
    @State private var crashReports = AppSettings.offersCrashReports

    var body: some View {
        Form {
            Section {
                LabeledContent("Full Disk Access:") {
                    HStack {
                        Text(fullDiskAccess == .granted ? "On" : "Off")
                            .foregroundStyle(.secondary)
                        Button(fullDiskAccess == .granted ? "Details…" : "Set Up…") {
                            FullDiskAccessWindowController.shared.show()
                        }
                    }
                }
                Caption("Lets \(AppInfo.name) show the Recycle Bin, Mail, Messages, Safari and Time Machine folders.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: bind($automaticChecks) {
                    Updater.shared.automaticallyChecks = $0
                })
                Toggle("Download and install updates automatically", isOn: bind($automaticDownloads) {
                    Updater.shared.automaticallyDownloads = $0
                })
                .disabled(!automaticChecks)
                Toggle("Get beta updates", isOn: bind($betaUpdates) {
                    AppSettings.receivesBetaUpdates = $0
                    Updater.shared.channelDidChange()
                })
                HStack {
                    Caption(Updater.shared.isAvailable
                            ? "Version \(AppInfo.version) (\(AppInfo.build)). Betas get new features first."
                            : "Updates are available in release builds of \(AppInfo.name).")
                    Spacer()
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
            }
            .disabled(!Updater.shared.isAvailable)
            Section {
                Toggle("Offer to report crashes", isOn: bind($crashReports) { AppSettings.offersCrashReports = $0 })
                Caption("After a crash, \(AppInfo.name) offers to open a GitHub issue with a summary for you "
                        + "to review. Nothing is sent automatically.")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = FullDiskAccess.status()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.didChangeNotification)) { _ in
            crashReports = AppSettings.offersCrashReports
        }
    }
}

/// Windows-style accent swatches, plus "Match macOS".
private struct AccentPicker: View {
    @Binding var selection: AccentChoice

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AccentChoice.allCases, id: \.self) { choice in
                Button {
                    selection = choice
                } label: {
                    swatch(choice)
                }
                .buttonStyle(.plain)
                .help(choice.title)
                .accessibilityLabel(choice.title)
            }
        }
    }

    @ViewBuilder
    private func swatch(_ choice: AccentChoice) -> some View {
        let isSelected = selection == choice
        ZStack {
            if choice == .system {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red],
                                              center: .center))
            } else {
                Circle().fill(Color(nsColor: choice.color))
            }
            if isSelected {
                Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
            }
        }
        .frame(width: 18, height: 18)
        .padding(3)
    }
}
