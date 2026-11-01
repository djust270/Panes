import Darwin
import Foundation

/// A remote source item and, for folders, its contents.
struct RemoteNode {
    let path: RemotePath
    /// What the item is, following symbolic links.
    let attributes: SFTPAttributes
    var children: [RemoteNode] = []
    var totalBytes: Int64
    var totalItems = 1

    var isDirectory: Bool { attributes.fileType == .directory }
    var name: String { path.name }

    var conflictItem: FileConflict.Item {
        FileConflict.Item(
            url: path.url,
            isDirectory: isDirectory,
            size: isDirectory ? nil : totalBytes,
            dateModified: attributes.dateModified
        )
    }
}

/// A local source item for an upload, following symbolic links.
struct LocalNode {
    let url: URL
    let isDirectory: Bool
    let permissions: UInt32
    let dateModified: Date
    var children: [LocalNode] = []
    var totalBytes: Int64
    var totalItems = 1

    var name: String { url.lastPathComponent }

    var conflictItem: FileConflict.Item {
        FileConflict.Item(
            url: url,
            isDirectory: isDirectory,
            size: isDirectory ? nil : totalBytes,
            dateModified: dateModified
        )
    }
}

/// The SFTP channel a transfer uses, opened again if the connection drops (for Retry).
final class RemoteChannel {
    let host: RemoteHost
    private let open: (RemoteHost) throws -> SFTPClient
    private var current: SFTPClient?

    init(host: RemoteHost, open: @escaping (RemoteHost) throws -> SFTPClient) {
        self.host = host
        self.open = open
    }

    func client() throws -> SFTPClient {
        if let current, current.isOpen { return current }
        current?.close()
        do {
            let client = try open(host)
            current = client
            return client
        } catch let error as SSHError {
            throw RemoteTransferError(message: error.message(for: host))
        }
    }

    func close() {
        current?.close()
    }
}

struct RemoteTransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Downloads from and uploads to SSH servers, with the same conflicts, progress, pause and
/// cancel as local copies. Files arrive under a temporary name and are renamed into place,
/// so a cancelled or failed transfer never leaves a partial file under the real name.
extension FileOperationTask {
    /// Folders nested deeper than this (usually a link loop) aren't followed.
    static let maximumRemoteDepth = 32

    // MARK: Download

    func runRemoteDownload(_ paths: [RemotePath], into folder: URL) throws {
        guard let host = paths.first?.host else { return }
        let channel = RemoteChannel(host: host, open: environment.openSFTP)
        defer { channel.close() }
        transferRoots = []
        defer {
            if !transferRoots.isEmpty {
                result.inverse = .trash(transferRoots.map(\.destination))
            }
        }

        var plan: [RemoteNode] = []
        for path in paths {
            try checkpoint()
            var node: RemoteNode?
            let found = try attempt(path.url) {
                let client = try channel.client()
                let real = try client.realpath(path.path)
                let attributes = try client.stat(path.path)
                node = try remoteNode(path, attributes: attributes, real: real, client: client, depth: 0)
            }
            guard found, let node else { continue }
            plan.append(node)
            if FileStatus(path: folder.appendingPathComponent(node.name).path) != nil {
                remainingConflicts += 1
            }
        }

        progress.phase = .running
        report(force: true)
        for node in plan {
            let destination = folder.appendingPathComponent(node.name, isDirectory: node.isDirectory)
            if let placed = try download(node, to: destination, channel: channel, recordsRoot: true) {
                result.resultingItems.append(placed)
            }
        }
    }

    /// Walks a remote item. `real` is its resolved path, to stop at links that loop back.
    private func remoteNode(
        _ path: RemotePath,
        attributes: SFTPAttributes,
        real: String,
        client: SFTPClient,
        depth: Int
    ) throws -> RemoteNode {
        let size = attributes.fileType == .directory ? 0 : Int64(clamping: attributes.size ?? 0)
        var node = RemoteNode(path: path, attributes: attributes, totalBytes: size)
        progress.totalItems += 1
        progress.totalBytes += size
        report()
        guard node.isDirectory, depth < Self.maximumRemoteDepth else { return node }

        for entry in try client.listDirectory(path.path) {
            try checkpoint()
            let childPath = path.appending(entry.name)
            var childAttributes = entry.attributes
            var childReal = real == "/" ? "/" + entry.name : real + "/" + entry.name
            if childAttributes.fileType == .symlink {
                // Broken links are left out, as there's nothing to copy.
                guard let target = try? client.stat(childPath.path) else { continue }
                childAttributes = target
                if target.fileType == .directory {
                    guard let resolved = try? client.realpath(childPath.path),
                          resolved != real, !real.hasPrefix(resolved == "/" ? "/" : resolved + "/") else { continue }
                    childReal = resolved
                }
            }
            guard childAttributes.fileType == .file || childAttributes.fileType == .directory else { continue }
            let child = try remoteNode(childPath, attributes: childAttributes, real: childReal,
                                       client: client, depth: depth + 1)
            node.children.append(child)
            node.totalBytes += child.totalBytes
            node.totalItems += child.totalItems
        }
        node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return node
    }

