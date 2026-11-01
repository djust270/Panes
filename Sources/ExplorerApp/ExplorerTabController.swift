import AppKit
import ExplorerCore

/// What a tab asks of the window holding it.
@MainActor
protocol TabHosting: AnyObject {
    /// The tab's title or icon changed.
    func tabDidChangeTitle(_ tab: ExplorerTabController)
    /// Opens `location` in a new tab next to `tab`.
    func openTab(at location: ExplorerLocation, besides tab: ExplorerTabController, select: Bool)
    /// In dual-pane mode, the pane beside `tab`.
    func otherPane(of tab: ExplorerTabController) -> ExplorerTabController?
}

/// One Explorer tab. Owns the navigation history, loads and watches the current location,
/// and coordinates the navigation pane, address and command bars, content view and status
/// bar. Sits in the responder chain while its tab is showing, so menu commands reach it.
/// File commands live in `ExplorerTabController+FileActions.swift`, view commands in
/// `ExplorerTabController+View.swift`, Home and search in `ExplorerTabController+Search.swift`.
@MainActor
final class ExplorerTabController: NSViewController {
    private(set) var history: NavigationHistory
    weak var host: TabHosting?

    let rootViewController = ExplorerRootViewController()
    private(set) var loader = DirectoryLoader()
    var loadTask: Task<Void, Never>?
    private var watchTasks: [Task<Void, Never>] = []
    private var watchers: [DirectoryWatcher] = []
    private var observers: [NSObjectProtocol] = []
    /// Waits out typing in the search box before searching.
    var searchDelay: Task<Void, Never>?
    /// The search hasn't finished its first pass.
    var isSearchRunning = false
    /// The search found more than `FileSearch.resultLimit` items.
    var isSearchTruncated = false
    /// Whether the folder shown is synced: a cloud folder, or Desktop and Documents in iCloud.
    private(set) var showsCloudFolder = false
    /// Items "Download now" is downloading, shown as syncing until it's done.
    var cloudDownloads: Set<URL> = []

    var content: ContentViewController { rootViewController.content }
    var addressBar: AddressBarView { rootViewController.addressBar }
    var commandBar: CommandBarView { rootViewController.commandBar }

    /// The tab strip's icon for the current location.
    private(set) var icon = NSImage()

    init(location: ExplorerLocation) {
        history = NavigationHistory(start: location)
        super.init(nibName: nil, bundle: nil)
        loader.options.includeHidden = AppSettings.showsHiddenFiles
        title = location.displayName
        icon = Self.icon(for: location)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        addChild(rootViewController)
        let container = NSView()
        let root = rootViewController.view
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        connectCallbacks()
        show(history.current)
    }

    private func connectCallbacks() {
        content.onNavigate = { [weak self] location in
            self?.navigate(to: location)
        }
        content.onConnect = { [weak self] server in
            guard let path = NetworkPath(server.absoluteString) else { return }
            self?.connect(to: path)
        }
        content.onOpenInNewTab = { [weak self] location in
            guard let self else { return }
            host?.openTab(at: location, besides: self, select: false)
        }
        content.onSelectionChange = { [weak self] in
            self?.updateStatusBar()
            self?.updateSidePane()
        }
        connectViewCallbacks()
        content.onRename = { [weak self] item, name in
            self?.rename(item, to: name)
        }
        content.dropHandler = self
        content.cutURLs = FileClipboard.shared.cutURLs
        rootViewController.navigationPane.onSelect = { [weak self] location in
            self?.navigate(to: location)
        }
        rootViewController.navigationPane.onOpenInNewTab = { [weak self] location in
            guard let self else { return }
            host?.openTab(at: location, besides: self, select: false)
        }
        rootViewController.navigationPane.dropHandler = self
        commandBar.target = self
        connectAddressBar()

        observers.append(NotificationCenter.default.addObserver(
            forName: FileClipboard.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.content.cutURLs = FileClipboard.shared.cutURLs
                self?.commandBar.validate()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        })
        observeLocations()
    }

    /// Reloads Home, This PC and Network when what they show changes; leaves an ejected drive.
    private func observeLocations() {
        observers.append(QuickAccess.observe { [weak self] in
            guard let self, history.current == .home else { return }
            reload()
        })
        observers.append(DriveCenter.observe { [weak self] in
            guard let self, history.current == .thisPC || history.current == .network else { return }
            reload()
        })
        observers.append(NetworkBrowser.observe { [weak self] in
            guard let self, history.current == .network else { return }
            reload()
        })
        observers.append(RemoteCenter.observe { [weak self] in
            guard let self, history.current == .network else { return }
            reload()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: DriveCenter.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let volume = notification.object as? URL else { return }
            MainActor.assumeIsolated { self?.volumeDidUnmount(volume) }
        })
    }

