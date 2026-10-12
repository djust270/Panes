import Foundation

/// Remembers where items this app moved to the Trash came from, so the Recycle Bin can
/// restore them. (Finder keeps its own record in the Trash's `.DS_Store`; see `DSStore`.)
///
/// Stored as JSON, `[trashed path: original path]`. Entries whose trashed item no longer
/// exists are dropped when the log is loaded.
public final class TrashLog: @unchecked Sendable {
    public static let shared = TrashLog(fileURL: TrashLog.defaultFileURL)

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let folder = Bundle.main.bundleIdentifier ?? "Explorer"
        return support.appendingPathComponent(folder).appendingPathComponent("TrashLog.json")
    }

    public func record(original: URL, trashed: URL) {
        lock.withLock {
            var entries = loadedEntries()
            entries[trashed.standardizedFileURL.path] = original.standardizedFileURL.path
            save(entries)
        }
    }

    public func originalURL(forTrashed trashed: URL) -> URL? {
        lock.withLock {
            loadedEntries()[trashed.standardizedFileURL.path].map { URL(fileURLWithPath: $0) }
        }
    }

    /// Must hold `lock`.
    private func loadedEntries() -> [String: String] {
        if let entries { return entries }
        var loaded: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            loaded = decoded.filter { FileManager.default.fileExists(atPath: $0.key) }
        }
        entries = loaded
        return loaded
    }

    /// Must hold `lock`.
    private func save(_ newEntries: [String: String]) {
        entries = newEntries
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(newEntries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