    /// Where an item goes, once whatever was already there has been dealt with.
    private enum Placement<Target> {
        /// Put it at `Target`, replacing what's there if `replacing`.
        case place(Target, replacing: Bool)
        /// Nothing more to do: merged into the existing folder (its target), or skipped (`nil`).
        case finished(Target?)
    }

    /// Downloads `node` to `destination`; returns where it ended up, or `nil` if skipped.
    private func download(
        _ node: RemoteNode,
        to destination: URL,
        channel: RemoteChannel,
        recordsRoot: Bool
    ) throws -> URL? {
        try checkpoint()
        progress.currentName = node.name
        report()

        switch try placement(of: node, at: destination, channel: channel, recordsRoot: recordsRoot) {
        case .finished(let placed):
            return placed
        case .place(let target, _) where node.isDirectory:
            guard try attempt(target, { try POSIXCall.check(mkdir(target.path, 0o755), target) }) else {
                skipRemote(items: node.totalItems, bytes: node.totalBytes)
                return nil
            }
            if recordsRoot { transferRoots.append(Relocation(source: node.path.url, destination: target)) }
            progress.completedItems += 1
            for child in node.children {
                let childTarget = target.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                _ = try download(child, to: childTarget, channel: channel, recordsRoot: false)
            }
            return target
        case .place(let target, let replacing):
            let baseBytes = progress.completedBytes
            let downloaded = try attempt(node.path.url) {
                progress.completedBytes = baseBytes
                try downloadFile(node, to: target, replacing: replacing, client: try channel.client())
            }
            progress.completedBytes = baseBytes + node.totalBytes
            progress.completedItems += 1
            guard downloaded else { return nil }
            if recordsRoot { transferRoots.append(Relocation(source: node.path.url, destination: target)) }
            return target
        }
    }

    /// Deals with whatever is already at a download's `destination`: merges folders, or asks.
    private func placement(
        of node: RemoteNode,
        at destination: URL,
        channel: RemoteChannel,
        recordsRoot: Bool
    ) throws -> Placement<URL> {
        guard let existing = FileStatus(path: destination.path) else { return .place(destination, replacing: false) }
        if node.isDirectory, existing.type == .directory {
            progress.completedItems += 1
            for child in node.children {
                let target = destination.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                _ = try download(child, to: target, channel: channel, recordsRoot: recordsRoot)
            }
            return .finished(destination)
        }
        switch try resolveConflict(node.conflictItem, existing.conflictItem(destination)) {
        case .replace:
            return .place(destination, replacing: true)
        case .keepBoth:
            let folder = destination.deletingLastPathComponent()
            let name = FileNaming.uniqueName(destination.lastPathComponent, hasExtension: !node.isDirectory,
                                             isTaken: FileNaming.existsChecker(in: folder))
            return .place(folder.appendingPathComponent(name, isDirectory: node.isDirectory), replacing: false)
        case .skip, .cancel:
            skipRemote(items: node.totalItems, bytes: node.totalBytes)
            return .finished(nil)
        }
    }

    private func downloadFile(_ node: RemoteNode, to destination: URL, replacing: Bool, client: SFTPClient) throws {
        let part = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).panes-part")
        let fd = open(part.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXCall.error(errno, part) }
        var isOpen = true
        var placed = false
        defer {
            if isOpen { Darwin.close(fd) }
            if !placed { unlink(part.path) }
        }

