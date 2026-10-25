import AppKit
import ExplorerCore

/// The sync clients' folders (OneDrive, iCloud Drive, Google Drive, Dropbox…), and a
/// notification whenever one appears or goes, e.g. when an account is added or removed.
@MainActor
enum CloudCenter {
    static let didChangeNotification = Notification.Name("CloudCenterDidChange")

    /// The cloud folders as last read.
    private(set) static var roots = CloudStorage.roots()
    private static var watchTask: Task<Void, Never>?
    private static var activationObserver: NSObjectProtocol?

    /// Starts following `~/Library/CloudStorage`. Called once at launch.
    static func start() {
        guard watchTask == nil else { return }
        let watcher = DirectoryWatcher(directory: CloudStorage.fileProviderFolder, latency: 1)
        watchTask = Task {
            for await _ in watcher.start() {
                refresh()
            }
        }
        // iCloud Drive is outside that folder, and the folder may not exist yet: check again
        // whenever the app comes forward.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }

    /// Re-reads the cloud folders, notifying observers if they changed.
    static func refresh() {
        let updated = CloudStorage.roots()
        guard updated != roots else { return }
        roots = updated
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Calls `body` after every change, until the returned token is released.
    static func observe(_ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
}
