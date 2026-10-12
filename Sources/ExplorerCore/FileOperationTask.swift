import Darwin
import Foundation

/// Runs one `FileOperationRequest` synchronously on the calling (background) thread.
///
/// `pause()`, `resume()` and `cancel()` may be called from any thread. Conflicts and errors
/// are handed to `FileOperationHandlers`, and the task blocks until they reply.
public final class FileOperationTask: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let request: FileOperationRequest
    let environment: FileOperationEnvironment

    /// Guards `paused`, `cancelled` and pending replies.
    private let state = NSCondition()
    private var paused = false
    private var cancelled = false
    private var hasRun = false

    // Worker-thread state, touched only inside `run`.
    var handlers = FileOperationHandlers()
    var progress = FileOperationProgress()
    var result = FileOperationResult()
    var conflictPolicy: ConflictResolution?
    var remainingConflicts = 0
    /// Items a transfer created at the top of the destination (or inside merged folders),
    /// source first; the basis of its undo.
    var transferRoots: [Relocation] = []
    private var skipsAllFailures = false
    private var lastReport: UInt64 = 0
    private static let reportInterval: UInt64 = 50_000_000

    public init(request: FileOperationRequest, environment: FileOperationEnvironment = .live) {
        self.request = request
        self.environment = environment
    }

    public var isPaused: Bool { state.withLock { paused } }
    public var isCancelled: Bool { state.withLock { cancelled } }

    public func pause() {
        state.withLock { paused = true }
    }

    public func resume() {
        state.withLock {
            paused = false
            state.broadcast()
        }
    }

    public func cancel() {
        state.withLock {
            cancelled = true
            state.broadcast()
        }
    }

    /// Performs the request. Call once, off the main thread.
    public func run(handlers: FileOperationHandlers = FileOperationHandlers()) -> FileOperationResult {
        precondition(!state.withLock { hasRun }, "A FileOperationTask can only run once")
        state.withLock { hasRun = true }
        self.handlers = handlers
        report(force: true)

        do {
            switch request {
            case .copy(let sources, let folder):
                try runTransfer(transfers(of: sources, into: folder, copying: true), mode: .copy)
            case .move(let sources, let folder):
                try runTransfer(transfers(of: sources, into: folder, copying: false), mode: .move)
            case .relocate(let relocations):
                try runTransfer(relocations, mode: .move)
            case .trash(let urls):
                try runTrash(urls)
            case .delete(let urls):
                try runDelete(urls)
            case .rename(let url, let name):
                runRename(url, to: name)
            case .createFolder(let folder, let name):
                runCreate(in: folder, name: name, directory: true)
            case .createFile(let folder, let name):
                runCreate(in: folder, name: name, directory: false)
            }
        } catch {
            result.wasCancelled = true
        }

        progress.phase = .finished
        progress.currentName = nil
        report(force: true)
        return result
    }

    // MARK: Control

    /// Blocks while paused. Throws `CancellationError` once cancelled.
    func checkpoint() throws {
        state.lock()
        defer { state.unlock() }
        while paused && !cancelled {
            state.wait()
        }
        if cancelled { throw CancellationError() }
    }

    /// Sends a question to a handler and waits for the reply. Returns `nil` if the task is
    /// cancelled first.
    func ask<Answer: Sendable>(_ send: (@escaping @Sendable (Answer) -> Void) -> Void) -> Answer? {
        let box = ReplyBox<Answer>()
        send { [state] answer in
            state.withLock {
                box.answer = answer
                state.broadcast()
            }
        }
        state.lock()
        defer { state.unlock() }
        while box.answer == nil && !cancelled {
            state.wait()
        }
        return cancelled ? nil : box.answer
    }

    /// Runs `body`, offering Retry/Skip/Cancel if it throws. Returns false if the user skipped.
    func attempt(_ url: URL, _ body: () throws -> Void) throws -> Bool {
        while true {
            do {
                try body()
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if try shouldRetry(after: FileOperationFailure(url: url, error: error)) { continue }
                return false
            }
        }
    }

    /// Reports `failure`; returns true to retry, false to skip, or throws to cancel.
    func shouldRetry(after failure: FileOperationFailure) throws -> Bool {
        if !skipsAllFailures {
            guard let resolution: FailureResolution = ask({ handlers.failure(failure, $0) }) else {
                throw CancellationError()
            }
            switch resolution {
            case .retry: return true
            case .skip: break
            case .skipAll: skipsAllFailures = true
            case .cancel: throw CancellationError()
            }
        }
        result.failures.append(failure)
        return false
    }

    func report(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now - lastReport >= Self.reportInterval else { return }
        lastReport = now
        handlers.progress(progress)
    }

    // MARK: Trash and delete

    private func runTrash(_ urls: [URL]) throws {
        progress.totalItems = urls.count
        progress.phase = .running
        var trashed: [Relocation] = []
        defer {
            if !trashed.isEmpty {
                result.inverse = .relocate(trashed.map(\.reversed))
            }
        }
        for url in urls {
            try checkpoint()
            progress.currentName = url.lastPathComponent
            report()
            var destination: URL?
            if try attempt(url, { destination = try environment.trash(url) }), let destination {
                trashed.append(Relocation(source: url, destination: destination))
            }
            progress.completedItems += 1
        }
    }

    private func runDelete(_ urls: [URL]) throws {
        progress.totalItems = try urls.reduce(0) { $0 + (try countItems(at: $1)) }
        progress.phase = .running
        for url in urls {
            try deleteRecursively(url)
        }
    }

    private func countItems(at url: URL) throws -> Int {
        try checkpoint()
        guard FileStatus(path: url.path)?.type == .directory else { return 1 }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return try children.reduce(1) { $0 + (try countItems(at: url.appendingPathComponent($1))) }
    }

    private func deleteRecursively(_ url: URL) throws {
        try checkpoint()
        progress.currentName = url.lastPathComponent
        report()
        if FileStatus(path: url.path)?.type == .directory {
            var children: [String] = []
            guard try attempt(url, { children = try FileManager.default.contentsOfDirectory(atPath: url.path) }) else {
                return
            }
            for child in children {
                try deleteRecursively(url.appendingPathComponent(child))
            }
            _ = try attempt(url) { try POSIXCall.check(rmdir(url.path), url) }
        } else {
            _ = try attempt(url) { try POSIXCall.check(unlink(url.path), url) }
        }
        progress.completedItems += 1
    }

    // MARK: Rename and create

    private func runRename(_ url: URL, to name: String) {
        progress.totalItems = 1
        if let message = FileNaming.validationError(for: name) {
            result.failures.append(FileOperationFailure(url: url, reason: .invalidName, message: message))
            return
        }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
        guard destination.lastPathComponent != url.lastPathComponent else { return }

        var status = renamex_np(url.path, destination.path, UInt32(RENAME_EXCL))
        if status != 0, errno == EEXIST, isSameItem(url, destination) {
            // A case-only rename on a case-insensitive volume: the "existing" item is this one.
            status = renamex_np(url.path, destination.path, 0)
        }
        guard status == 0 else {
            let code = errno
            let failure = code == EEXIST
                ? FileOperationFailure(
                    url: url,
                    reason: .alreadyExists,
                    message: "There is already a file with the same name in this location."
                )
                : FileOperationFailure(url: url, error: POSIXCall.error(code, url))
            result.failures.append(failure)
            return
        }
        progress.completedItems = 1
        result.resultingItems = [destination]
        result.inverse = .rename(destination, to: url.lastPathComponent)
    }

    private func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        var left = stat(), right = stat()
        guard lstat(lhs.path, &left) == 0, lstat(rhs.path, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private func runCreate(in folder: URL, name: String, directory: Bool) {
        progress.totalItems = 1
        if let message = FileNaming.validationError(for: name) {
            result.failures.append(FileOperationFailure(url: folder, reason: .invalidName, message: message))
            return
        }
        let isTaken = FileNaming.existsChecker(in: folder)
        // Retry a few times in case another process takes the name between check and create.
        for _ in 0..<5 {
            let unique = FileNaming.uniqueName(name, hasExtension: !directory, isTaken: isTaken)
            let url = folder.appendingPathComponent(unique, isDirectory: directory)
            let status: Int32
            if directory {
                status = mkdir(url.path, 0o755)
            } else {
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
                status = fd >= 0 ? close(fd) : -1
            }
            if status == 0 {
                progress.completedItems = 1
                result.resultingItems = [url]
                result.inverse = .trash([url])
                return
            }
            guard errno == EEXIST else {
                result.failures.append(FileOperationFailure(url: url, error: POSIXCall.error(errno, url)))
                return
            }
        }
        result.failures.append(
            FileOperationFailure(url: folder, reason: .alreadyExists, message: "Couldn't find a free name.")
        )
    }
}

/// Holds a handler's reply; read and written under the task's `state` lock.
private final class ReplyBox<Answer>: @unchecked Sendable {
    var answer: Answer?
}
