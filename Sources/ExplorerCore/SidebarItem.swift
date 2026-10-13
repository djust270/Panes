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

/// The navigation pane's two-level tree: root items (Home, the Quick access pins, This PC,
/// Network, Recycle Bin), and — only under This PC — mounted volumes.
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
    /// Prefix of the IDs of pinned folders' rows.
    public static let pinIDPrefix = "pin:"

    /// Desktop, Downloads, Documents, Pictures, Music and Videos: Quick access's default pins.
    public static func wellKnownFolderURLs() -> [URL] {
        wellKnownFolders.compactMap { url(of: $0) }
    }

    private static func url(of folder: WellKnownFolder) -> URL? {
        FileManager.default.urls(for: folder.searchPathDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    /// Title and symbol for a folder: the well-known folders' own, or the folder's name.
    public static func appearance(of folder: URL) -> (title: String, symbolName: String) {
        let path = folder.standardizedFileURL.path
        if let known = wellKnownFolders.first(where: { url(of: $0)?.path == path }) {
            return (known.title, known.symbolName)
        }
        if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return (FileManager.default.displayName(atPath: path), "person.crop.square")
        }
        return (FileManager.default.displayName(atPath: path), "folder")
    }

    /// Home, the pinned folders (by default the six well-known ones), This PC, Network,
    /// Recycle Bin — in that order.
    public static func roots(pinnedFolders: [URL]? = nil) -> [SidebarItem] {
        var items = [SidebarItem(id: "home", title: "Home", symbolName: "house", location: .home)]

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
        items.append(SidebarItem(id: "network", title: "Network", symbolName: "network", location: .network))
        items.append(SidebarItem(id: "recycle-bin", title: "Recycle Bin", symbolName: "trash", location: .recycleBin))
        return items
    }

    /// Children of an expandable root. `[]` for every leaf item, and for Network (Bonjour/SMB
    /// discovery is Phase 6).
    public static func children(of item: SidebarItem) -> [SidebarItem] {
        guard item.id == thisPCID else { return [] }
        return VolumeLister.mountedVolumes().map { volume in
            SidebarItem(
                id: "volume-\(volume.url.path)",
                title: volume.name,
                symbolName: volume.isInternal ? "internaldrive" : "externaldrive",
                location: .folder(volume.url.standardizedFileURL)
            )
        }
    }
}
