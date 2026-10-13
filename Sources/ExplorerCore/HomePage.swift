import Foundation

/// Home's three groups, in order.
public enum HomeSection: String, Sendable, CaseIterable {
    /// Pinned and frequent folders, shown as tiles.
    case quickAccess = "home:quick-access"
    /// Files added to Favorites.
    case favorites = "home:favorites"
    /// Recently used files.
    case recent = "home:recent"

    public var title: String {
        switch self {
        case .quickAccess: return "Quick access"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }

    /// The group (and so the section) this is, given a group ID.
    public init?(groupID: String?) {
        guard let groupID else { return nil }
        self.init(rawValue: groupID)
    }

    /// The group to show for `items`, in the order given.
    public func group(_ items: [FileItem]) -> FileGroup {
        FileGroup(id: rawValue, title: title, items: items)
    }
}
