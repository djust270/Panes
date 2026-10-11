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
}

/// The navigation pane's two-level tree: root items (Home, well-known folders, This PC,
/// Network), and — only under This PC — mounted volumes.
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

    /// Home, Desktop/Downloads/Documents/Pictures/Music/Videos, This PC, Network — in that order.
    public static func roots() -> [SidebarItem] {
        var items = [SidebarItem(id: "home", title: "Home", symbolName: "house", location: .home)]

        for folder in wellKnownFolders {
            guard let url = FileManager.default.urls(for: folder.searchPathDirectory, in: .userDomainMask).first else {
                continue
            }
            items.append(SidebarItem(
                id: "folder-\(folder.searchPathDirectory.rawValue)",
                title: folder.title,
                symbolName: folder.symbolName,
                location: .folder(url.standardizedFileURL)
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
        return items
    }

    /// Children of an expandable root. `[]` for every leaf item, and for Network (Bonjour/SMB
    /// discovery is Phase 6) — this is also where Phase 5's Favorites will plug in.
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
