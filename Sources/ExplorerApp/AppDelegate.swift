import AppKit
import ExplorerCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [ExplorerWindowController] = []
    private var settingsObserver: NSObjectProtocol?
    private var menuScheme: KeyboardScheme?

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate // swiftlint:disable:this force_cast
    }

    /// Where new windows and tabs open: Home unless changed in Settings.
    static var newTabLocation: ExplorerLocation {
        AppSettings.startLocation.location
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        settingsObserver = AppSettings.observe { [weak self] in self?.applySettings() }
        KeyboardShortcuts.installEventMonitors()
        openWindow(at: Self.newTabLocation)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rebuilds the menu bar when the keyboard scheme changes, and applies the theme.
    private func applySettings() {
        Theme.applyAppearance()
        let scheme = AppSettings.keyboardScheme
        guard scheme != menuScheme else { return }
        menuScheme = scheme
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Another app may have replaced the clipboard, ending a pending cut.
        FileClipboard.shared.refresh()
    }

    /// Quitting mid-operation cancels it and waits for the cleanup (partial copies are removed)
    /// rather than leaving half-written files behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let center = FileOperationCenter.shared
        guard center.hasRunningOperations else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "File operations are still in progress."
        alert.informativeText = "If you quit now, they will be cancelled."
        alert.addButton(withTitle: "Cancel Operations and Quit")
        alert.addButton(withTitle: "Don’t Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        center.cancelAll()
        Task {
            while center.hasRunningOperations {
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Commands

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: Self.newTabLocation)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        AppSettings.showsHiddenFiles.toggle()
    }

    @objc func toggleCompactView(_ sender: Any?) {
        AppSettings.compactView.toggle()
    }

    // MARK: Windows

    func openWindow(at location: ExplorerLocation) {
        show(ExplorerWindowController(location: location))
    }

    /// Opens a window for a tab dragged out of another window.
    func openWindow(with tab: ExplorerTabController, frame: NSRect) {
        show(ExplorerWindowController(tabs: [tab], frame: frame))
    }

    private func show(_ controller: ExplorerWindowController) {
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = AppSettings.showsHiddenFiles ? .on : .off
        case #selector(toggleCompactView(_:)):
            menuItem.state = AppSettings.compactView ? .on : .off
        default:
            break
        }
        return true
    }
}
