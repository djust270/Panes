import Foundation

/// One row in the navigation pane.
public struct SidebarItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// SF Symbol name; a placeholder until Phase 4 brings Fluent UI icons.
    public let symbolName: String
    public let location: ExplorerLocation
    public let isExpandable: Bool

    public init(id: String, title: String, symbolName: String, location: ExplorerLocation, isExpandable: Bool = false) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.location = location
        self.isExpandable = isExpandable
    }
    /// A Quick access pin (unpinned from its context menu).
    public var isPinnedFolder: Bool { id.hasPrefix(SidebarTree.pinIDPrefix) }
}

/// The navigation pane's two-level tree: root items (Home, cloud folders, the Quick access
/// pins, This PC, Network, Recycle Bin); mounted volumes under This PC, and SSH servers
/// under Network.
public enum SidebarTree {
    private struct WellKnownFolder {
        let title: String
        let symbolName: String
        let searchPathDirectory: FileManager.SearchPathDirectory
    }

    private static let wellKnownFolders: [WellKnownFolder] = [
        WellKnownFolder(title: "Desktop", symbolName: "menubar.dock.rectangle", searchPathDirectory: .desktopDirectory),
        WellKnownFolder(title: "Downloads", symbolName: "arrow.down.circle", searchPathDirectory: .downloadsDirectory),
        WellKnownFolder(title: "Documents", symbolName: "doc", searchPathDirectory: .documentDirectory),
        WellKnownFolder(title: "Pictures", symbolName: "photo", searchPathDirectory: .picturesDirectory),
        WellKnownFolder(title: "Music", symbolName: "music.note", searchPathDirectory: .musicDirectory),
        WellKnownFolder(title: "Videos", symbolName: "film", searchPathDirectory: .moviesDirectory),
    ]

    public static let thisPCID = "this-pc"
    public static let networkID = "network"
    /// Prefix of the IDs of SSH servers' rows.
    public static let serverIDPrefix = "ssh:"
    /// Prefix of the IDs of cloud folders' rows.
    public static let cloudIDPrefix = "cloud:"
    /// Prefix of the IDs of pinned folders' rows.
    public static let pinIDPrefix = "pin:"

    /// Desktop, Downloads, Documents, Pictures, Music and Videos: Quick access's default pins.
    public static func wellKnownFolderURLs() -> [URL] {
        wellKnownFolders.compactMap { url(of: $0) }
    }

    private static func url(of folder: WellKnownFolder) -> URL? {
        FileManager.default.urls(for: folder.searchPathDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    /// Title and symbol for a folder: the well-known folders' and cloud folders' own, or the
    /// folder's name.
    public static func appearance(of folder: URL) -> (title: String, symbolName: String) {
        if let cloud = CloudStorage.root(at: folder) { return (cloud.title, cloud.symbolName) }
        let path = folder.standardizedFileURL.path
        if let known = wellKnownFolders.first(where: { url(of: $0)?.path == path }) {
            return (known.title, known.symbolName)
        }
        if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return (FileManager.default.displayName(atPath: path), "person.crop.square")
        }
        return (FileManager.default.displayName(atPath: path), "folder")
    }

    /// Home, cloud folders (as Windows 11 puts OneDrive under Home), the pinned folders (by
    /// default the six well-known ones), This PC, Network, Recycle Bin — in that order.
    /// Network expands only when `hasServers`.
    public static func roots(
        pinnedFolders: [URL]? = nil,
        cloudRoots: [CloudRoot] = [],
        hasServers: Bool = false
    ) -> [SidebarItem] {
        var items = [SidebarItem(id: "home", title: "Home", symbolName: "house", location: .home)]

        for cloud in cloudRoots {
            items.append(SidebarItem(
                id: cloudIDPrefix + cloud.url.path,
                title: cloud.title,
                symbolName: cloud.symbolName,
                location: .folder(cloud.url)
            ))
        }

        for folder in pinnedFolders ?? wellKnownFolderURLs() {
            let appearance = appearance(of: folder)
            items.append(SidebarItem(
                id: pinIDPrefix + folder.standardizedFileURL.path,
                title: appearance.title,
                symbolName: appearance.symbolName,
                location: .folder(folder.standardizedFileURL)
            ))
        }

        items.append(SidebarItem(
            id: thisPCID,
            title: "This PC",
            symbolName: "desktopcomputer",
            location: .thisPC,
            isExpandable: true
        ))
        items.append(SidebarItem(id: networkID, title: "Network", symbolName: "network", location: .network,
                                 isExpandable: hasServers))
        items.append(SidebarItem(id: "recycle-bin", title: "Recycle Bin", symbolName: "trash", location: .recycleBin))
        return items
    }

    /// A pin dragged from root index `source` to the gap before root index `target`, as
    /// `QuickAccessStore.movePin` arguments; nil if it would stay put. The pins are roots
    /// `firstPin..<firstPin + pinCount` (Home and the cloud folders come first), and `target`
    /// is clamped to their gaps.
    public static func pinMove(
        fromRoot source: Int,
        toRoot target: Int,
        firstPin: Int = 1,
        pinCount: Int
    ) -> (from: Int, to: Int)? {
        guard pinCount > 0, (firstPin..<firstPin + pinCount).contains(source) else { return nil }
        let from = source - firstPin
        var destination = pinGap(nearest: target, firstPin: firstPin, pinCount: pinCount) - firstPin
        if destination > from { destination -= 1 }
        return destination == from ? nil : (from, destination)
    }

    /// The gap among the pins nearest to the gap before root index `target`.
    public static func pinGap(nearest target: Int, firstPin: Int, pinCount: Int) -> Int {
        min(max(target, firstPin), firstPin + pinCount)
    }

    /// Network's children: SSH servers, as `(title, folder to open)`.
    public static func serverItems(_ servers: [(title: String, location: RemotePath)]) -> [SidebarItem] {
        servers.map { server in
            SidebarItem(
                id: serverIDPrefix + server.location.host.key,
                title: server.title,
                symbolName: "server.rack",
                location: .remote(server.location)
            )
        }
    }

    /// Children of an expandable root: This PC's volumes; `[]` for everything else.
    /// - Parameter names: display names by mount point (e.g. with drive letters); the volume
    ///   name otherwise.
    public static func children(of item: SidebarItem, names: [URL: String] = [:]) -> [SidebarItem] {
        guard item.id == thisPCID else { return [] }
        return VolumeLister.mountedVolumes().map { volume in
            let url = volume.url.standardizedFileURL
            let symbol: String
            switch volume.kind {
            case .local: symbol = "internaldrive"
            case .removable: symbol = "externaldrive"
            case .network: symbol = "server.rack"
            }
            return SidebarItem(
                id: "volume-\(volume.url.path)",
                title: names[url] ?? volume.name,
                symbolName: symbol,
                location: .folder(url)
            )
        }
    }
}
