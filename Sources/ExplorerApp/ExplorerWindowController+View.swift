import AppKit
import ExplorerCore

/// View commands: layout, sort, group, panes, item checkboxes, selection, and per-folder view
/// memory. Changes the user makes are saved for the folder being shown.
extension ExplorerWindowController {
    @objc func chooseViewMode(_ sender: NSMenuItem) {
        guard ViewMode.allCases.indices.contains(sender.tag) else { return }
        setViewMode(ViewMode.allCases[sender.tag])
    }

    func setViewMode(_ mode: ViewMode) {
        content.updateSettings { $0.viewMode = mode }
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = FileItemSortKey(rawValue: raw) else { return }
        content.updateSettings { settings in
            // Picking the current key again keeps its direction, as on Windows.
            if settings.sort.key != key {
                settings.sort = FileItemSort(key: key, ascending: !Self.defaultsToDescending(key))
            }
        }
    }

    /// Dates and sizes start largest-first, like Windows.
    private static func defaultsToDescending(_ key: FileItemSortKey) -> Bool {
        switch key {
        case .dateModified, .dateCreated, .dateDeleted, .size: return true
        default: return false
        }
    }

    @objc func setSortOrder(_ sender: NSMenuItem) {
        content.updateSettings { $0.sort.ascending = sender.tag == 1 }
    }

    @objc func groupBy(_ sender: NSMenuItem) {
        let key = (sender.representedObject as? String).flatMap(FileGroupKey.init(rawValue:))
        content.updateSettings { settings in
            guard settings.grouping?.key != key else { return }
            settings.grouping = key.map { FileGrouping(key: $0) }
        }
    }

    @objc func setGroupOrder(_ sender: NSMenuItem) {
        content.updateSettings { $0.grouping?.ascending = sender.tag == 1 }
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        let pane = rootViewController.sidePane.pane
        rootViewController.showSidePane(pane == .preview ? .none : .preview)
        updateSidePane()
    }

    @objc func toggleDetailsPane(_ sender: Any?) {
        let pane = rootViewController.sidePane.pane
        rootViewController.showSidePane(pane == .details ? .none : .details)
        updateSidePane()
    }

    @objc func toggleItemCheckboxes(_ sender: Any?) {
        content.showsCheckboxes.toggle()
    }

    @objc func selectNone(_ sender: Any?) {
        content.selectNone()
    }

    @objc func invertSelection(_ sender: Any?) {
        content.invertSelection()
    }

    /// Windows' Folder Options › "Apply to Folders": this folder's view becomes every folder's.
    @objc func applyViewToAllFolders(_ sender: Any?) {
        Task {
            let alert = NSAlert()
            alert.messageText = "Do you want all folders to match this folder’s view settings?"
            alert.informativeText = "This applies the layout, sort, grouping and columns to every folder. "
                + "The Recycle Bin and This PC keep their own views."
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            guard await presentAlert(alert) == .alertFirstButtonReturn else { return }
            FolderViewMemory.store.applyToAllFolders(content.settings)
        }
    }

    /// Windows' "Reset Folders": every folder goes back to the default view.
    @objc func resetAllFolders(_ sender: Any?) {
        Task {
            let alert = NSAlert()
            alert.messageText = "Do you want to reset all folders to their default view settings?"
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            guard await presentAlert(alert) == .alertFirstButtonReturn else { return }
            FolderViewMemory.store.resetAllFolders()
            content.show(mode: content.mode, settings: FolderViewMemory.store.settings(for: history.current))
            reload()
        }
    }

    func updateSidePane() {
        rootViewController.sidePane.update(
            selection: content.selectedItems,
            folderName: history.current.displayName,
            itemCount: content.allItems.count
        )
    }

    private func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Validation

    /// Validates the commands above; `nil` for anything else.
    func validateViewMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        if let valid = validateLayoutMenuItem(menuItem) { return valid }
        switch menuItem.action {
        case #selector(togglePreviewPane(_:)):
            menuItem.state = rootViewController.sidePane.pane == .preview ? .on : .off
            return true
        case #selector(toggleDetailsPane(_:)):
            menuItem.state = rootViewController.sidePane.pane == .details ? .on : .off
            return true
        case #selector(toggleItemCheckboxes(_:)):
            menuItem.state = content.showsCheckboxes ? .on : .off
            return true
        case #selector(selectNone(_:)), #selector(invertSelection(_:)):
            return !content.allItems.isEmpty
        case #selector(applyViewToAllFolders(_:)):
            return currentFolder != nil
        case #selector(resetAllFolders(_:)):
            return true
        default:
            return nil
        }
    }

    /// Layout, Sort by and Group by items, with checkmarks for the current choices.
    private func validateLayoutMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        let settings = content.settings
        let inRecycleBin = history.current == .recycleBin
        let hasItems = currentFolder != nil || inRecycleBin || history.current == .thisPC

        switch menuItem.action {
        case #selector(chooseViewMode(_:)):
            menuItem.state = ViewMode.allCases.firstIndex(of: settings.viewMode) == menuItem.tag ? .on : .off
            return hasItems
        case #selector(sortBy(_:)):
            let key = (menuItem.representedObject as? String).flatMap(FileItemSortKey.init(rawValue:))
            menuItem.isHidden = key?.isRecycleBinOnly == true && !inRecycleBin
            menuItem.state = key == settings.sort.key ? .on : .off
            return hasItems
        case #selector(setSortOrder(_:)):
            menuItem.state = settings.sort.ascending == (menuItem.tag == 1) ? .on : .off
            return hasItems
        case #selector(groupBy(_:)):
            let key = (menuItem.representedObject as? String).flatMap(FileGroupKey.init(rawValue:))
            menuItem.isHidden = key?.isRecycleBinOnly == true && !inRecycleBin
            menuItem.state = key == settings.grouping?.key ? .on : .off
            return hasItems
        case #selector(setGroupOrder(_:)):
            menuItem.state = settings.grouping?.ascending == (menuItem.tag == 1) ? .on : .off
            return hasItems && settings.grouping != nil
        default:
            return nil
        }
    }
}

/// The app's per-folder view memory.
@MainActor
enum FolderViewMemory {
    static let store = FolderViewSettingsStore()
}
