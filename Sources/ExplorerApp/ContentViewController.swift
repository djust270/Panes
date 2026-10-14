import AppKit
import ExplorerCore

/// Receives drops on the content view and the navigation pane. `nil` locations mean "the
/// location the window is showing".
@MainActor
protocol FileDropHandling: AnyObject {
    func dropOperation(
        for urls: [URL],
        into location: ExplorerLocation?,
        sourceMask: NSDragOperation
    ) -> NSDragOperation
    func performDrop(of urls: [URL], into location: ExplorerLocation?, operation: NSDragOperation)
    func canReceivePromises(into location: ExplorerLocation?) -> Bool
    func receivePromises(_ receivers: [NSFilePromiseReceiver], into location: ExplorerLocation?)
    /// Items dragged out to the Dock's Trash.
    func trashDraggedItems(_ urls: [URL])
}

/// The folder's contents in one of eight layouts: Details is an `NSTableView`; the icon views,
/// List, Tiles and Content share an `NSCollectionView`. Both show the same `FileListContent`
/// (sorted, optionally grouped), and selection is tracked by URL so it survives reloads and
/// layout changes. Table, collection, rename, menu and drag-and-drop code live in extensions.
@MainActor
final class ContentViewController: NSViewController {
    enum Mode {
        /// A real folder.
        case folder
        /// The Recycle Bin: adds Original Location and Date Deleted columns.
        case recycleBin
        /// This PC's volume list: no file operations.
        case volumes
        /// Home: Quick access tiles, then Favorites and Recent as rows. A fixed layout.
        case home
        /// Search results: adds the Folder column.
        case search
        /// Network: computers, opened by connecting to them. No file operations.
        case network
    }

    /// Network's computers aren't files: no drags, drops or thumbnails.
    var listsFiles: Bool { mode != .volumes && mode != .network }

    private static let checkboxesKey = "ShowItemCheckboxes"

