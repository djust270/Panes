import Foundation

/// A Details-view column. Raw values are persisted in folder view settings.
public enum FileColumn: String, Sendable, Codable, CaseIterable {
    case name
    /// Sync state in cloud folders (OneDrive etc.).
    case status
    case originalLocation = "original-location"
    case dateDeleted = "date-deleted"
    case dateModified = "date-modified"
    case type
    case size
    case dateCreated = "date-created"
    case tags
    case dimensions
    case duration
    /// Search results only: the folder holding the item.
    case folder
    /// This PC only.
    case totalSize = "total-size"
    /// This PC only.
    case freeSpace = "free-space"

    public var title: String {
        switch self {
        case .name: return "Name"
        case .status: return "Status"
        case .originalLocation: return "Original Location"
        case .dateDeleted: return "Date Deleted"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .dateCreated: return "Date created"
        case .tags: return "Tags"
        case .dimensions: return "Dimensions"
        case .duration: return "Duration"
        case .folder: return "Folder"
        case .totalSize: return "Total Size"
        case .freeSpace: return "Free Space"
        }
    }

    public var sortKey: FileItemSortKey {
        switch self {
        case .name: return .name
        case .status: return .status
        case .originalLocation: return .originalLocation
        case .dateDeleted: return .dateDeleted
        case .dateModified: return .dateModified
        case .type: return .type
        case .size: return .size
        case .dateCreated: return .dateCreated
        case .tags: return .tags
        case .dimensions: return .dimensions
        case .duration: return .duration
        case .folder: return .folder
        case .totalSize: return .totalSize
        case .freeSpace: return .freeSpace
        }
    }

    /// The only kind of list this column appears in, if it's specific to one.
    public var onlyIn: FileListKind? { sortKey.onlyIn }

    /// Whether showing this column requires reading `FileProperties`.
    public var needsProperties: Bool { sortKey.needsProperties }

    /// Columns that can be shown in a list of the given kind.
    public static func available(in kind: FileListKind) -> [FileColumn] {
        // Drives have no dates, tags or media properties.
        if kind == .drives { return [.name, .type, .totalSize, .freeSpace] }
        return allCases.filter { $0.onlyIn == nil || $0.onlyIn == kind }
    }
}

/// What a file list shows, which decides the columns, sorts and groups on offer.
public enum FileListKind: Sendable, Hashable {
    case folder
    /// Adds Original Location and Date Deleted.
    case recycleBin
    /// Adds Folder.
    case searchResults
    /// This PC: Name, Type, Total Size and Free Space.
    case drives
}
