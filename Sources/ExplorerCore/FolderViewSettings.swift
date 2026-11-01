import Foundation

/// How a folder is shown: layout, sort, grouping and Details columns. Remembered per folder.
public struct FolderViewSettings: Sendable, Hashable, Codable {
    public var viewMode: ViewMode
    public var sort: FileItemSort
    public var grouping: FileGrouping?
    /// Visible Details-view columns, in display order. Always starts with Name.
    public var columns: [FileColumn]

    public init(
        viewMode: ViewMode = .details,
        sort: FileItemSort = FileItemSort(),
        grouping: FileGrouping? = nil,
        columns: [FileColumn] = [.name, .dateModified, .type, .size]
    ) {
        self.viewMode = viewMode
        self.sort = sort
        self.grouping = grouping
        self.columns = columns
    }

    public static let folderDefault = FolderViewSettings()

    public static let recycleBinDefault = FolderViewSettings(
        columns: [.name, .originalLocation, .dateDeleted, .size, .type, .dateModified]
    )

    public static let searchDefault = FolderViewSettings(
        columns: [.name, .dateModified, .type, .size, .folder]
    )

    /// Network: computers as tiles.
    public static let networkDefault = FolderViewSettings(viewMode: .tiles, columns: [.name, .type])

    /// This PC: drive tiles with capacity bars, as on Windows.
    public static let drivesDefault = FolderViewSettings(
        viewMode: .tiles,
        columns: [.name, .type, .totalSize, .freeSpace]
    )

    /// Whether the items need `FileProperties` (tags, dimensions, duration) for what's shown.
    public var needsProperties: Bool {
        sort.key.needsProperties || (viewMode == .details && columns.contains(where: \.needsProperties))
    }

    /// Drops columns, sorting and grouping that belong to other kinds of list (e.g. Recycle
    /// Bin–only columns elsewhere), and makes sure Name is shown first.
    public func sanitized(for kind: FileListKind) -> FolderViewSettings {
        func fits(_ onlyIn: FileListKind?) -> Bool { onlyIn == nil || onlyIn == kind }
        var result = self
        if kind == .drives {
            // This PC has fixed groups (drives, network locations) and only drive columns.
            let available = FileColumn.available(in: .drives)
            result.columns.removeAll { !available.contains($0) }
            result.grouping = nil
        }
        result.columns.removeAll { !fits($0.onlyIn) }
        if !result.sort.key.isAvailable(in: kind) { result.sort = FileItemSort() }
        if let grouping = result.grouping, !fits(grouping.key.onlyIn) { result.grouping = nil }
        var seen = Set<FileColumn>()
        result.columns = [.name] + result.columns.filter { $0 != .name && seen.insert($0).inserted }
        return result
    }
}

extension ExplorerLocation {
    /// Key under which this location's view settings are remembered; `nil` for locations
    /// that always use the defaults.
    public var viewSettingsKey: String? {
        switch self {
        case .folder(let url): return "folder:" + url.standardizedFileURL.path
        // "folder:" so "Apply to all folders" and the size limit cover remote folders too.
        case .remote(let remote): return "folder:" + remote.url.absoluteString
        case .recycleBin: return "recycle-bin"
        case .thisPC: return "this-pc"
        case .search: return "search"
        case .network: return "network"
        case .home: return nil
        }
    }

    /// The kind of file list this location shows.
    public var listKind: FileListKind {
        switch self {
        case .recycleBin: return .recycleBin
        case .search: return .searchResults
        case .thisPC: return .drives
        default: return .folder
        }
    }
}

/// Per-folder view memory, like Windows' "Bags": a folder keeps the view it was last given;
/// other folders use the default, which "Apply to all folders" replaces.
///
/// Holds at most `capacity` folders, forgetting the least recently changed.
public final class FolderViewSettingsStore {
    private struct Entry: Codable {
        var settings: FolderViewSettings
        var lastChanged: Date
    }

    private struct Storage: Codable {
        var folderDefault: FolderViewSettings?
        var entries: [String: Entry] = [:]
    }

    private static let storageKey = "FolderViewSettings.v1"
    private static let folderPrefix = "folder:"

    public let capacity: Int
    private let defaults: UserDefaults
    private var storage: Storage

    public init(defaults: UserDefaults = .standard, capacity: Int = 2000) {
        self.defaults = defaults
        self.capacity = capacity
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    /// What regular folders show until they're given their own view.
    public var folderDefault: FolderViewSettings {
        storage.folderDefault ?? .folderDefault
    }

    /// A folder's own view, or the default for its kind; cloud folders (OneDrive etc.) show
    /// Status after Name by default, as on Windows.
    public func settings(for location: ExplorerLocation) -> FolderViewSettings {
        let kind = location.listKind
        if let key = location.viewSettingsKey, let entry = storage.entries[key] {
            return entry.settings.sanitized(for: kind)
        }
        if location == .network { return .networkDefault }
        switch kind {
        case .recycleBin: return .recycleBinDefault
        case .searchResults: return .searchDefault
        case .drives: return .drivesDefault
        case .folder:
            var settings = folderDefault
            if let url = location.fileURL, CloudStorage.isInCloudFolder(url), !settings.columns.contains(.status) {
                settings.columns.insert(.status, at: min(1, settings.columns.count))
            }
            return settings
        }
    }

    public func save(_ settings: FolderViewSettings, for location: ExplorerLocation, now: Date = Date()) {
        guard let key = location.viewSettingsKey else { return }
        storage.entries[key] = Entry(settings: settings, lastChanged: now)
        if storage.entries.count > capacity {
            let oldest = storage.entries.sorted { $0.value.lastChanged < $1.value.lastChanged }
            for (key, _) in oldest.prefix(storage.entries.count - capacity) {
                storage.entries[key] = nil
            }
        }
        persist()
    }

    /// Makes `settings` the view of every regular folder: the new default, replacing any
    /// folder's own view. The Recycle Bin, This PC and search results keep theirs.
    public func applyToAllFolders(_ settings: FolderViewSettings) {
        storage.folderDefault = settings.sanitized(for: .folder)
        storage.entries = storage.entries.filter { !$0.key.hasPrefix(Self.folderPrefix) }
        persist()
    }

    /// Forgets every folder's view and the custom default ("Reset folders").
    public func resetAllFolders() {
        storage = Storage()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
