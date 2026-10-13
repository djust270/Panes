import Foundation

/// What Home and the navigation pane show besides the fixed locations: pinned folders
/// (Quick access), favorite files, folders visited often, and files opened from the app.
///
/// As on Windows, Quick access starts with Desktop, Downloads, Documents, Pictures, Music and
/// Videos pinned; unpinning one of them sticks. Frequent folders are ranked by visit count
/// weighted by how recent the last visit was; "Remove from Quick access" hides a frequent
/// folder for good, and "Remove from Recent" hides a file until it's opened again.
public final class QuickAccessStore {
    private struct Visit: Codable {
        var count: Int
        var last: Date
    }

    private struct Storage: Codable {
        /// `nil` until the user changes the pins: the default pins.
        var pinnedFolders: [String]?
        var favorites: [String] = []
        var visits: [String: Visit] = [:]
        var hiddenFrequent: Set<String> = []
        /// Files opened from the app, by path, with when.
        var opened: [String: Date] = [:]
        /// Files removed from Recent, with when; they come back if used after that.
        var hiddenRecent: [String: Date] = [:]
    }

    private static let storageKey = "QuickAccess.v1"
    /// Folders and files remembered at most; the least recent are forgotten.
    static let visitCapacity = 500
    static let openedCapacity = 200

    private let defaults: UserDefaults
    private let defaultPins: [URL]
    private var storage: Storage

