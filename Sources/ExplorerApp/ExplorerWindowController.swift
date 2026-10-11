import AppKit
import ExplorerCore

/// One Explorer window. Owns the navigation history and loads the current location.
///
/// Phase 0: shows the split-view skeleton and wires Core loading/watching into the
/// status bar. Real views arrive in Phase 1.
@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "ExplorerWindow"

    private(set) var history: NavigationHistory
    var onClose: (() -> Void)?

    private let rootViewController = ExplorerRootViewController()
    private let loader = DirectoryLoader()
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?

    init(location: ExplorerLocation) {
        history = NavigationHistory(start: location)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 520, height: 320)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        super.init(window: window)

        // Assigning the content view controller resizes the window to the view's fitting
        // size (the minimum), so set the default size afterwards, then restore any saved frame.
        window.contentViewController = rootViewController
        window.setContentSize(NSSize(width: 1100, height: 680))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.delegate = self
        show(location)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func navigate(to location: ExplorerLocation) {
        history.navigate(to: location)
        show(location)
    }

    private func show(_ location: ExplorerLocation) {
        window?.title = location.displayName
        rootViewController.content.location = location
        reload()
        watch(location)
    }

    private func reload() {
        loadTask?.cancel()
        guard let url = history.current.fileURL else {
            rootViewController.statusBar.text = ""
            return
        }
        loadTask = Task { [weak self, loader] in
            do {
                let items = try await loader.contents(of: url)
                guard !Task.isCancelled else { return }
                self?.rootViewController.statusBar.text = items.count == 1 ? "1 item" : "\(items.count) items"
            } catch is CancellationError {
                // Superseded by a newer load.
            } catch {
                self?.rootViewController.statusBar.text = error.localizedDescription
            }
        }
    }

    private func watch(_ location: ExplorerLocation) {
        watchTask?.cancel()
        watcher?.stop()
        guard let url = location.fileURL else {
            watcher = nil
            return
        }
        let watcher = DirectoryWatcher(directory: url)
        self.watcher = watcher
        let changes = watcher.start()
        watchTask = Task { [weak self] in
            for await _ in changes {
                self?.reload()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        watchTask?.cancel()
        watcher?.stop()
        onClose?()
    }
}
