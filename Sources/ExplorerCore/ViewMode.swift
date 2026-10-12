import Foundation

/// Explorer's eight folder layouts, in the order Windows lists them (Ctrl+Shift+1…8).
public enum ViewMode: String, Sendable, Codable, CaseIterable {
    case extraLargeIcons
    case largeIcons
    case mediumIcons
    case smallIcons
    case list
    case details
    case tiles
    case content

    public var title: String {
        switch self {
        case .extraLargeIcons: return "Extra large icons"
        case .largeIcons: return "Large icons"
        case .mediumIcons: return "Medium icons"
        case .smallIcons: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }

    /// Edge length of the item's icon, in points.
    public var iconSize: Double {
        switch self {
        case .extraLargeIcons: return 256
        case .largeIcons: return 96
        case .mediumIcons: return 48
        case .smallIcons, .list, .details: return 16
        case .tiles: return 48
        case .content: return 40
        }
    }

    /// Whether items show a content thumbnail (pictures, documents…) instead of a type icon.
    /// As on Windows, only the larger layouts do.
    public var showsThumbnails: Bool { iconSize >= 40 }

    /// The icon layouts, where the name sits under the icon.
    public var isIconGrid: Bool {
        self == .extraLargeIcons || self == .largeIcons || self == .mediumIcons
    }
}
