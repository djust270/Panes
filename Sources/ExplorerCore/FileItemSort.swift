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
        }
    }

    /// Whether sorting by this key requires reading `FileProperties`.
    public var needsProperties: Bool { self == .tags || self == .dimensions || self == .duration }

    public var isRecycleBinOnly: Bool { self == .originalLocation || self == .dateDeleted }
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

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder
            }
            let result = compare(lhs, rhs)
            if result != 0 {
                return ascending ? result < 0 : result > 0
            }
            return nameOrder(lhs, rhs) < 0
        }
    }

    private func compare(_ lhs: FileItem, _ rhs: FileItem) -> Int {
        switch key {
        case .name:
            return nameOrder(lhs, rhs)
        case .dateModified:
            return order(lhs.dateModified ?? .distantPast, rhs.dateModified ?? .distantPast)
        case .type:
            return nameOrder0(lhs.typeDescription, rhs.typeDescription)
        case .size:
            return sizeOrder(lhs.size, rhs.size)
        case .dateCreated:
            return order(lhs.dateCreated ?? .distantPast, rhs.dateCreated ?? .distantPast)
        case .tags:
            return emptyLastOrder(lhs.properties?.tagsText ?? "", rhs.properties?.tagsText ?? "")
        case .dimensions:
            return sizeOrder(lhs.properties?.pixelCount.map(Int64.init), rhs.properties?.pixelCount.map(Int64.init))
        case .duration:
            return sizeOrder(
                lhs.properties?.duration.map { Int64($0 * 1000) },
                rhs.properties?.duration.map { Int64($0 * 1000) }
            )
        case .originalLocation:
            return nameOrder0(lhs.originalFolderPath, rhs.originalFolderPath)
        case .dateDeleted:
            return order(lhs.trashInfo?.dateDeleted ?? .distantPast, rhs.trashInfo?.dateDeleted ?? .distantPast)
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
    private func emptyLastOrder(_ lhs: String, _ rhs: String) -> Int {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return 0
        case (true, false): return ascending ? 1 : -1
        case (false, true): return ascending ? -1 : 1
        case (false, false): return nameOrder0(lhs, rhs)
        }
    }

    private func nameOrder(_ lhs: FileItem, _ rhs: FileItem) -> Int {
        nameOrder0(lhs.name, rhs.name)
    }

    private func nameOrder0(_ lhs: String, _ rhs: String) -> Int {
        switch lhs.localizedStandardCompare(rhs) {
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
}
