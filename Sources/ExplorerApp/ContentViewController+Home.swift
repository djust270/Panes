import AppKit
import ExplorerCore

/// Home, This PC and search results: Home's and This PC's fixed groups, and pruning results
/// that were moved away.
extension ContentViewController {
    /// The kind of list shown, which decides the columns, sorts and groups on offer.
    var listKind: FileListKind {
        switch mode {
        case .recycleBin: return .recycleBin
        case .search: return .searchResults
        case .volumes: return .drives
        case .folder, .home, .network, .remote: return .folder
        }
    }

    /// Shows Home's groups; `dates` are when Favorites and Recent files were last used.
    func setHomeGroups(_ groups: [FileGroup], dates: [String: Date]) {
        homeGroups = groups
        homeDates = dates
        setItems(groups.flatMap(\.items))
    }

    /// The Home group holding `item`, if Home is showing.
    func homeSection(of item: FileItem) -> HomeSection? {
        guard mode == .home, let position = listContent.position(of: item.url) else { return nil }
        return HomeSection(groupID: listContent.sections[position.section].group?.id)
    }

    /// This PC's groups, as on Windows: "Devices and drives", then "Network locations", each
    /// sorted by the view's sort.
    func driveGroups() -> [FileGroup] {
        let sorted = settings.sort.sorted(items)
        let network = sorted.filter { $0.volume?.kind == .network }
        let local = sorted.filter { $0.volume?.kind != .network }
        return [
            FileGroup(id: "drives:local", title: "Devices and drives", items: local),
            FileGroup(id: "drives:network", title: "Network locations", items: network),
        ].filter { !$0.items.isEmpty }
    }

    /// Drops items that no longer exist (after deleting or moving from search results).
    func removeMissingItems() {
        let present = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard present.count != items.count else { return }
        setItems(present)
    }
}