    /// A folder on an ejected drive goes to This PC, as on Windows.
    private func volumeDidUnmount(_ volume: URL) {
        guard history.current.fileURL != nil || inSearchResults, let folder = searchScope else { return }
        let root = volume.standardizedFileURL.pathComponents
        guard folder.standardizedFileURL.pathComponents.starts(with: root) else { return }
        navigate(to: .thisPC)
    }

    private func connectAddressBar() {
        addressBar.onNavigate = { [weak self] location in
            self?.navigate(to: location)
        }
        addressBar.onNetworkPath = { [weak self] path in
            self?.connect(to: path)
        }
        addressBar.onRemotePath = { [weak self] path in
            self?.navigate(to: .remote(path))
        }
        addressBar.onGoBack = { [weak self] steps in
            self?.goBack(steps: steps)
        }
        addressBar.onGoForward = { [weak self] steps in
            self?.goForward(steps: steps)
        }
        addressBar.onUp = { [weak self] in self?.navigateUp() }
        addressBar.onEndEditing = { [weak self] in self?.focusContent() }
        addressBar.onRefresh = { [weak self] in self?.reload() }
        addressBar.backList = { [weak self] in self?.history.backList ?? [] }
        addressBar.forwardList = { [weak self] in self?.history.forwardList ?? [] }
        addressBar.onSearchChange = { [weak self] text in self?.searchTextDidChange(text) }
        addressBar.onSearchSubmit = { [weak self] text in self?.search(for: text) }
        addressBar.onSearchCancel = { [weak self] in self?.cancelSearch() }
        addressBar.onSearchMoveDown = { [weak self] in self?.focusContent() }
    }

    private func connectViewCallbacks() {
        content.onSettingsChange = { [weak self] settings in
            guard let self else { return }
            FolderViewMemory.store.save(settings, for: history.current)
            rootViewController.statusBar.setViewMode(settings.viewMode)
            commandBar.validate()
        }
        rootViewController.statusBar.onViewMode = { [weak self] mode in
            self?.setViewMode(mode)
        }
    }

    private func settingsDidChange() {
        if loader.options.includeHidden != AppSettings.showsHiddenFiles {
            loader.options.includeHidden = AppSettings.showsHiddenFiles
            reload()
        }
        content.applyTheme()
        rootViewController.navigationPane.applyTheme()
        commandBar.validate()
    }

    // MARK: Navigation

    func navigate(to location: ExplorerLocation) {
        history.navigate(to: location)
        show(location)
    }

    /// Shows `location` in place of the current one, without adding to the history.
    func replace(with location: ExplorerLocation) {
        history.replaceCurrent(with: location)
        show(location)
    }

    func goBack(steps: Int) {
        guard let destination = history.goBack(steps: steps) else { return }
        show(destination)
    }

    func goForward(steps: Int) {
        guard let destination = history.goForward(steps: steps) else { return }
        show(destination)
    }

    /// Mounts a network share typed into the address bar (or a computer under Network, or a
    /// drive being mapped), then opens it.
    func connect(
        to path: NetworkPath,
        signIn: NetworkShareMounter.SignIn = .automatic,
        onMounted: ((URL) -> Void)? = nil
    ) {
        rootViewController.statusBar.text = "Connecting to \(path.shareURL.absoluteString)…"
        Task {
            switch await NetworkShareMounter.mount(path, signIn: signIn) {
            case .mounted(let folder):
                onMounted?(folder)
                navigate(to: .folder(folder))
            case .cancelled:
                updateStatusBar()
            case .failed(let message):
                updateStatusBar()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t connect to “\(path.shareURL.absoluteString)”"
                alert.informativeText = message
                await present(alert)
            }
        }
    }

    func navigateUp() {
        guard let parent = history.current.parent else { return }
        navigate(to: parent)
    }

    /// The real folder being shown, if any (not This PC, Home, Recycle Bin…).
    var currentFolder: URL? { history.current.fileURL }

    var inSearchResults: Bool {
        if case .search = history.current { return true }
        return false
    }

    private func show(_ location: ExplorerLocation) {
        showsCloudFolder = location.fileURL.map(CloudStatusReader.isCloudFolder) ?? false
        title = location.displayName
        icon = Self.icon(for: location)
        host?.tabDidChangeTitle(self)
        let mode: ContentViewController.Mode
        var settings = FolderViewMemory.store.settings(for: location)
        switch location {
        case .recycleBin: mode = .recycleBin
        case .thisPC: mode = .volumes
        case .home:
            mode = .home
            settings = FolderViewSettings(viewMode: .tiles)
        case .search: mode = .search
        case .folder(let url):
            mode = .folder
            QuickAccess.recordVisit(to: url)
        case .network:
            mode = .network
            NetworkBrowser.shared.start()
        case .remote:
            mode = .remote
        }
        content.show(mode: mode, settings: settings)
        rootViewController.statusBar.setViewMode(content.settings.viewMode)
        rootViewController.navigationPane.select(location)
        addressBar.update(location: location, history: history)
        updateSearchField()
        reload()
        watch(location)
    }

