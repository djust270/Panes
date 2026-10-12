import AppKit
import ExplorerCore
import SwiftUI

/// Settings (⌘,): keyboard scheme, theme, accent colour, caption buttons and view options.
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
    @State private var scheme = AppSettings.keyboardScheme
    @State private var appearance = AppSettings.appearance
    @State private var accent = AppSettings.accent
    @State private var captionButtons = AppSettings.windowsCaptionButtons
    @State private var compactView = AppSettings.compactView
    @State private var hiddenFiles = AppSettings.showsHiddenFiles

    var body: some View {
        Form {
            Section {
                Picker("Keyboard shortcuts:", selection: bind($scheme) { AppSettings.keyboardScheme = $0 }) {
                    ForEach(KeyboardScheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(scheme == .windows
                     ? "Ctrl+C, Ctrl+V, Ctrl+Z… as on Windows. Ctrl+click selects; ⌘ shortcuts keep working."
                     : "⌘C, ⌘V, ⌘Z… as in Finder. Ctrl+click opens the context menu. F2 and F5 still work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Theme:", selection: bind($appearance) { AppSettings.appearance = $0 }) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Accent colour:") {
                    AccentPicker(selection: bind($accent) { AppSettings.accent = $0 })
                }
            }
            Section {
                Toggle("Window buttons on the right (Windows style)",
                       isOn: bind($captionButtons) { AppSettings.windowsCaptionButtons = $0 })
                Toggle("Compact view", isOn: bind($compactView) { AppSettings.compactView = $0 })
                Toggle("Show hidden items", isOn: bind($hiddenFiles) { AppSettings.showsHiddenFiles = $0 })
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.didChangeNotification)) { _ in
            // Picks up changes made from menus while the window is open.
            scheme = AppSettings.keyboardScheme
            appearance = AppSettings.appearance
            accent = AppSettings.accent
            captionButtons = AppSettings.windowsCaptionButtons
            compactView = AppSettings.compactView
            hiddenFiles = AppSettings.showsHiddenFiles
        }
    }

    /// A binding that also writes the new value through `save`.
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
