import Foundation

/// Column a Details-view sort is keyed on.
public enum FileItemSortKey: String, Sendable, CaseIterable {
    case name
    case dateModified
    case type
    case size
}

/// A Details-view sort: a key plus direction, matching Windows Explorer's behaviour that
/// folders always sort before files regardless of direction.
public struct FileItemSort: Sendable, Equatable {
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
        }
    }

    /// Nil sizes (directories, or anything the file system didn't report) always sort last,
    /// regardless of `ascending` — unlike dates, where a missing value is just "oldest."
    private func sizeOrder(_ lhs: Int64?, _ rhs: Int64?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): return 0
        case (nil, _): return ascending ? 1 : -1
        case (_, nil): return ascending ? -1 : 1
        case let (lhs?, rhs?): return order(lhs, rhs)
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
