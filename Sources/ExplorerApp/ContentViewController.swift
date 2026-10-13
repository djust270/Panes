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
    }

    private static let checkboxesKey = "ShowItemCheckboxes"

    var onNavigate: ((ExplorerLocation) -> Void)?
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
    private(set) var listContent = FileListContent()
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
        if isDetailsMode {
            return tableView.selectedRowIndexes.compactMap { listContent.item(atRow: $0) }
        }
        return collectionView.selectionIndexPaths.sorted().compactMap {
            listContent.item(section: $0.section, index: $0.item)
        }
    }

    var selectedURLs: Set<URL> { Set(selectedItems.map(\.url.standardizedFileURL)) }

    let tableView = FileTableView()
    let collectionView = FileCollectionView()
    private let tableScrollView = NSScrollView()
    private let collectionScrollView = NSScrollView()
    private let unavailableLabel = NSTextField(labelWithString: "")
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

    private var propertiesCache: [URL: (modified: Date?, properties: FileProperties)] = [:]
    private var propertiesTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView()

        configureTableView()
        tableScrollView.documentView = tableView
        configureCollectionView()
        collectionScrollView.documentView = collectionView

        for scrollView in [tableScrollView, collectionScrollView] {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        unavailableLabel.textColor = .secondaryLabelColor
        unavailableLabel.alignment = .center
        unavailableLabel.isHidden = true
        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(unavailableLabel)
        NSLayoutConstraint.activate([
            unavailableLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            unavailableLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
        ])

        view = container
        applySettings(settings, notify: false)
    }

    // MARK: Settings

    /// Prepares for a new location: its kind and remembered view. Items follow via `setItems`.
    func show(mode: Mode, settings: FolderViewSettings) {
        finishRenaming(commit: true)
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
        settings = newSettings.sanitized(for: listKind)

        isApplyingSettings = true
        applyTableSettings()
        let isGrouped = settings.grouping != nil || mode == .home
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

        if unavailableLabel.isHidden {
            tableScrollView.isHidden = !isDetailsMode
            collectionScrollView.isHidden = isDetailsMode
        }
        rebuild(selecting: selection, scroll: true)
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
        unavailableLabel.isHidden = true
        tableScrollView.isHidden = !isDetailsMode
        collectionScrollView.isHidden = isDetailsMode

        var selection = selectedURLs
        var scroll = false
        items = newItems
        if let pending = pendingSelection {
            let present = Set(pending).intersection(newItems.map(\.url.standardizedFileURL))
            if !present.isEmpty {
                revealGroups(containing: present)
                selection = present
                scroll = true
                pendingSelection = nil
            }
        }
        rebuild(selecting: selection, scroll: scroll)

        if let rename = pendingRename, listContent.row(of: rename) != nil {
            pendingRename = nil
            beginRenaming(rename)
        }
    }

    /// Selects `urls` (now, or once they appear after a reload) and optionally starts renaming one.
    func select(_ urls: [URL], renaming renameURL: URL? = nil) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let loaded = Set(items.map(\.url.standardizedFileURL))
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
    func showUnavailable(_ message: String) {
        finishRenaming(commit: false)
        items = []
        rebuild(selecting: [], scroll: false)
        unavailableLabel.stringValue = message
        unavailableLabel.isHidden = false
        tableScrollView.isHidden = true
        collectionScrollView.isHidden = true
    }

    /// Rebuilds `listContent` from `items` and reloads the active view.
    func rebuild(selecting selection: Set<URL>, scroll: Bool) {
        if mode == .home {
            listContent = FileListContent(groups: homeGroups, collapsedGroups: collapsedGroups)
        } else {
            let shown = kindFilter.filter(settings.needsProperties ? itemsWithProperties() : items)
            listContent = FileListContent(
                items: shown,
                sort: settings.sort,
                grouping: settings.grouping,
                collapsedGroups: collapsedGroups
            )
        }
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
    private func revealGroups(containing urls: Set<URL>) -> Bool {
        let hidden = listContent.sections.filter { section in
            section.isCollapsed && section.group?.items.contains { urls.contains($0.url.standardizedFileURL) } == true
        }
        let ids = hidden.compactMap(\.group?.id)
        collapsedGroups.subtract(ids)
        return !ids.isEmpty
    }

    func toggleGroup(_ id: String) {
        finishRenaming(commit: true)
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
        rebuild(selecting: selectedURLs, scroll: false)
    }

    func selectGroup(_ id: String) {
        guard let group = listContent.sections.first(where: { $0.group?.id == id })?.group else { return }
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
            rebuild(selecting: [], scroll: false)
        }
        setSelection(Set(group.items.map(\.url.standardizedFileURL)), scroll: false)
        view.window?.makeFirstResponder(activeView)
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

    // MARK: Activation

    @objc func activateSelection() {
        let selected = selectedItems
        guard !selected.isEmpty, mode != .recycleBin else { return }
        if selected.count == 1, let only = selected.first, only.isFolder {
            onNavigate?(.folder(only.url))
            return
        }
        let files = selected.filter { !$0.isFolder }.map(\.url)
        for file in files {
            NSWorkspace.shared.open(file)
        }
        // Apps and other packages aren't "recent files".
        QuickAccess.recordOpen(of: selected.filter { $0.kind == .file }.map(\.url))
    }

    /// Type-ahead: selects the next item whose name starts with what's been typed. Returns
    /// `false` if the key should be handled normally (a space with nothing typed yet).
    func typeAhead(_ text: String) -> Bool {
        let now = Date()
        if text == " ", typeAhead.currentPrefix(at: now) == nil { return false }
        let visible = listContent.sections.flatMap(\.items)
        let selected = selectedURLs
        let current = visible.firstIndex { selected.contains($0.url.standardizedFileURL) }
        if let index = typeAhead.type(text, at: now, names: visible.map(\.name), current: current) {
            setSelection([visible[index].url.standardizedFileURL], scroll: true)
        } else {
            NSSound.beep()
        }
        return true
    }

    /// Middle-click on a folder opens it in a new tab.
    func openInNewTab(_ item: FileItem) {
        guard item.isFolder, mode != .recycleBin else { return }
        onOpenInNewTab?(.folder(item.url))
    }

    /// Re-applies theme settings (row heights, colours, fonts) after they change.
    func applyTheme() {
        guard isViewLoaded else { return }
        tableView.rowHeight = Theme.detailsRowHeight
        collectionView.backgroundColors = [Theme.bodyColor]
        tableView.backgroundColor = Theme.bodyColor
        if isDetailsMode {
            tableView.reloadData()
            setSelection(selectedURLs, scroll: false)
        } else {
            reconfigureVisibleItems()
        }
    }

    // MARK: Display helpers

    func icon(for item: FileItem) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    func isCut(_ item: FileItem) -> Bool {
        cutURLs.contains(item.url.standardizedFileURL)
    }

    /// Redraws visible items after a change that doesn't affect layout (cut, checkboxes).
    func reconfigureVisibleItems() {
        if isDetailsMode {
            let visible = tableView.rows(in: tableView.visibleRect)
            let rows = IndexSet(integersIn: visible.location..<visible.location + visible.length)
                .filteredIndexSet { listContent.item(atRow: $0) != nil }
            guard !rows.isEmpty else { return }
            let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
            tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
        } else {
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let cell = collectionView.item(at: indexPath) as? FileCollectionItem else { continue }
                configure(cell, at: indexPath)
            }
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
