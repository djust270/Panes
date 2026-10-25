import Foundation

/// Sibling/child locations for a breadcrumb segment's chevron dropdown menu.
public enum LocationChildren {
    /// Child locations of `location`, naturally sorted by name. A lightweight synchronous
    /// listing — just names for a menu, not the full resource-value prefetch `DirectoryLoader`
    /// does for a Details-view row. Listing failures (permissions, a location that no longer
    /// exists) yield `[]` rather than throwing, since this only ever feeds an optional menu.
    public static func of(_ location: ExplorerLocation) -> [ExplorerLocation] {
        switch location {
        case .folder(let url):
            return subfolders(of: url)
        case .thisPC:
            return VolumeLister.mountedVolumes().map { .folder($0.url.standardizedFileURL) }
        case .home:
            // Cloud folders (OneDrive etc.) are Home's children in breadcrumbs.
            return CloudStorage.roots().map { .folder($0.url) }
        case .network, .recycleBin, .search:
            return []
        }
    }

    private static func subfolders(of url: URL) -> [ExplorerLocation] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let folders = urls.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true
        }
        let sorted = folders.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return sorted.map { .folder($0.standardizedFileURL) }
    }
}
