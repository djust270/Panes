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

    /// Whether the items need `FileProperties` (tags, dimensions, duration) for what's shown.
    public var needsProperties: Bool {
        sort.key.needsProperties || (viewMode == .details && columns.contains(where: \.needsProperties))
    }

    /// Drops Recycle Bin–only columns, sorting and grouping outside the Recycle Bin, and makes
    /// sure Name is shown first.
    public func sanitized(inRecycleBin: Bool) -> FolderViewSettings {
        var result = self
        if !inRecycleBin {
            result.columns.removeAll(where: \.isRecycleBinOnly)
            if result.sort.key.isRecycleBinOnly { result.sort = FileItemSort() }
            if result.grouping?.key.isRecycleBinOnly == true { result.grouping = nil }
        }
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
        case .recycleBin: return "recycle-bin"
        case .thisPC: return "this-pc"
        case .home, .network, .search: return nil
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

    public func settings(for location: ExplorerLocation) -> FolderViewSettings {
        let inRecycleBin = location == .recycleBin
        if let key = location.viewSettingsKey, let entry = storage.entries[key] {
            return entry.settings.sanitized(inRecycleBin: inRecycleBin)
        }
        return inRecycleBin ? .recycleBinDefault : folderDefault
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
    /// folder's own view. The Recycle Bin and This PC keep theirs.
    public func applyToAllFolders(_ settings: FolderViewSettings) {
        storage.folderDefault = settings.sanitized(inRecycleBin: false)
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
