import CoreServices
import Foundation

/// Watches a directory for changes using FSEvents and reports them as an `AsyncStream`.
///
/// Events are coalesced by FSEvents (see `latency`), so consumers should treat each
/// event as "something under this path changed — reload" rather than a precise diff.
public final class DirectoryWatcher: @unchecked Sendable {
    public struct Change: Sendable, Hashable {
        /// Paths that changed. With `watchesSubtree == false` these are filtered to
        /// the watched directory and its direct children.
        public let paths: [String]
        /// True if FSEvents dropped events and a full rescan is required.
        public let mustRescan: Bool
    }

    public let directory: URL
    public let latency: TimeInterval
    public let watchesSubtree: Bool

    /// `directory` with symlinks resolved, matching the paths FSEvents reports.
    private let resolvedPath: String
    private let queue = DispatchQueue(label: "DirectoryWatcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Change>.Continuation?

    public init(directory: URL, latency: TimeInterval = 0.2, watchesSubtree: Bool = false) {
        self.directory = directory.standardizedFileURL
        // Not `resolvingSymlinksInPath()`: it strips `/private`, which FSEvents keeps.
        self.resolvedPath = realpath(self.directory.path, nil).map { ptr in
            defer { free(ptr) }
            return String(cString: ptr)
        } ?? self.directory.path
        self.latency = latency
        self.watchesSubtree = watchesSubtree
    }

    deinit {
        stop()
    }

    /// Starts watching and returns a stream of changes. Calling `start()` again
    /// finishes the previous stream and starts a new one.
    public func start() -> AsyncStream<Change> {
        stop()

        let (changes, continuation) = AsyncStream<Change>.makeStream(bufferingPolicy: .bufferingNewest(64))

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.callback,
            &context,
            [resolvedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            continuation.finish()
            return changes
        }

        lock.withLock {
            self.stream = stream
            self.continuation = continuation
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }
        return changes
    }

    public func stop() {
        let (stream, continuation) = lock.withLock {
            let pair = (self.stream, self.continuation)
            self.stream = nil
            self.continuation = nil
            return pair
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation?.finish()
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let rescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        let mustRescan = flags.contains { $0 & rescanMask != 0 }

        let relevant: [String]
        if watchesSubtree {
            relevant = paths
        } else {
            let root = resolvedPath
            relevant = paths.filter { path in
                path == root || (path as NSString).deletingLastPathComponent == root
            }
        }

        guard mustRescan || !relevant.isEmpty else { return }
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(Change(paths: relevant, mustRescan: mustRescan))
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
        watcher.handle(paths: paths, flags: flags)
    }
}
