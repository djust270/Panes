import Foundation

/// Column a Details-view sort is keyed on.
public enum FileItemSortKey: String, Sendable, Codable, CaseIterable {
    case name
    case dateModified
    case type
    case size
    case dateCreated
    case tags
    case dimensions
    case duration
    /// Recycle Bin only.
    case originalLocation
    /// Recycle Bin only.
    case dateDeleted
    /// Search results only.
    case folder
    /// This PC only.
    case totalSize
    /// This PC only.
    case freeSpace

    public var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .dateCreated: return "Date created"
        case .tags: return "Tags"
        case .dimensions: return "Dimensions"
        case .duration: return "Duration"
        case .originalLocation: return "Original Location"
        case .dateDeleted: return "Date Deleted"
        case .folder: return "Folder"
        case .totalSize: return "Total Size"
        case .freeSpace: return "Free Space"
        }
    }

    /// Whether sorting by this key requires reading `FileProperties`.
    public var needsProperties: Bool { self == .tags || self == .dimensions || self == .duration }

    /// The only kind of list this key applies to, if it's specific to one.
    public var onlyIn: FileListKind? {
        switch self {
        case .originalLocation, .dateDeleted: return .recycleBin
        case .folder: return .searchResults
        case .totalSize, .freeSpace: return .drives
        default: return nil
        }
    }

    /// Whether a list of `kind` can be sorted by this key (This PC only by its own columns).
    public func isAvailable(in kind: FileListKind) -> Bool {
        if kind == .drives { return FileColumn.available(in: .drives).contains { $0.sortKey == self } }
        return onlyIn == nil || onlyIn == kind
    }
}

/// A Details-view sort: a key plus direction, matching Windows Explorer's behaviour that
/// folders always sort before files regardless of direction.
public struct FileItemSort: Sendable, Hashable, Codable {
    public var key: FileItemSortKey
    public var ascending: Bool

    public init(key: FileItemSortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// Folders first, then by the key; ties by name. Each item's key is computed once, not
    /// once per comparison (type names come from LaunchServices), and names are compared as
    /// `NSString`s, which skips bridging: 100,000 items sort in well under a second.
    public func sorted(_ items: [FileItem]) -> [FileItem] {
        // Plain arrays: reading a field through `items[i]` copies (and retains) the whole item.
        let names = items.map { $0.name as NSString }
        let folders = items.map(\.isFolder)
        let keys = items.map(sortValue)
        let order = Array(items.indices).sorted { lhs, rhs in
            if folders[lhs] != folders[rhs] {
                return folders[lhs]
            }
            let result = key == .name ? nameOrder0(names[lhs], names[rhs]) : compare(keys[lhs], keys[rhs])
            if result != 0 {
                return ascending ? result < 0 : result > 0
            }
            return nameOrder0(names[lhs], names[rhs]) < 0
        }
        return order.map { items[$0] }
    }

    /// An item's value for the sort key.
    private enum SortValue {
        case name
        case text(NSString)
        /// Empty text sorts last in either direction.
        case textEmptyLast(NSString)
        /// `nil` sorts last in either direction.
        case number(Int64?)
        case date(Date)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func sortValue(_ item: FileItem) -> SortValue {
        switch key {
        case .name: return .name
        case .dateModified: return .date(item.dateModified ?? .distantPast)
        case .type: return .text(item.typeDescription as NSString)
        case .size: return .number(item.size)
        case .dateCreated: return .date(item.dateCreated ?? .distantPast)
        case .tags: return .textEmptyLast((item.properties?.tagsText ?? "") as NSString)
        case .dimensions: return .number(item.properties?.pixelCount.map(Int64.init))
        case .duration: return .number(item.properties?.duration.map { Int64($0 * 1000) })
        case .originalLocation: return .text(item.originalFolderPath as NSString)
        case .dateDeleted: return .date(item.trashInfo?.dateDeleted ?? .distantPast)
        case .folder: return .text(item.folderPath as NSString)
        case .totalSize: return .number(item.volume?.totalCapacity)
        case .freeSpace: return .number(item.volume?.availableCapacity)
        }
    }

    /// Ties compare equal (the caller breaks them by name); `.name` is compared by the caller.
    private func compare(_ lhs: SortValue, _ rhs: SortValue) -> Int {
        switch (lhs, rhs) {
        case let (.text(lhs), .text(rhs)): return nameOrder0(lhs, rhs)
        case let (.textEmptyLast(lhs), .textEmptyLast(rhs)): return emptyLastOrder(lhs, rhs)
        case let (.number(lhs), .number(rhs)): return sizeOrder(lhs, rhs)
        case let (.date(lhs), .date(rhs)): return order(lhs, rhs)
        default: return 0
        }
    }

    /// Nil sizes (directories, or anything the file system didn't report) always sort last,
    /// regardless of `ascending` — unlike dates, where a missing value is just "oldest."
    /// Also used for dimensions and durations.
    private func sizeOrder(_ lhs: Int64?, _ rhs: Int64?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): return 0
        case (nil, _): return ascending ? 1 : -1
        case (_, nil): return ascending ? -1 : 1
        case let (lhs?, rhs?): return order(lhs, rhs)
        }
    }

    /// Empty text (e.g. untagged files) sorts last in either direction.
    private func emptyLastOrder(_ lhs: NSString, _ rhs: NSString) -> Int {
        switch (lhs.length == 0, rhs.length == 0) {
        case (true, true): return 0
        case (true, false): return ascending ? 1 : -1
        case (false, true): return ascending ? -1 : 1
        case (false, false): return nameOrder0(lhs, rhs)
        }
    }

    private func nameOrder0(_ lhs: NSString, _ rhs: NSString) -> Int {
        switch lhs.localizedStandardCompare(rhs as String) {
        case .orderedAscending: return -1
        case .orderedSame: return 0
        case .orderedDescending: return 1
        }
    }

    private func order<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }
}

extension FileItem {
    /// The Recycle Bin's "Original Location" column: the folder the item was deleted from.
    public var originalFolderPath: String {
        trashInfo?.originalURL?.deletingLastPathComponent().path ?? ""
    }

    /// Search results' "Folder" column: the folder holding the item.
    public var folderPath: String {
        url.deletingLastPathComponent().path
    }
}