    var onNavigate: ((ExplorerLocation) -> Void)?
    /// Opening a computer under Network.
    var onConnect: ((URL) -> Void)?
    /// Middle-click or "Open in new tab" on a folder.
    var onOpenInNewTab: ((ExplorerLocation) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// The user finished renaming `item` to the given name.
    var onRename: ((FileItem, String) -> Void)?
    /// The user changed the layout, sort, grouping or columns.
    var onSettingsChange: ((FolderViewSettings) -> Void)?
    weak var dropHandler: FileDropHandling?

    private(set) var mode: Mode = .folder
    private(set) var settings = FolderViewSettings()

    /// Home's groups, as last supplied by `setHomeGroups`.
    var homeGroups: [FileGroup] = []
    /// When Home's Favorites and Recent files were last used, by path.
    var homeDates: [String: Date] = [:]

    /// Items waiting in the clipboard after Cut, drawn dimmed.
    var cutURLs: Set<URL> = [] {
        didSet {
            guard cutURLs != oldValue, renaming == nil else { return }
            reconfigureVisibleItems()
        }
    }

    /// Windows' "Item check boxes" option; app-wide.
    var showsCheckboxes = UserDefaults.standard.bool(forKey: ContentViewController.checkboxesKey) {
        didSet {
            guard showsCheckboxes != oldValue else { return }
            UserDefaults.standard.set(showsCheckboxes, forKey: Self.checkboxesKey)
            finishRenaming(commit: true)
            reconfigureVisibleItems()
        }
    }

    /// The current folder's contents, unsorted, as last supplied by `setItems`.
    private(set) var items: [FileItem] = []
    /// What the views show.
    private(set) var listContent = FileListContent() {
        didSet { listGeneration &+= 1 }
    }
    /// Changes with `listContent`, so cached lookups know they're stale.
    private var listGeneration = 0
    /// `selectedItems` for a selection snapshot: menu and command-bar validation asks for it
    /// many times per change, and building it for 100,000 selected items takes a while.
    private var selectionCache: SelectionSnapshot?

    private struct SelectionSnapshot {
        let generation: Int
        let rows: IndexSet
        let paths: Set<IndexPath>
        let items: [FileItem]
    }
    /// Every item in display order, including those in collapsed groups.
    var allItems: [FileItem] { listContent.allItems }
    /// Group IDs the user collapsed; forgotten on navigation.
    var collapsedGroups: Set<String> = []
    /// The command bar's Filter: kinds of items to show (all if empty); forgotten on navigation.
    var kindFilter: Set<FileKind> = [] {
        didSet {
            guard kindFilter != oldValue else { return }
            refreshContent()
        }
    }
    var typeAhead = TypeAheadSelector()

    var isDetailsMode: Bool { settings.viewMode == .details }

    /// Items currently selected, in display order.
    var selectedItems: [FileItem] {
        let rows = isDetailsMode ? tableView.selectedRowIndexes : IndexSet()
        let paths = isDetailsMode ? [] : collectionView.selectionIndexPaths
        if let cache = selectionCache, cache.generation == listGeneration, cache.rows == rows, cache.paths == paths {
            return cache.items
        }
        let items = isDetailsMode
            ? rows.compactMap { listContent.item(atRow: $0) }
            : paths.sorted().compactMap { listContent.item(section: $0.section, index: $0.item) }
        selectionCache = SelectionSnapshot(generation: listGeneration, rows: rows, paths: paths, items: items)
        return items
    }

    var selectedURLs: Set<URL> { Set(selectedItems.map(\.url)) }

    let tableView = FileTableView()
    let collectionView = FileCollectionView()
    private let tableScrollView = NSScrollView()
    private let collectionScrollView = NSScrollView()
    /// Shown in place of the list when a location can't be listed: a message and an optional button.
    private let unavailableView = NSStackView()
    private let unavailableLabel = NSTextField(wrappingLabelWithString: "")
    private let unavailableButton = NSButton(title: "", target: nil, action: nil)
    private var unavailableAction: (() -> Void)?
    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Selection (and optionally an item to rename) to apply once those items are loaded.
    private var pendingSelection: [URL]?
    private var pendingRename: URL?
    /// The in-place rename in progress, if any.
    var renaming: RenameSession?
    /// Items that arrived while renaming; applied when the rename ends.
    var deferredItems: [FileItem]?
    /// Set while settings are pushed into the views, so view callbacks don't echo them back.
    var isApplyingSettings = false
    /// `listContent` changed while the collection view was hidden (only the showing view is
    /// reloaded). It must be reloaded before its layout changes, or AppKit asks the new layout
    /// about index paths that no longer exist and throws.
    private var collectionNeedsReload = false

    /// Listings at least this long are sorted and grouped off the main thread when they
    /// arrive, so opening (or live-refreshing) a huge folder doesn't freeze the window.
    private static let backgroundBuildThreshold = 5_000
    /// Builds `listContent` for the latest `setItems`; any synchronous rebuild cancels it.
    private var buildTask: Task<Void, Never>?

    private var propertiesCache: [URL: (modified: Date?, properties: FileProperties)] = [:]
    private var propertiesTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView()

        configureTableView()
        tableScrollView.documentView = tableView
        configureCollectionView()
        collectionScrollView.documentView = collectionView

        // Both lists share one frame (Windows 98's sunken one).
        let lists = NSView()
        for scrollView in [tableScrollView, collectionScrollView] {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            lists.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: lists.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: lists.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: lists.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: lists.bottomAnchor),
            ])
        }
        BevelView.embed(lists, in: container)

        unavailableLabel.textColor = .secondaryLabelColor
        unavailableLabel.alignment = .center
        unavailableLabel.preferredMaxLayoutWidth = 420
        unavailableButton.bezelStyle = .rounded
        unavailableButton.target = self
        unavailableButton.action = #selector(unavailableButtonClicked)
        unavailableView.orientation = .vertical
        unavailableView.spacing = 12
        unavailableView.addArrangedSubview(unavailableLabel)
        unavailableView.addArrangedSubview(unavailableButton)
        unavailableView.isHidden = true
        unavailableView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(unavailableView)
        NSLayoutConstraint.activate([
            unavailableView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            unavailableView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            unavailableView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
        ])

        view = container
        applySettings(settings, notify: false)
    }

    // MARK: Settings

    /// Prepares for a new location: its kind and remembered view. Items follow via `setItems`.
    func show(mode: Mode, settings: FolderViewSettings) {
        finishRenaming(commit: true)
        buildTask?.cancel()
        self.mode = mode
        collapsedGroups = []
        kindFilter = []
        typeAhead.reset()
        items = []
        listContent = FileListContent()
        collectionNeedsReload = true
        homeGroups = []
        homeDates = [:]
        propertiesTask?.cancel()
        propertiesCache = [:]
        applySettings(settings, notify: false)
    }

    /// Changes the view in response to the user, and reports it through `onSettingsChange`.
    func updateSettings(_ change: (inout FolderViewSettings) -> Void) {
        guard mode != .home else { return }
        finishRenaming(commit: true)
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        applySettings(updated, notify: true)
    }

    private func applySettings(_ newSettings: FolderViewSettings, notify: Bool) {
        let selection = selectedURLs
        let hadFocus = view.window?.firstResponder === activeView
        let previous = settings
        settings = newSettings.sanitized(for: listKind)

        isApplyingSettings = true
        applyTableSettings()
        let isGrouped = settings.grouping != nil || mode == .home || mode == .volumes
        let layout = collectionView.collectionViewLayout as? FileCollectionLayout
        let isHome = mode == .home
        if layout?.viewMode != settings.viewMode || layout?.isGrouped != isGrouped || layout?.isHome != isHome {
            if collectionNeedsReload {
                collectionView.reloadData()
                collectionNeedsReload = false
            }
            collectionView.collectionViewLayout = FileCollectionLayout(
                viewMode: settings.viewMode,
                isGrouped: isGrouped,
                isHome: isHome
            )
        }
        isApplyingSettings = false

        if unavailableView.isHidden {
            tableScrollView.isHidden = !isDetailsMode
            collectionScrollView.isHidden = isDetailsMode
        }
        // Re-sorting a huge folder happens in the background, the old order showing meanwhile.
        // Other changes rebuild at once: the collection view's layout must match its data.
        var sortOnly = previous
        sortOnly.sort = settings.sort
        if sortOnly == settings, previous.sort != settings.sort, canBuildInBackground {
            buildInBackground { [weak self] content in
                guard let self else { return }
                show(content, selecting: selectedURLs, scroll: true)
            }
        } else {
            rebuild(selecting: selection, scroll: true)
        }
        if hadFocus { view.window?.makeFirstResponder(activeView) }
        if notify { onSettingsChange?(settings) }
    }

    /// The view that shows items in the current mode.
    var activeView: NSView { isDetailsMode ? tableView : collectionView }

    // MARK: Items

    /// Replaces the folder's contents, preserving the selection by URL where possible.
    func setItems(_ newItems: [FileItem]) {
        if renaming != nil {
            deferredItems = newItems
            return
        }
        unavailableView.isHidden = true
        tableScrollView.isHidden = !isDetailsMode
        collectionScrollView.isHidden = isDetailsMode

        items = newItems
        guard canBuildInBackground else {
            buildTask?.cancel()
            itemsDidArrive(prepared: nil)
            return
        }
        buildInBackground { [weak self] content in
            self?.itemsDidArrive(prepared: content)
            // The tab updated its status bar for the old list when the items arrived.
            self?.onSelectionChange?()
        }
    }

    private var canBuildInBackground: Bool {
        items.count >= Self.backgroundBuildThreshold && (mode == .folder || mode == .recycleBin)
            && !settings.needsProperties
    }

    /// Sorts and groups `items` off the main thread, then hands the result to `finish`,
    /// unless something rebuilt the list in the meantime.
    private func buildInBackground(then finish: @escaping (FileListContent) -> Void) {
        buildTask?.cancel()
        let (shown, sort, grouping, collapsed) = (kindFilter.filter(items), settings.sort, settings.grouping,
                                                  collapsedGroups)
        buildTask = Task {
            let content = await Task.detached(priority: .userInitiated) {
                FileListContent(items: shown, sort: sort, grouping: grouping, collapsedGroups: collapsed)
            }.value
            guard !Task.isCancelled else { return }
            finish(content)
        }
    }

    /// Shows the new `items`, keeping the selection by URL (or selecting what was asked for),
    /// from `prepared` content when it was built in the background.
    private func itemsDidArrive(prepared: FileListContent?) {
        var prepared = prepared
        var selection = selectedURLs
        var scroll = false
        if let pending = pendingSelection {
            let present = Set(pending).intersection(items.map(\.url))
            if !present.isEmpty {
                // Expanding a group means building again.
                if revealGroups(containing: present, in: prepared ?? listContent) { prepared = nil }
                selection = present
                scroll = true
                pendingSelection = nil
            }
        }
        if let prepared {
            show(prepared, selecting: selection, scroll: scroll)
        } else {
            rebuild(selecting: selection, scroll: scroll)
        }

        if let rename = pendingRename, listContent.row(of: rename) != nil {
            pendingRename = nil
            beginRenaming(rename)
        }
    }

    /// Selects `urls` (now, or once they appear after a reload) and optionally starts renaming one.
    func select(_ urls: [URL], renaming renameURL: URL? = nil) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let loaded = Set(items.map(\.url))
        if !wanted.isEmpty, wanted.isSubset(of: loaded) {
            if revealGroups(containing: wanted) { rebuild(selecting: wanted, scroll: true) }
            setSelection(wanted, scroll: true)
            if let renameURL { beginRenaming(renameURL) }
        } else {
            pendingSelection = Array(wanted)
            pendingRename = renameURL?.standardizedFileURL
        }
    }

    /// Shows a centered message instead of the items, for locations with nothing to list.
    /// Replaces the list with `message`, and a button running `action` if given.
    func showUnavailable(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        finishRenaming(commit: false)
        items = []
        rebuild(selecting: [], scroll: false)
        unavailableLabel.stringValue = message
        unavailableButton.title = action?.title ?? ""
        unavailableButton.isHidden = action == nil
        unavailableAction = action?.run
        unavailableView.isHidden = false
        tableScrollView.isHidden = true
        collectionScrollView.isHidden = true
    }

    @objc private func unavailableButtonClicked() {
        unavailableAction?()
    }

    /// Rebuilds `listContent` from `items` and reloads the active view.
    func rebuild(selecting selection: Set<URL>, scroll: Bool) {
        buildTask?.cancel()
        let content: FileListContent
        if mode == .home {
            content = FileListContent(groups: homeGroups, collapsedGroups: collapsedGroups)
        } else if mode == .volumes {
            content = FileListContent(groups: driveGroups(), collapsedGroups: collapsedGroups)
        } else {
            let shown = kindFilter.filter(settings.needsProperties ? itemsWithProperties() : items)
            content = FileListContent(
                items: shown,
                sort: settings.sort,
                grouping: settings.grouping,
                collapsedGroups: collapsedGroups
            )
        }
        show(content, selecting: selection, scroll: scroll)
    }

    /// Makes `content` the list and reloads the active view.
    private func show(_ content: FileListContent, selecting selection: Set<URL>, scroll: Bool) {
        listContent = content
        if isDetailsMode {
            tableView.reloadData()
            collectionNeedsReload = true
        } else {
            collectionView.reloadData()
            collectionNeedsReload = false
        }
        setSelection(selection, scroll: scroll)
    }

    /// Rebuilds keeping the current selection, unless a rename is in progress.
    func refreshContent() {
        if renaming != nil {
            deferredItems = items
        } else {
            rebuild(selecting: selectedURLs, scroll: false)
        }
    }

    /// Expands collapsed groups holding any of `urls`. Returns whether any were expanded.
    @discardableResult
    private func revealGroups(containing urls: Set<URL>, in content: FileListContent? = nil) -> Bool {
        let hidden = (content ?? listContent).sections.filter { section in
            section.isCollapsed && section.group?.items.contains { urls.contains($0.url) } == true
        }
        let ids = hidden.compactMap(\.group?.id)
        collapsedGroups.subtract(ids)
        return !ids.isEmpty
    }

    // MARK: Selection

    /// Selects exactly `urls` (those that are visible) in the active view.
    func setSelection(_ urls: Set<URL>, scroll: Bool) {
        if isDetailsMode {
            let rows = IndexSet(urls.compactMap { listContent.row(of: $0) })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            if scroll, let first = rows.first { tableView.scrollRowToVisible(first) }
        } else {
            let paths = Set(urls.compactMap { url in
                listContent.position(of: url).map { IndexPath(item: $0.index, section: $0.section) }
            })
            collectionView.deselectItems(at: collectionView.selectionIndexPaths.subtracting(paths))
            collectionView.selectItems(at: paths, scrollPosition: [])
            if scroll, let first = paths.min() {
                collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
            }
        }
        selectionDidChange()
    }

    func selectionDidChange() {
        if showsCheckboxes, isDetailsMode { updateVisibleCheckboxes() }
        onSelectionChange?()
    }

    /// Re-applies theme settings (row heights, colours, fonts) after they change.
    func applyTheme() {
        guard isViewLoaded else { return }
        tableView.rowHeight = Theme.detailsRowHeight
        collectionView.backgroundColors = [Theme.paneColor]
        tableView.backgroundColor = Theme.paneColor
        if isDetailsMode {
            tableView.reloadData()
            setSelection(selectedURLs, scroll: false)
        } else {
            reconfigureVisibleItems()
        }
    }

    // MARK: Properties

    /// `items` with tags, dimensions and duration filled in from the cache; starts reading
    /// whatever is missing, and rebuilds when that's done.
    private func itemsWithProperties() -> [FileItem] {
        var missing: [FileItem] = []
        let merged = items.map { item -> FileItem in
            var item = item
            if let cached = propertiesCache[item.url], cached.modified == item.dateModified {
                item.properties = cached.properties
            } else {
                missing.append(item)
            }
            return item
        }
        if !missing.isEmpty { loadProperties(missing) }
        return merged
    }

    private func loadProperties(_ missing: [FileItem]) {
        propertiesTask?.cancel()
        propertiesTask = Task { [weak self] in
            let reader = Task.detached(priority: .utility) { () -> [(FileItem, FileProperties)]? in
                var result: [(FileItem, FileProperties)] = []
                for item in missing {
                    if Task.isCancelled { return nil }
                    result.append((item, FilePropertiesReader.read(item)))
                }
                return result
            }
            let loaded = await withTaskCancellationHandler {
                await reader.value
            } onCancel: {
                reader.cancel()
            }
            guard let self, let loaded, !Task.isCancelled else { return }
            for (item, properties) in loaded {
                propertiesCache[item.url] = (item.dateModified, properties)
            }
            refreshContent()
        }
    }
}
