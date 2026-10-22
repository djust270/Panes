import Foundation

/// A running search's results so far.
public struct SearchProgress: Sendable {
    public let items: [FileItem]
    /// The first pass is over. (Spotlight results can still change afterwards.)
    public let isComplete: Bool
    /// More items matched than `FileSearch.resultLimit`; only that many are listed.
    public let isTruncated: Bool
}

/// Searches a folder and everything under it: with Spotlight on volumes it indexes, otherwise
/// by walking the folders and matching names (Windows likewise only matches contents in
/// indexed locations).
public enum FileSearch {
    public static let resultLimit = 10_000

    /// Spotlight indexes local internal volumes by default; external, disk image and network
    /// volumes often aren't indexed, so those are walked.
    public static func usesSpotlight(for scope: URL) -> Bool {
        let values = try? scope.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        return values?.volumeIsLocal == true && values?.volumeIsInternal == true
    }

    /// Like Windows' indexer, Spotlight results leave out app data (~/Library) and, unless
    /// hidden items are shown, anything in a hidden folder — except when searching inside them.
    static func isSearchable(_ path: String, in scope: String, includeHidden: Bool) -> Bool {
        guard path.hasPrefix(scope) else { return false }
        let library = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/Library/"
        if path.hasPrefix(library), !(scope + "/").hasPrefix(library) { return false }
        if !includeHidden {
            let relative = path.dropFirst(scope.count).split(separator: "/").dropLast()
            if relative.contains(where: { $0.hasPrefix(".") }) { return false }
        }
        return true
    }

    /// Snapshots of the results as they arrive. Cancel the consuming task to stop searching.
    @MainActor
    public static func start(
        _ query: SearchQuery,
        in scope: URL,
        includeHidden: Bool
    ) -> AsyncStream<SearchProgress> {
        if usesSpotlight(for: scope),
           let predicate = NSPredicate(fromMetadataQueryString: query.spotlightQuery()) {
            let scopePath = scope.standardizedFileURL.path
            return SpotlightSearch.start(predicate: predicate, scope: scope) { item in
                isSearchable(item.url.path, in: scopePath, includeHidden: includeHidden)
                    && (includeHidden || !item.isHidden)
                    && query.matchesNamePatterns(item.name)
                    && query.matchesFilters(item)
            }
        }
        return DirectorySearch.start(query, in: scope, includeHidden: includeHidden)
    }
}

// MARK: - Walking

/// Name search by walking folders breadth-first, so shallow matches come first. Doesn't enter
/// packages or follow symbolic links.
public enum DirectorySearch {
    public static func start(
        _ query: SearchQuery,
        in scope: URL,
        includeHidden: Bool,
        limit: Int = FileSearch.resultLimit
    ) -> AsyncStream<SearchProgress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let options = DirectoryLoader.Options(includeHidden: includeHidden)
                let now = Date()
                var pending = [scope.standardizedFileURL]
                var found: [FileItem] = []
                var truncated = false
                var lastYield = Date()
                var yieldedCount = 0