        let baseBytes = progress.completedBytes
        try client.download(node.path.path, expectedSize: node.attributes.size, to: fd) { received in
            progress.completedBytes = baseBytes + received
            report()
            try checkpoint()
        }
        if let permissions = node.attributes.permissions {
            fchmod(fd, mode_t(permissions & 0o777))
        }
        Darwin.close(fd)
        isOpen = false
        if let modified = node.attributes.modificationTime {
            let time = timespec(tv_sec: Int(modified), tv_nsec: 0)
            var times = [time, time]
            utimensat(AT_FDCWD, part.path, &times, 0)
        }
        guard renamex_np(part.path, destination.path, replacing ? 0 : UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXCall.error(errno, destination)
        }
        placed = true
    }

    // MARK: Upload

    func runRemoteUpload(_ urls: [URL], into folder: RemotePath) throws {
        let channel = RemoteChannel(host: folder.host, open: environment.openSFTP)
        defer { channel.close() }

        var plan: [LocalNode] = []
        for url in urls {
            try checkpoint()
            guard let node = try localNode(url.standardizedFileURL, depth: 0) else {
                _ = try shouldRetry(after: FileOperationFailure(url: url, error: POSIXCall.error(ENOENT, url)))
                continue
            }
            plan.append(node)
        }
        if let client = try? channel.client() {
            remainingConflicts += plan.filter { (try? client.lstat(folder.appending($0.name).path)) != nil }.count
        }

        progress.phase = .running
        report(force: true)
        for node in plan {
            if let placed = try upload(node, into: folder, channel: channel) {
                result.resultingItems.append(placed.url)
            }
        }
    }

    private func localNode(_ url: URL, depth: Int) throws -> LocalNode? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        let size = isDirectory ? 0 : Int64(info.st_size)
        var node = LocalNode(url: url, isDirectory: isDirectory, permissions: UInt32(info.st_mode) & 0o777,
                             dateModified: modified, totalBytes: size)
        progress.totalItems += 1
        progress.totalBytes += size
        report()
        guard isDirectory, depth < Self.maximumRemoteDepth,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return node }
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            try checkpoint()
            if let child = try localNode(url.appendingPathComponent(name), depth: depth + 1) {
                node.children.append(child)
                node.totalBytes += child.totalBytes
                node.totalItems += child.totalItems
            }
        }
        return node
    }

    /// Uploads `node` into `folder`; returns where it ended up, or `nil` if skipped.
    private func upload(_ node: LocalNode, into folder: RemotePath, channel: RemoteChannel) throws -> RemotePath? {
        try checkpoint()
        progress.currentName = node.name
        report()

        switch try placement(of: node, in: folder, channel: channel) {
        case .finished(let placed):
            return placed
        case .place(let target, _) where node.isDirectory:
            guard try attempt(target.url, { try channel.client().mkdir(target.path) }) else {
                skipRemote(items: node.totalItems, bytes: node.totalBytes)
                return nil
            }
            progress.completedItems += 1
            for child in node.children {
                _ = try upload(child, into: target, channel: channel)
            }
            return target
        case .place(let target, let replacing):
            let baseBytes = progress.completedBytes
            let uploaded = try attempt(node.url) {
                progress.completedBytes = baseBytes
                try uploadFile(node, to: target, replacing: replacing, client: try channel.client())
            }
            progress.completedBytes = baseBytes + node.totalBytes
            progress.completedItems += 1
            return uploaded ? target : nil
        }
    }

    /// Deals with whatever is already on the server where `node` goes: merges folders, or asks.
    private func placement(
        of node: LocalNode,
        in folder: RemotePath,
        channel: RemoteChannel
    ) throws -> Placement<RemotePath> {
        let destination = folder.appending(node.name)
        guard let existing = try? remoteAttributes(destination, client: channel.client()) else {
            return .place(destination, replacing: false)
        }
        if node.isDirectory, existing.fileType == .directory {
            progress.completedItems += 1
            for child in node.children {
                _ = try upload(child, into: destination, channel: channel)
            }
            return .finished(destination)
        }
        let existingItem = FileConflict.Item(
            url: destination.url,
            isDirectory: existing.fileType == .directory,
            size: existing.fileType == .directory ? nil : existing.size.map { Int64(clamping: $0) },
            dateModified: existing.dateModified
        )
        switch try resolveConflict(node.conflictItem, existingItem) {
        case .replace:
            return .place(destination, replacing: true)
        case .keepBoth:
            let client = try channel.client()
            let name = FileNaming.uniqueName(node.name, hasExtension: !node.isDirectory) { candidate in
                (try? client.lstat(folder.appending(candidate).path)) != nil
            }
            return .place(folder.appending(name), replacing: false)
        case .skip, .cancel:
            skipRemote(items: node.totalItems, bytes: node.totalBytes)
            return .finished(nil)
        }
    }

    /// What's at `path`, following a link unless it's broken; `nil` if nothing is there.
    private func remoteAttributes(_ path: RemotePath, client: SFTPClient) throws -> SFTPAttributes? {
        guard let attributes = try? client.lstat(path.path) else { return nil }
        guard attributes.fileType == .symlink else { return attributes }
        return (try? client.stat(path.path)) ?? attributes
    }

    private func uploadFile(_ node: LocalNode, to destination: RemotePath, replacing: Bool, client: SFTPClient) throws {
        let fd = open(node.url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXCall.error(errno, node.url) }
        defer { Darwin.close(fd) }

        let suffix = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let temporary = destination.parent?.appending(".\(node.name).panes-upload-\(suffix)")
            ?? RemotePath(host: destination.host, path: ".\(node.name).panes-upload-\(suffix)")
        var placed = false
        defer {
            if !placed { try? client.remove(temporary.path) }
        }

        let baseBytes = progress.completedBytes
        try client.upload(from: fd, to: temporary.path, permissions: node.permissions) { acknowledged in
            progress.completedBytes = baseBytes + acknowledged
            report()
            try checkpoint()
        }
        let modified = UInt32(clamping: Int64(node.dateModified.timeIntervalSince1970))
        try? client.setAttributes(temporary.path, SFTPAttributes(accessTime: modified, modificationTime: modified))
        try client.rename(temporary.path, to: destination.path, replacing: replacing)
        placed = true
    }

    // MARK: Helpers

    private func skipRemote(items: Int, bytes: Int64) {
        progress.completedItems += items
        progress.completedBytes += bytes
    }
}