    static func icon(for location: ExplorerLocation) -> NSImage {
        let image: NSImage?
        switch location {
        case .folder(let url): image = NSWorkspace.shared.icon(forFile: url.path)
        case .home: image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
        case .thisPC: image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        case .network: image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        case .recycleBin: image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        case .search: image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        case .remote(let remote):
            let symbol = remote.parent == nil ? "server.rack" : "folder"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return image ?? NSImage()
    }

    func reload() {
        loadTask?.cancel()
        isSearchRunning = false

        switch history.current {
        case .thisPC:
            content.setItems(DriveCenter.items())
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
                    try await self?.refineCloudStatus(of: items)
                } catch is CancellationError {
                    // Superseded by a newer load.
                } catch {
                    self?.showLoadError(error)
                }
            }
        case .home:
            loadHome()
        case .search(let text, let scope):
            runSearch(text, in: scope)
        case .network:
            content.setItems(networkItems())
            updateStatusBar()
        case .remote(let remote):
            loadRemote(remote)
        }
    }

    private static let fullDiskAccessAction = (
        title: "Set Up Full Disk Access…",
        run: { FullDiskAccessWindowController.shared.show() }
    )

    /// Windows' "You don't currently have permission to access this folder", offering Full
    /// Disk Access when that's what's missing. Other errors go to the status bar.
    private func showLoadError(_ error: Error) {
        guard FullDiskAccess.isPermissionDenial(error) else {
            rootViewController.statusBar.text = error.localizedDescription
            return
        }
        if FullDiskAccess.isPrivacyDenial(error), FullDiskAccess.status() != .granted {
            content.showUnavailable(
                "macOS protects this folder. Give \(AppInfo.name) Full Disk Access to open it.",
                action: Self.fullDiskAccessAction
            )
        } else {
            content.showUnavailable("You don’t currently have permission to access this folder.")
        }
        rootViewController.statusBar.text = ""
    }

    func updateStatusBar() {
        let selected = content.selectedItems
        let selectedSize: Int64? = selected.allSatisfy(\.isFolder)
            ? nil
            : selected.reduce(0) { $0 + ($1.size ?? 0) }
        var text = StatusBarText.make(
            totalCount: content.allItems.count,
            selectedCount: selected.count,
            selectedSizeBytes: selectedSize
        )
        if !content.kindFilter.isEmpty {
            text += "  |  Filtered"
        }
        if isSearchRunning {
            text += "  |  Searching…"
        } else if isSearchTruncated, inSearchResults {
            text += "  |  Showing the first \(FileSearch.resultLimit.formatted()) results"
        }
        rootViewController.statusBar.text = text
        commandBar.validate()
    }

    private func watch(_ location: ExplorerLocation) {
        stopWatching()

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

    private func stopWatching() {
        watchTasks.forEach { $0.cancel() }
        watchers.forEach { $0.stop() }
        watchTasks = []
        watchers = []
    }

    /// Stops loading and watching, for good. Called when the tab closes.
    func close() {
        content.finishRenaming(commit: true)
        loadTask?.cancel()
        searchDelay?.cancel()
        stopWatching()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        rootViewController.navigationPane.close()
    }

    // MARK: Alerts

    func confirm(_ message: String, detail: String, button: String, cancel: String = "Cancel") async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: cancel)
        return await present(alert) == .alertFirstButtonReturn
    }

    func inform(_ message: String) async {
        let alert = NSAlert()
        alert.messageText = message
        await present(alert)
    }

    /// Shows `alert` as a sheet on the tab's window, or as a panel if the tab isn't showing.
    @discardableResult
    func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - Renamed locations

extension ExplorerTabController {
    /// Swaps the current location for the same place under another name (a remote home
    /// folder, once resolved) without loading it again.
    func adopt(_ location: ExplorerLocation) {
        history.replaceCurrent(with: location)
        title = location.displayName
        icon = Self.icon(for: location)
        host?.tabDidChangeTitle(self)
        rootViewController.navigationPane.select(location)
        addressBar.update(location: location, history: history)
        updateSearchField()
    }
}

// MARK: - Recycle Bin

extension ExplorerTabController {
    fileprivate func loadRecycleBin() {
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
                    "\(AppInfo.name) needs Full Disk Access to show the Recycle Bin.",
                    action: Self.fullDiskAccessAction
                )
                rootViewController.statusBar.text = ""
            case .failure(let error):
                rootViewController.statusBar.text = error.localizedDescription
            }
        }
    }
}