                while !pending.isEmpty, !Task.isCancelled, !truncated {
                    let folder = pending.removeFirst()
                    guard let items = try? DirectoryLoader.loadSync(folder, options: options) else { continue }
                    for item in items {
                        if query.matches(item, now: now) {
                            if found.count == limit {
                                truncated = true
                                break
                            }
                            found.append(item)
                        }
                        if item.kind == .directory { pending.append(item.url) }
                    }
                    if found.count != yieldedCount, Date().timeIntervalSince(lastYield) > 0.25 {
                        continuation.yield(SearchProgress(items: found, isComplete: false, isTruncated: false))
                        yieldedCount = found.count
                        lastYield = Date()
                    }
                }
                if !Task.isCancelled {
                    continuation.yield(SearchProgress(items: found, isComplete: true, isTruncated: truncated))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Spotlight

/// An `NSMetadataQuery` whose results are turned into `FileItem`s off the main thread. Keeps
/// running after the initial gathering, so results follow changes on disk.
@MainActor
final class SpotlightSearch {
    private let query = NSMetadataQuery()
    private let filter: @Sendable (FileItem) -> Bool
    private let continuation: AsyncStream<SearchProgress>.Continuation
    private var observers: [NSObjectProtocol] = []
    private var isGathering = true
    /// Items already read from disk, by path.
    private var cache: [String: FileItem] = [:]
    private var conversion: Task<Void, Never>?
    private var needsConversion = false

    static func start(
        predicate: NSPredicate,
        scope: URL,
        filter: @escaping @Sendable (FileItem) -> Bool
    ) -> AsyncStream<SearchProgress> {
        let (stream, continuation) = AsyncStream<SearchProgress>.makeStream()
        let search = SpotlightSearch(filter: filter, continuation: continuation)
        // The stream keeps the search alive until its consumer goes away.
        continuation.onTermination = { _ in
            Task { @MainActor in search.stop() }
        }
        search.start(predicate: predicate, scope: scope)
        return stream
    }

    private init(
        filter: @escaping @Sendable (FileItem) -> Bool,
        continuation: AsyncStream<SearchProgress>.Continuation
    ) {
        self.filter = filter
        self.continuation = continuation
    }

    private func start(predicate: NSPredicate, scope: URL) {
        query.predicate = predicate
        query.searchScopes = scope.path == "/" ? [NSMetadataQueryLocalComputerScope] : [scope]
        query.notificationBatchingInterval = 0.3

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                let changed = (note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem])?
                    .compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String } ?? []
                MainActor.assumeIsolated {
                    self?.resultsChanged(finished: name == .NSMetadataQueryDidFinishGathering, changed: changed)
                }
            })
        }
        if !query.start() {
            continuation.yield(SearchProgress(items: [], isComplete: true, isTruncated: false))
        }
    }

    private func stop() {
        query.stop()
        conversion?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func resultsChanged(finished: Bool, changed: [String]) {
        if finished { isGathering = false }
        for path in changed { cache[path] = nil }
        convert()
    }

    /// Reads the current results; if a read is under way, runs again when it's done.
    private func convert() {
        guard conversion == nil else {
            needsConversion = true
            return
        }
        query.disableUpdates()
        let count = query.resultCount
        var paths: [String] = []
        paths.reserveCapacity(min(count, FileSearch.resultLimit))
        for index in 0..<count where paths.count < FileSearch.resultLimit {
            if let result = query.result(at: index) as? NSMetadataItem,
               let path = result.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(path)
            }
        }
        query.enableUpdates()

        let known = cache
        let filter = filter
        let complete = !isGathering
        let truncated = count > FileSearch.resultLimit
        conversion = Task { [weak self, paths] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(String, FileItem)] in
                paths.compactMap { path in
                    if let item = known[path] { return (path, item) }
                    return FileItem.load(URL(fileURLWithPath: path)).map { (path, $0) }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            cache = Dictionary(loaded, uniquingKeysWith: { first, _ in first })
            continuation.yield(SearchProgress(
                items: loaded.map(\.1).filter(filter),
                isComplete: complete,
                isTruncated: truncated
            ))
            conversion = nil
            if needsConversion {
                needsConversion = false
                convert()
            }
        }
    }
}

// MARK: - Recently used files

/// Files the user opened recently, anywhere (Spotlight's "last used" date, which Launch
/// Services sets when a file is opened), for Home's Recent list.
public enum SpotlightRecents {
    /// The most recently used files in the home folder over the past `days`, newest first.
    /// Folders, apps, hidden files and anything in ~/Library are left out.
    @MainActor
    public static func fetch(limit: Int = 40, days: Int = 30) async -> [RecentFile] {
        await RecentsQuery(limit: limit, days: days).run()
    }

    /// Whether a used file belongs in Recent.
    static func isUserFile(_ path: String, home: String) -> Bool {
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) { return false }
        if path.hasPrefix(home + "/Library/") { return false }
        // Inside a package (e.g. an app's resources).
        let parents = components.dropLast()
        let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary"]
        return !parents.contains { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }
}

@MainActor
private final class RecentsQuery {
    private let query = NSMetadataQuery()
    private let limit: Int
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[RecentFile], Never>?

    init(limit: Int, days: Int) {
        self.limit = limit
        query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemLastUsedDate >= $time.today(-\(days))")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
    }

    func run() async -> [RecentFile] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            guard query.start() else {
                finish()
                return
            }
            // Spotlight can be slow or switched off; don't hold Home up for it.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        query.stop()
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var files: [RecentFile] = []
        for index in 0..<query.resultCount where files.count < limit {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                  SpotlightRecents.isUserFile(path, home: home) else { continue }
            let types = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            if types.contains("public.folder") || types.contains("com.apple.application") { continue }
            files.append(RecentFile(url: URL(fileURLWithPath: path), lastUsed: used))
        }
        continuation.resume(returning: files)
    }
}