    /// - Parameter defaultPins: Quick access before the user changes it; the six well-known
    ///   folders unless given.
    public init(defaults: UserDefaults = .standard, defaultPins: [URL]? = nil) {
        self.defaults = defaults
        self.defaultPins = (defaultPins ?? SidebarTree.wellKnownFolderURLs()).map { Self.url(Self.path($0)) }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    // MARK: Pinned folders

    /// Quick access pins, in order.
    public var pinnedFolders: [URL] {
        storage.pinnedFolders.map { $0.map(Self.url) } ?? defaultPins
    }

    public func isPinned(_ folder: URL) -> Bool {
        pinnedFolders.contains { $0.path == Self.path(folder) }
    }

    /// Pins `folder` at the end of Quick access (no-op if already pinned).
    public func pin(_ folder: URL) {
        guard !isPinned(folder) else { return }
        setPins(pinnedFolders + [Self.url(Self.path(folder))])
    }

    public func unpin(_ folder: URL) {
        setPins(pinnedFolders.filter { $0.path != Self.path(folder) })
    }

    /// Moves the pin at `source` to `destination` (an index in the list without it).
    public func movePin(from source: Int, to destination: Int) {
        var pins = pinnedFolders
        guard pins.indices.contains(source) else { return }
        let pin = pins.remove(at: source)
        pins.insert(pin, at: min(max(destination, 0), pins.count))
        setPins(pins)
    }

    private func setPins(_ pins: [URL]) {
        storage.pinnedFolders = pins.map(Self.path)
        persist()
    }

    // MARK: Favorites

    public var favorites: [URL] {
        storage.favorites.map(Self.url)
    }

    public func isFavorite(_ file: URL) -> Bool {
        storage.favorites.contains(Self.path(file))
    }

    public func addFavorite(_ file: URL) {
        guard !isFavorite(file) else { return }
        storage.favorites.append(Self.path(file))
        persist()
    }

    public func removeFavorite(_ file: URL) {
        storage.favorites.removeAll { $0 == Self.path(file) }
        persist()
    }

    // MARK: Frequent folders

    /// Counts a visit to `folder`; a folder hidden with "Remove from Quick access" stays hidden.
    public func recordVisit(to folder: URL, at date: Date = Date()) {
        let path = Self.path(folder)
        var visit = storage.visits[path] ?? Visit(count: 0, last: date)
        visit.count += 1
        visit.last = max(visit.last, date)
        storage.visits[path] = visit
        trim(&storage.visits, to: Self.visitCapacity) { $0.last }
        persist()
    }

    /// Folders visited at least twice, most frequent first, excluding pinned and hidden ones.
    public func frequentFolders(limit: Int = 10, now: Date = Date()) -> [URL] {
        let pinned = Set(pinnedFolders.map(\.path))
        let candidates = storage.visits.filter { path, visit in
            visit.count >= 2 && !pinned.contains(path) && !storage.hiddenFrequent.contains(path)
        }
        let ranked = candidates.sorted { lhs, rhs in
            let lhsScore = Self.score(lhs.value, now: now)
            let rhsScore = Self.score(rhs.value, now: now)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.value.last > rhs.value.last
        }
        return ranked.prefix(limit).map { Self.url($0.key) }
    }

    /// Hides `folder` from the frequent folders.
    public func removeFromFrequent(_ folder: URL) {
        storage.hiddenFrequent.insert(Self.path(folder))
        persist()
    }

    public func isFrequent(_ folder: URL) -> Bool {
        frequentFolders().contains { $0.path == Self.path(folder) }
    }

    /// Visits count for less the longer ago the last one was.
    private static func score(_ visit: Visit, now: Date) -> Double {
        let days = now.timeIntervalSince(visit.last) / 86400
        let weight: Double
        switch days {
        case ..<4: weight = 1
        case ..<14: weight = 0.7
        case ..<31: weight = 0.5
        case ..<90: weight = 0.3
        default: weight = 0.1
        }
        return Double(visit.count) * weight
    }

    // MARK: Recent files

    /// Remembers that `file` was opened from the app.
    public func recordOpen(of file: URL, at date: Date = Date()) {
        let path = Self.path(file)
        storage.opened[path] = date
        storage.hiddenRecent[path] = nil
        trim(&storage.opened, to: Self.openedCapacity) { $0 }
        persist()
    }

    /// Files opened from the app, most recent first.
    public var openedFiles: [RecentFile] {
        storage.opened.map { RecentFile(url: Self.url($0.key), lastUsed: $0.value) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Hides `file` from Recent until it is used again.
    public func removeFromRecent(_ file: URL, at date: Date = Date()) {
        let path = Self.path(file)
        storage.hiddenRecent[path] = date
        storage.opened[path] = nil
        persist()
    }

    /// Home's Recent list: `found` (e.g. from Spotlight) merged with files opened from the app,
    /// newest use per file, without hidden files or favorites, newest first.
    public func recentFiles(merging found: [RecentFile], limit: Int = 20) -> [RecentFile] {
        var latest: [String: Date] = [:]
        for file in found + openedFiles {
            let path = Self.path(file.url)
            latest[path] = max(latest[path] ?? .distantPast, file.lastUsed)
        }
        let favorites = Set(storage.favorites)
        let shown = latest.filter { path, used in
            if favorites.contains(path) { return false }
            if let hidden = storage.hiddenRecent[path], used <= hidden { return false }
            return true
        }
        return shown.map { RecentFile(url: Self.url($0.key), lastUsed: $0.value) }
            .sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed > $1.lastUsed : $0.url.path < $1.url.path }
            .prefix(limit)
            .map { $0 }
    }

    public func isRecentlyOpened(_ file: URL) -> Bool {
        storage.opened[Self.path(file)] != nil
    }

    // MARK: Storage

    /// Entries are keyed by standardized path: URLs for the same folder can differ by a
    /// trailing slash and so compare unequal.
    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    private func trim<Value>(_ entries: inout [String: Value], to capacity: Int, by date: (Value) -> Date) {
        guard entries.count > capacity else { return }
        let oldest = entries.sorted { date($0.value) < date($1.value) }
        for (key, _) in oldest.prefix(entries.count - capacity) {
            entries[key] = nil
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// A file and when it was last used.
public struct RecentFile: Sendable, Hashable {
    public let url: URL
    public let lastUsed: Date

    public init(url: URL, lastUsed: Date) {
        self.url = url
        self.lastUsed = lastUsed
    }
}
