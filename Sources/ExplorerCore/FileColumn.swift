import Foundation

/// A Details-view column. Raw values are persisted in folder view settings.
public enum FileColumn: String, Sendable, Codable, CaseIterable {
    case name
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

    public var title: String {
        switch self {
        case .name: return "Name"
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
        }
    }

    public var sortKey: FileItemSortKey {
        switch self {
        case .name: return .name
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
        }
    }

    /// The only kind of list this column appears in, if it's specific to one.
    public var onlyIn: FileListKind? { sortKey.onlyIn }

    /// Whether showing this column requires reading `FileProperties`.
    public var needsProperties: Bool { sortKey.needsProperties }

    /// Columns that can be shown in a list of the given kind.
    public static func available(in kind: FileListKind) -> [FileColumn] {
        allCases.filter { $0.onlyIn == nil || $0.onlyIn == kind }
    }
}

/// What a file list shows, which decides the columns, sorts and groups on offer.
public enum FileListKind: Sendable, Hashable {
    case folder
    /// Adds Original Location and Date Deleted.
    case recycleBin
    /// Adds Folder.
    case searchResults
}
