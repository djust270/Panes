import AppKit
import ExplorerCore

/// The app's Quick access, Favorites and Recent (`QuickAccessStore`). Changes that Home or the
/// navigation pane show post `didChangeNotification`; folder visits don't, since they only
/// reorder frequent folders and Home re-reads those whenever it's shown.
@MainActor
enum QuickAccess {
    static let didChangeNotification = Notification.Name("QuickAccessDidChange")

    static let store = QuickAccessStore()

    static func change(_ body: (QuickAccessStore) -> Void) {
        body(store)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func recordVisit(to folder: URL) {
        store.recordVisit(to: folder)
    }

    /// Files opened from the app show up in Home's Recent.
    static func recordOpen(of files: [URL]) {
        guard !files.isEmpty else { return }
        change { store in files.forEach { store.recordOpen(of: $0) } }
    }

    /// Calls `body` after every change, until the returned token is released.
    static func observe(_ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
}
