import AppKit
import ExplorerCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [ExplorerWindowController] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        openWindow(at: .folder(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        let location = activeWindowController?.history.current
            ?? .folder(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
        openWindow(at: location)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        guard let controller = activeWindowController else { return }
        controller.setShowsHiddenFiles(!controller.showsHiddenFiles)
    }

    @objc func refresh(_ sender: Any?) {
        activeWindowController?.refresh()
    }

    private var activeWindowController: ExplorerWindowController? {
        windowControllers.first { $0.window == NSApp.keyWindow }
    }

    private func openWindow(at location: ExplorerLocation) {
        let controller = ExplorerWindowController(location: location)
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHiddenFiles(_:)) {
            menuItem.state = (activeWindowController?.showsHiddenFiles ?? false) ? .on : .off
        }
        return true
    }
}
