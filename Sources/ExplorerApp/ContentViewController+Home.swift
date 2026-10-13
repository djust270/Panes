import AppKit
import ExplorerCore

/// Home and search results: Home's fixed groups, and pruning results that were moved away.
extension ContentViewController {
    /// The kind of list shown, which decides the columns, sorts and groups on offer.
    var listKind: FileListKind {
        switch mode {
        case .recycleBin: return .recycleBin
        case .search: return .searchResults
        case .folder, .volumes, .home: return .folder
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

    /// Drops items that no longer exist (after deleting or moving from search results).
    func removeMissingItems() {
        let present = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard present.count != items.count else { return }
        setItems(present)
    }
}
