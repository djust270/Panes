import AppKit
import ExplorerCore

/// Home (Quick access, Favorites, Recent), the search box and search results, and the Quick
/// access and Favorites commands.
extension ExplorerTabController {
    // MARK: Home

    /// Pinned and frequent folders, favorite files, and recent files from Spotlight and this
    /// app's own history. Missing files and folders are left out.
    func loadHome() {
        let store = QuickAccess.store
        let folders = store.pinnedFolders + store.frequentFolders()
        let favorites = store.favorites
        loadTask = Task { [weak self] in
            let found = await SpotlightRecents.fetch()
            guard !Task.isCancelled else { return }
            let recent = store.recentFiles(merging: found, limit: 40)
            let loaded = await Task.detached(priority: .userInitiated) {
                (
                    folders.compactMap(FileItem.load).filter(\.isFolder),
                    favorites.compactMap(FileItem.load),
                    recent.compactMap { file in FileItem.load(file.url).map { ($0, file.lastUsed) } }
                        .filter { !$0.0.isFolder }
                        .prefix(20)
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            let (folderItems, favoriteItems, recentItems) = loaded
            let dates = Dictionary(recentItems.map { ($0.0.url.standardizedFileURL.path, $0.1) }) { first, _ in first }
            content.setHomeGroups([
                HomeSection.quickAccess.group(folderItems),
                HomeSection.favorites.group(favoriteItems),
                HomeSection.recent.group(recentItems.map(\.0)),
            ], dates: dates)
            updateStatusBar()
        }
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: .home)
    }

    // MARK: Search box

    /// What the search box searches from here: the folder, the home folder from Home, every
    /// local volume from This PC; nothing from the Recycle Bin or Network.
    var searchScope: URL? {
        switch history.current {
        case .folder(let url): return url
        case .search(_, let scope): return scope
        case .home: return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        case .thisPC: return URL(fileURLWithPath: "/")
        case .recycleBin, .network, .remote: return nil
        }
    }

    /// Shows the current query (or none) and "Search <place>".
    func updateSearchField() {
        let place: String
        switch history.current {
        case .search(_, let scope): place = ExplorerLocation.folder(scope).displayName
        default: place = history.current.displayName
        }
        var query = ""
        if case .search(let text, _) = history.current { query = text }
        addressBar.setSearch(query: query, placeholder: "Search \(place)", isEnabled: searchScope != nil)
    }

    /// Ctrl+F, Ctrl+E, F3: put the cursor in the search box.
    @objc func focusSearch(_ sender: Any?) {
        addressBar.focusSearch()
    }

    /// Searches as the user types, once they pause.
    func searchTextDidChange(_ text: String) {
        searchDelay?.cancel()
        searchDelay = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.search(for: text)
        }
    }

    /// Shows results for `text`. Refining a search replaces it in the history rather than
    /// adding a step per keystroke; clearing the box goes back to where the search started.
    func search(for text: String) {
        searchDelay?.cancel()
        let text = text.trimmingCharacters(in: .whitespaces)
        if case .search(_, let scope) = history.current {
            guard !text.isEmpty else {
                cancelSearch()
                return
            }
            let location = ExplorerLocation.search(query: text, scope: scope)
            guard location != history.current else { return }
            replace(with: location)
        } else if !text.isEmpty, let scope = searchScope {
            navigate(to: .search(query: text, scope: scope))
        }
    }

    /// Escape or clearing the box: leave the search results.
    func cancelSearch() {
        searchDelay?.cancel()
        guard case .search(_, let scope) = history.current else {
            updateSearchField()
            return
        }
        if history.canGoBack {
            goBack(steps: 1)
        } else {
            navigate(to: .folder(scope))
        }
    }

    func runSearch(_ text: String, in scope: URL) {
        let query = SearchQuery(parsing: text)
        guard !query.isEmpty else {
            content.showUnavailable("Type what to search for.")
            rootViewController.statusBar.text = ""
            return
        }
        isSearchRunning = true
        isSearchTruncated = false
        updateStatusBar()
        let results = FileSearch.start(query, in: scope, includeHidden: loader.options.includeHidden)
        loadTask = Task { [weak self] in
            for await progress in results {
                guard let self, !Task.isCancelled else { return }
                isSearchRunning = !progress.isComplete
                isSearchTruncated = progress.isTruncated
                if progress.isComplete, progress.items.isEmpty {
                    content.showUnavailable("No items match your search.")
                } else {
                    content.setItems(progress.items)
                }
                updateStatusBar()
            }
        }
    }

    // MARK: Quick access and Favorites

    private var selectedFolderURLs: [URL] { content.selectedItems.filter(\.isFolder).map(\.url) }
    private var selectedFileURLs: [URL] { content.selectedItems.filter { !$0.isFolder }.map(\.url) }

    @objc func pinToQuickAccess(_ sender: Any?) {
        let folders = selectedFolderURLs
        QuickAccess.change { store in folders.forEach(store.pin) }
    }

    @objc func unpinFromQuickAccess(_ sender: Any?) {
        let folders = selectedFolderURLs
        QuickAccess.change { store in folders.forEach(store.unpin) }
    }

    @objc func addToFavorites(_ sender: Any?) {
        let files = selectedFileURLs
        QuickAccess.change { store in files.forEach(store.addFavorite) }
    }

    @objc func removeFromFavorites(_ sender: Any?) {
        let files = selectedFileURLs
        QuickAccess.change { store in files.forEach(store.removeFavorite) }
    }

    /// Home: hides frequent folders from Quick access.
    @objc func removeFromFrequent(_ sender: Any?) {
        let folders = selectedFolderURLs
        QuickAccess.change { store in folders.forEach(store.removeFromFrequent) }
    }

    /// Home: hides files from Recent until they're opened again.
    @objc func removeFromRecent(_ sender: Any?) {
        let files = selectedFileURLs
        QuickAccess.change { store in files.forEach { store.removeFromRecent($0) } }
    }

    /// Search results and Home: opens the item's folder with the item selected.
    @objc func openFileLocation(_ sender: Any?) {
        guard let item = content.selectedItems.first else { return }
        navigate(to: .folder(item.url.deletingLastPathComponent().standardizedFileURL))
        content.select([item.url])
    }

    /// Validates the commands above; `nil` for anything else.
    func validateSearchMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        let selection = content.selectedItems
        switch menuItem.action {
        case #selector(focusSearch(_:)):
            return searchScope != nil
        case #selector(goHome(_:)):
            return true
        case #selector(pinToQuickAccess(_:)), #selector(unpinFromQuickAccess(_:)), #selector(removeFromFrequent(_:)):
            return !selection.isEmpty && selection.allSatisfy(\.isFolder) && history.current != .recycleBin
        case #selector(addToFavorites(_:)), #selector(removeFromFavorites(_:)), #selector(removeFromRecent(_:)):
            return !selection.isEmpty && !selection.contains(where: \.isFolder) && history.current != .recycleBin
        case #selector(openFileLocation(_:)):
            return selection.count == 1 && (inSearchResults || history.current == .home)
        default:
            return nil
        }
    }
}
