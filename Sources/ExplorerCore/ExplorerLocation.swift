import Foundation

/// Anything the user can navigate to: a real folder or one of Explorer's virtual locations.
public enum ExplorerLocation: Sendable, Hashable {
    /// A real directory on disk.
    case folder(URL)
    /// The "Home" page (Quick Access, Favorites, Recent).
    case home
    /// "This PC" — mounted volumes shown as drives.
    case thisPC
    /// Network browser (SMB / Bonjour).
    case network
    /// Aggregated Trash across volumes.
    case recycleBin
    /// Search results for `query` under `scope`.
    case search(query: String, scope: URL)

    /// Creates a folder location with a normalised URL so equal paths compare equal.
    public static func folder(path: String) -> ExplorerLocation {
        .folder(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
    }

    /// Name shown in the window title, tab and breadcrumb.
    public var displayName: String {
        switch self {
        case .folder(let url):
            if let cloud = CloudStorage.root(at: url) { return cloud.title }
            // Localised name; "/" becomes the boot volume name (e.g. "Macintosh HD").
            return FileManager.default.displayName(atPath: url.path)
        case .home: return "Home"
        case .thisPC: return "This PC"
        case .network: return "Network"
        case .recycleBin: return "Recycle Bin"
        case .search(let query, let scope):
            return "Search Results in \(ExplorerLocation.folder(scope).displayName) — \(query)"
        }
    }

    /// The backing directory, if this location is a real folder.
    public var fileURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    /// The location reached by "Up" (Alt+↑), or `nil` at the top of the hierarchy.
    ///
    /// Mirrors Windows: a volume root goes up to This PC, a cloud folder (OneDrive etc.) to
    /// Home; virtual locations other than search have no parent.
    public var parent: ExplorerLocation? {
        switch self {
        case .folder(let url):
            if CloudStorage.root(at: url) != nil { return .home }
            if Self.isVolumeRoot(url) { return .thisPC }
            return .folder(url.deletingLastPathComponent().standardizedFileURL)
        case .search(_, let scope):
            return .folder(scope)
        case .home, .thisPC, .network, .recycleBin:
            return nil
        }
    }

    /// Path from the top of the hierarchy down to this location, used for the breadcrumb.
    public var ancestry: [ExplorerLocation] {
        var chain: [ExplorerLocation] = [self]
        var current = self
        while let parent = current.parent {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// Whether `url` is the root of a volume (a "drive").
    public static func isVolumeRoot(_ url: URL) -> Bool {
        if url.path == "/" { return true }
        let values = try? url.resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume ?? false
    }
}
