import AppKit
import ExplorerCore
import SwiftUI

/// First-run onboarding for Full Disk Access: why it's needed, how to turn it on, and whether
/// it is. Shown once at first launch when access is off; afterwards from Help, Settings, and
/// folders macOS won't let Explorer open.
@MainActor
final class FullDiskAccessWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FullDiskAccessWindowController()

    private static let shownKey = "FullDiskAccessOnboardingShown"
    private static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private let model = FullDiskAccessModel()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: FullDiskAccessView(model: model)))
        window.title = "Full Disk Access"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        model.onClose = { [weak window] in window?.close() }
        model.onOpenSettings = { NSWorkspace.shared.open(Self.settingsURL) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// At launch: shows the window the first time, if access is off.
    static func showIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey), FullDiskAccess.status() == .denied else { return }
        defaults.set(true, forKey: shownKey)
        shared.show()
    }

    func show() {
        model.startPolling()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc static func showWindow(_ sender: Any?) {
        shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

@MainActor
private final class FullDiskAccessModel: ObservableObject {
    @Published var status = FullDiskAccess.status()
    var onClose: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    private var timer: Timer?

    /// System Settings can't tell us when the switch flips, so check every second.
    func startPolling() {
        status = FullDiskAccess.status()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let status = FullDiskAccess.status()
                if status != self.status { self.status = status }
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

private struct FullDiskAccessView: View {
    @ObservedObject var model: FullDiskAccessModel

    private var isGranted: Bool { model.status == .granted }
    private var bundleURL: URL? { Bundle.main.bundleIdentifier == nil ? nil : Bundle.main.bundleURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let \(AppInfo.name) see all your files")
                        .font(.title2.weight(.semibold))
                    Text("""
                    macOS keeps some places private until you let an app in: the Trash (\(AppInfo.name)’s \
                    Recycle Bin), Mail, Messages, Safari, Time Machine backups and other users’ folders. \
                    \(AppInfo.name) only reads files when you browse to them, and nothing leaves your Mac.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Click Open System Settings.")
                step(2, bundleURL == nil
                     ? "Turn on the app you started \(AppInfo.name) from (such as Terminal) under Full Disk Access."
                     : "Turn on \(AppInfo.name) under Full Disk Access. "
                        + "If it isn’t listed, drag this icon into the list:")
                if let bundleURL {
                    DraggableAppIcon(url: bundleURL)
                        .padding(.leading, 30)
                }
                step(3, "If macOS asks, choose Quit & Reopen.")
            }

            HStack(spacing: 6) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isGranted ? Color.green : Color.secondary)
                Text(isGranted ? "Full Disk Access is on." : "Full Disk Access is off.")
            }
            .accessibilityElement(children: .combine)

            HStack {
                Spacer()
                if isGranted {
                    Button("Done") { model.onClose() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { model.onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open System Settings") { model.onOpenSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The app's icon, draggable into System Settings' Full Disk Access list.
private struct DraggableAppIcon: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(url.deletingPathExtension().lastPathComponent)
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("Drag into the Full Disk Access list")
        .accessibilityLabel("\(AppInfo.name) app icon, draggable into the Full Disk Access list")
    }
}
