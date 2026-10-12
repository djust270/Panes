import Foundation

/// What a folder view displays: items sorted, optionally grouped, with collapsed groups hidden.
/// Addressable both as flat rows (Details view, where group headers are rows) and as
/// sections (icon views).
public struct FileListContent: Sendable {
    public struct Section: Sendable {
        /// `nil` when the view isn't grouped (one section, no header).
        public let group: FileGroup?
        public let isCollapsed: Bool
        /// Items shown: none while collapsed.
        public let items: [FileItem]
    }

    public enum Row: Sendable, Hashable {
        case header(section: Int)
        case item(section: Int, index: Int)
    }

    public let sections: [Section]
    public let rows: [Row]
    /// Every item in display order, including those in collapsed groups.
    public let allItems: [FileItem]
    private let rowByURL: [URL: Int]
    private let indexByURL: [URL: Row]

    public var isGrouped: Bool { sections.first?.group != nil }

    public init(
        items: [FileItem] = [],
        sort: FileItemSort = FileItemSort(),
        grouping: FileGrouping? = nil,
        collapsedGroups: Set<String> = [],
        grouper: FileGrouper = FileGrouper()
    ) {
        let sorted = sort.sorted(items)
        if let grouping {
            let groups = grouper.groups(sorted, by: grouping)
            sections = groups.map { group in
                let collapsed = collapsedGroups.contains(group.id)
                return Section(group: group, isCollapsed: collapsed, items: collapsed ? [] : group.items)
            }
            allItems = groups.flatMap(\.items)
        } else {
            sections = [Section(group: nil, isCollapsed: false, items: sorted)]
            allItems = sorted
        }

        var rows: [Row] = []
        var rowByURL: [URL: Int] = [:]
        var indexByURL: [URL: Row] = [:]
        rows.reserveCapacity(allItems.count + sections.count)
        for (sectionIndex, section) in sections.enumerated() {
            if section.group != nil { rows.append(.header(section: sectionIndex)) }
            for (index, item) in section.items.enumerated() {
                let key = item.url.standardizedFileURL
                rowByURL[key] = rows.count
                indexByURL[key] = .item(section: sectionIndex, index: index)
                rows.append(.item(section: sectionIndex, index: index))
            }
        }
        self.rows = rows
        self.rowByURL = rowByURL
        self.indexByURL = indexByURL
    }

    /// The item on a Details-view row; `nil` for headers and out-of-range rows.
    public func item(atRow row: Int) -> FileItem? {
        guard rows.indices.contains(row), case .item(let section, let index) = rows[row] else { return nil }
        return sections[section].items[index]
    }

    public func item(section: Int, index: Int) -> FileItem? {
        guard sections.indices.contains(section), sections[section].items.indices.contains(index) else { return nil }
        return sections[section].items[index]
    }

    /// The group whose header is on `row`, if it is a header row.
    public func header(atRow row: Int) -> Int? {
        guard rows.indices.contains(row), case .header(let section) = rows[row] else { return nil }
        return section
    }

    /// The Details-view row showing `url`; `nil` if absent or in a collapsed group.
    public func row(of url: URL) -> Int? {
        rowByURL[url.standardizedFileURL]
    }

    /// Section and index of `url` in the icon views; `nil` if absent or collapsed.
    public func position(of url: URL) -> (section: Int, index: Int)? {
        guard case .item(let section, let index) = indexByURL[url.standardizedFileURL] else { return nil }
        return (section, index)
    }

    /// Rows of the items in `section` (for "click a group header to select its items").
    public func itemRows(inSection section: Int) -> IndexSet {
        IndexSet(sections[section].items.compactMap { row(of: $0.url) })
    }

    /// Every row that holds an item (not a header).
    public var allItemRows: IndexSet {
        IndexSet(rows.indices.filter { if case .item = rows[$0] { return true } else { return false } })
    }
}
