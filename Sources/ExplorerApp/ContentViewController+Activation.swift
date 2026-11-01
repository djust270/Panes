import AppKit
import ExplorerCore

/// Opening items, type-ahead, group headers and per-item display helpers.
extension ContentViewController {
    // MARK: Activation

    @objc func activateSelection() {
        let selected = selectedItems
        guard !selected.isEmpty, mode != .recycleBin else { return }
        if mode == .network {
            guard let computer = selected.first else { return }
            if let server = RemotePath(url: computer.url) {
                onNavigate?(.remote(server))
            } else {
                onConnect?(computer.url)
            }
            return
        }
        if selected.count == 1, let only = selected.first, only.isFolder, let location = location(for: only) {
            onNavigate?(location)
            return
        }
        if mode == .remote {
            RemoteCenter.open(selected, from: view.window)
            return
        }
        CloudCenter.open(selected.filter { !$0.isFolder }.map(\.url))
        // Apps and other packages aren't "recent files".
        QuickAccess.recordOpen(of: selected.filter { $0.kind == .file }.map(\.url))
    }

    /// Type-ahead: selects the next item whose name starts with what's been typed. Returns
    /// `false` if the key should be handled normally (a space with nothing typed yet).
    func typeAhead(_ text: String) -> Bool {
        let now = Date()
        if text == " ", typeAhead.currentPrefix(at: now) == nil { return false }
        // Ungrouped, that's `allItems` itself, without copying 100,000 items per key.
        let visible = listContent.isGrouped ? listContent.sections.flatMap(\.items) : listContent.allItems
        let showsExtensions = AppSettings.showsFileExtensions
        let names = visible.lazy.map { $0.displayName(showingExtensions: showsExtensions) }
        let selected = selectedURLs
        let current = visible.firstIndex { selected.contains($0.url) }
        if let index = typeAhead.type(text, at: now, names: names, current: current) {
            setSelection([visible[index].url], scroll: true)
        } else {
            NSSound.beep()
        }
        return true
    }

    /// Middle-click on a folder opens it in a new tab.
    func openInNewTab(_ item: FileItem) {
        guard mode != .recycleBin, mode != .network, let location = location(for: item) else { return }
        onOpenInNewTab?(location)
    }

    /// Where opening a folder item goes: a local or a remote folder. `nil` for files.
    func location(for item: FileItem) -> ExplorerLocation? {
        guard item.isFolder else { return nil }
        if let remote = RemotePath(url: item.url) { return .remote(remote) }
        return .folder(item.url)
    }

    // MARK: Display helpers

    func icon(for item: FileItem) -> NSImage {
        if mode == .network {
            let symbol = item.isRemote ? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) : nil
            return symbol ?? NSImage(named: NSImage.computerName) ?? NSImage()
        }
        return FileIcons.icon(for: item)
    }

    func isCut(_ item: FileItem) -> Bool {
        cutURLs.contains(item.url)
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

    // MARK: Groups

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
        setSelection(Set(group.items.map(\.url)), scroll: false)
        view.window?.makeFirstResponder(activeView)
    }
}
