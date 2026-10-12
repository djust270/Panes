import Foundation

/// What a folder's items can be grouped by.
public enum FileGroupKey: String, Sendable, Codable, CaseIterable {
    case name
    case dateModified
    case dateCreated
    case type
    case size
    /// Recycle Bin only.
    case originalLocation
    /// Recycle Bin only.
    case dateDeleted

    public var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .dateCreated: return "Date created"
        case .type: return "Type"
        case .size: return "Size"
        case .originalLocation: return "Original Location"
        case .dateDeleted: return "Date Deleted"
        }
    }

    /// Dates group newest-first by default ("Today" on top), everything else A→Z.
    public var defaultAscending: Bool {
        switch self {
        case .dateModified, .dateCreated, .dateDeleted: return false
        default: return true
        }
    }

    public var isRecycleBinOnly: Bool { self == .originalLocation || self == .dateDeleted }
}

/// A Group by choice: key plus the order of the groups themselves.
public struct FileGrouping: Sendable, Hashable, Codable {
    public var key: FileGroupKey
    public var ascending: Bool

    public init(key: FileGroupKey, ascending: Bool? = nil) {
        self.key = key
        self.ascending = ascending ?? key.defaultAscending
    }
}

/// One collapsible group, e.g. "Today" or "A - H".
public struct FileGroup: Sendable, Hashable {
    /// Stable across reloads, used to remember collapsed groups.
    public let id: String
    public let title: String
    public var items: [FileItem]
}

/// Assigns items to Windows Explorer's groups.
public struct FileGrouper: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// Groups already-sorted items, keeping their order within each group. Groups are ordered
    /// by `grouping.ascending`, except "Unspecified", which always comes last.
    public func groups(_ sortedItems: [FileItem], by grouping: FileGrouping) -> [FileGroup] {
        var order: [Bucket] = []
        var members: [Bucket: [FileItem]] = [:]
        for item in sortedItems {
            let bucket = bucket(for: item, key: grouping.key)
            if members[bucket] == nil { order.append(bucket) }
            members[bucket, default: []].append(item)
        }

        let sorted = order.sorted { lhs, rhs in
            if lhs.isUnspecified != rhs.isUnspecified { return rhs.isUnspecified }
            if lhs.rank != rhs.rank { return grouping.ascending ? lhs.rank < rhs.rank : lhs.rank > rhs.rank }
            let byTitle = lhs.title.localizedStandardCompare(rhs.title)
            return grouping.ascending ? byTitle == .orderedAscending : byTitle == .orderedDescending
        }
        return sorted.map { bucket in
            FileGroup(id: "\(grouping.key.rawValue):\(bucket.title)", title: bucket.title, items: members[bucket] ?? [])
        }
    }

    private struct Bucket: Hashable {
        let rank: Int
        let title: String
        var isUnspecified: Bool { rank == Int.max }

        static let unspecified = Bucket(rank: Int.max, title: "Unspecified")
    }

    private func bucket(for item: FileItem, key: FileGroupKey) -> Bucket {
        switch key {
        case .name: return nameBucket(item.name)
        case .dateModified: return dateBucket(item.dateModified)
        case .dateCreated: return dateBucket(item.dateCreated)
        case .dateDeleted: return dateBucket(item.trashInfo?.dateDeleted)
        case .type: return Bucket(rank: 0, title: item.typeDescription)
        case .size: return sizeBucket(item.size)
        case .originalLocation:
            let path = item.originalFolderPath
            return path.isEmpty ? .unspecified : Bucket(rank: 0, title: path)
        }
    }

    private func nameBucket(_ name: String) -> Bucket {
        let first = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first
        guard let first, first.isASCII else { return Bucket(rank: 4, title: "Other") }
        switch first {
        case "0"..."9": return Bucket(rank: 0, title: "0 - 9")
        case "a"..."h": return Bucket(rank: 1, title: "A - H")
        case "i"..."p": return Bucket(rank: 2, title: "I - P")
        case "q"..."z": return Bucket(rank: 3, title: "Q - Z")
        default: return Bucket(rank: 4, title: "Other")
        }
    }

    /// Ranks run oldest (0) to newest, so ascending order is chronological.
    private func dateBucket(_ date: Date?) -> Bucket {
        guard let date else { return .unspecified }
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? now
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        let thisYear = calendar.dateInterval(of: .year, for: now)?.start ?? today

        if date >= tomorrow { return Bucket(rank: 9, title: "In the future") }
        if date >= today { return Bucket(rank: 8, title: "Today") }
        if date >= yesterday { return Bucket(rank: 7, title: "Yesterday") }
        if date >= thisWeek { return Bucket(rank: 6, title: "Earlier this week") }
        if date >= lastWeek { return Bucket(rank: 5, title: "Last week") }
        if date >= thisMonth { return Bucket(rank: 4, title: "Earlier this month") }
        if date >= lastMonth { return Bucket(rank: 3, title: "Last month") }
        if date >= thisYear { return Bucket(rank: 2, title: "Earlier this year") }
        return Bucket(rank: 1, title: "A long time ago")
    }

    /// Windows 11's size groups.
    private func sizeBucket(_ size: Int64?) -> Bucket {
        guard let size else { return .unspecified }
        let kb: Int64 = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        switch size {
        case 0: return Bucket(rank: 0, title: "Empty (0 KB)")
        case ..<(16 * kb): return Bucket(rank: 1, title: "Tiny (0 - 16 KB)")
        case ..<mb: return Bucket(rank: 2, title: "Small (16 KB - 1 MB)")
        case ..<(128 * mb): return Bucket(rank: 3, title: "Medium (1 - 128 MB)")
        case ..<gb: return Bucket(rank: 4, title: "Large (128 MB - 1 GB)")
        case ..<(4 * gb): return Bucket(rank: 5, title: "Huge (1 - 4 GB)")
        default: return Bucket(rank: 6, title: "Gigantic (> 4 GB)")
        }
    }
}
