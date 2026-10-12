import AppKit
import ExplorerCore

/// One Explorer window. Owns the navigation history, loads and watches the current
/// location, and coordinates the sidebar, toolbar, content view and status bar.
/// File commands live in `ExplorerWindowController+FileActions.swift`.
@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "ExplorerWindow"

    private(set) var history: NavigationHistory
    var onClose: (() -> Void)?

    let rootViewController = ExplorerRootViewController()
    private let toolbarController = ExplorerToolbarController()
    private var loader = DirectoryLoader()
    private var loadTask: Task<Void, Never>?
    private var watchTasks: [Task<Void, Never>] = []
    private var watchers: [DirectoryWatcher] = []
    private var clipboardObserver: NSObjectProtocol?
    /// Undo for text being edited (rename, address bar), kept apart from file operations.
    private let textUndoManager = UndoManager()

    var content: ContentViewController { rootViewController.content }

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

        connectCallbacks()
        show(location)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func connectCallbacks() {
        content.onNavigate = { [weak self] location in
            self?.navigate(to: location)
        }
        content.onSelectionChange = { [weak self] in
            self?.updateStatusBar()
        }
        content.onRename = { [weak self] item, name in
            self?.rename(item, to: name)
        }
        content.dropHandler = self
        content.cutURLs = FileClipboard.shared.cutURLs
        rootViewController.navigationPane.onSelect = { [weak self] location in
            self?.navigate(to: location)
        }
        rootViewController.navigationPane.dropHandler = self
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

        clipboardObserver = NotificationCenter.default.addObserver(
            forName: FileClipboard.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.content.cutURLs = FileClipboard.shared.cutURLs
            }
        }
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

    /// The real folder being shown, if any (not This PC, Home, Recycle Bin…).
    var currentFolder: URL? { history.current.fileURL }

    private func show(_ location: ExplorerLocation) {
        window?.title = location.displayName
        content.finishRenaming(commit: true)
        switch location {
        case .recycleBin: content.mode = .recycleBin
        case .thisPC: content.mode = .volumes
        default: content.mode = .folder
        }
        rootViewController.navigationPane.select(location)
        toolbarController.update(location: location, history: history)
        reload()
        watch(location)
    }

    func reload() {
        loadTask?.cancel()

        switch history.current {
        case .thisPC:
            let items = VolumeLister.mountedVolumes().map { volume in
                FileItem(url: volume.url.standardizedFileURL, name: volume.name, kind: .directory)
            }
            content.setItems(items)
            updateStatusBar()
        case .recycleBin:
            loadRecycleBin()
        case .folder(let url):
            loadTask = Task { [weak self, loader] in
                do {
                    let items = try await loader.contents(of: url)
                    guard !Task.isCancelled else { return }
                    self?.content.setItems(items)
                    self?.updateStatusBar()
                } catch is CancellationError {
                    // Superseded by a newer load.
                } catch {
                    self?.rootViewController.statusBar.text = error.localizedDescription
                }
            }
        case .home, .network, .search:
            content.showUnavailable("\(history.current.displayName) isn't available yet.")
            rootViewController.statusBar.text = ""
        }
    }

    private func loadRecycleBin() {
        let includeHidden = loader.options.includeHidden
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try RecycleBin.contents(includeHidden: includeHidden) }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let items):
                content.setItems(items)
                updateStatusBar()
            case .failure(is RecycleBin.AccessDenied):
                content.showUnavailable(
                    "Explorer needs Full Disk Access to show the Recycle Bin.\n"
                        + "Turn it on in System Settings › Privacy & Security › Full Disk Access."
                )
                rootViewController.statusBar.text = ""
            case .failure(let error):
                rootViewController.statusBar.text = error.localizedDescription
            }
        }
    }

    func updateStatusBar() {
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
        watchTasks.forEach { $0.cancel() }
        watchers.forEach { $0.stop() }

        let directories: [URL]
        switch location {
        case .folder(let url): directories = [url]
        case .recycleBin: directories = RecycleBin.trashDirectories()
        default: directories = []
        }
        watchers = directories.map { DirectoryWatcher(directory: $0) }
        watchTasks = watchers.map { watcher in
            let changes = watcher.start()
            return Task { [weak self] in
                for await _ in changes {
                    self?.reload()
                }
            }
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndoManager : FileOperationCenter.shared.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        content.finishRenaming(commit: true)
        loadTask?.cancel()
        watchTasks.forEach { $0.cancel() }
        watchers.forEach { $0.stop() }
        if let clipboardObserver {
            NotificationCenter.default.removeObserver(clipboardObserver)
        }
        onClose?()
    }
}
