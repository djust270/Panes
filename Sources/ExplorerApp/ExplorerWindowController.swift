import AppKit
import ExplorerCore

/// One Explorer window. Owns the navigation history, loads and watches the current
/// location, and coordinates the sidebar, toolbar, content view and status bar.
@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "ExplorerWindow"

    private(set) var history: NavigationHistory
    var onClose: (() -> Void)?

    private let rootViewController = ExplorerRootViewController()
    private let toolbarController = ExplorerToolbarController()
    private var loader = DirectoryLoader()
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
        window.toolbar = toolbarController.toolbar

        rootViewController.content.onNavigate = { [weak self] location in
            self?.navigate(to: location)
        }
        rootViewController.content.onSelectionChange = { [weak self] in
            self?.updateStatusBar()
        }
        rootViewController.navigationPane.onSelect = { [weak self] location in
            self?.navigate(to: location)
        }
        toolbarController.onNavigate = { [weak self] location in
            self?.navigate(to: location)
        }
        toolbarController.onGoBack = { [weak self] steps in
            guard let self, let destination = history.goBack(steps: steps) else { return }
            show(destination)
        }
        toolbarController.onGoForward = { [weak self] steps in
            guard let self, let destination = history.goForward(steps: steps) else { return }
            show(destination)
        }
        toolbarController.onUp = { [weak self] in self?.navigateUp() }
        toolbarController.onRefresh = { [weak self] in self?.refresh() }
        toolbarController.backList = { [weak self] in self?.history.backList ?? [] }
        toolbarController.forwardList = { [weak self] in self?.history.forwardList ?? [] }

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

    func navigateUp() {
        guard let parent = history.current.parent else { return }
        navigate(to: parent)
    }

    func refresh() {
        reload()
    }

    var showsHiddenFiles: Bool { loader.options.includeHidden }

    func setShowsHiddenFiles(_ value: Bool) {
        guard value != loader.options.includeHidden else { return }
        loader.options.includeHidden = value
        reload()
    }

    private func show(_ location: ExplorerLocation) {
        window?.title = location.displayName
        rootViewController.navigationPane.select(location)
        toolbarController.update(location: location, history: history)
        reload()
        watch(location)
    }

    private func reload() {
        loadTask?.cancel()

        if history.current == .thisPC {
            let items = VolumeLister.mountedVolumes().map { volume in
                FileItem(url: volume.url.standardizedFileURL, name: volume.name, kind: .directory)
            }
            rootViewController.content.setItems(items)
            updateStatusBar()
            return
        }

        guard let url = history.current.fileURL else {
            rootViewController.content.showUnavailable("\(history.current.displayName) isn't available yet.")
            rootViewController.statusBar.text = ""
            return
        }
        loadTask = Task { [weak self, loader] in
            do {
                let items = try await loader.contents(of: url)
                guard !Task.isCancelled else { return }
                self?.rootViewController.content.setItems(items)
                self?.updateStatusBar()
            } catch is CancellationError {
                // Superseded by a newer load.
            } catch {
                self?.rootViewController.statusBar.text = error.localizedDescription
            }
        }
    }

    private func updateStatusBar() {
        let content = rootViewController.content
        let selected = content.selectedItems
        let selectedSize: Int64? = selected.allSatisfy(\.isFolder)
            ? nil
            : selected.reduce(0) { $0 + ($1.size ?? 0) }
        rootViewController.statusBar.text = StatusBarText.make(
            totalCount: content.sortedItems.count,
            selectedCount: selected.count,
            selectedSizeBytes: selectedSize
        )
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
