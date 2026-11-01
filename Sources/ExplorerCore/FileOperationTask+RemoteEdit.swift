import Foundation

/// An item to delete on a server and, for folders, what's inside. Links are items in their
/// own right: deleting one never touches what it points to.
struct RemoteDeletion {
    let path: RemotePath
    let isDirectory: Bool
    var children: [RemoteDeletion] = []
}

/// Delete, rename and new folder on SSH servers. Deleting is permanent, as on Windows for
/// network locations; a rename can be undone.
extension FileOperationTask {
    /// Folders nested deeper than this aren't emptied (nothing loops: links aren't followed).
    static let maximumDeletionDepth = 256

    // MARK: Delete

    func runRemoteDelete(_ paths: [RemotePath]) throws {
        guard let host = paths.first?.host else { return }
        let channel = RemoteChannel(host: host, open: environment.openSFTP)
        defer { channel.close() }

        var plan: [RemoteDeletion] = []
        for path in paths {
            try checkpoint()
            var node: RemoteDeletion?
            let found = try attempt(path.url) { node = try deletionNode(path, client: try channel.client(), depth: 0) }
            if found, let node { plan.append(node) }
        }
        progress.phase = .running
        report(force: true)
        for node in plan {
            _ = try delete(node, channel: channel)
        }
    }

    /// Walks what's to be deleted, without following links. `nil` if it's already gone.
    private func deletionNode(_ path: RemotePath, client: SFTPClient, depth: Int) throws -> RemoteDeletion? {
        try checkpoint()
        let attributes: SFTPAttributes
        do {
            attributes = try client.lstat(path.path)
        } catch SFTPError.status(.noSuchFile, _) {
            return nil
        }
        var node = RemoteDeletion(path: path, isDirectory: attributes.fileType == .directory)
        progress.totalItems += 1
        report()
        guard node.isDirectory, depth < Self.maximumDeletionDepth else { return node }
        for entry in try client.listDirectory(path.path) {
            if let child = try deletionNode(path.appending(entry.name), client: client, depth: depth + 1) {
                node.children.append(child)
            }
        }
        return node
    }

    /// Deletes `node`, contents first. Returns false if anything was left (skipped), in which
    /// case its folders stay too.
    private func delete(_ node: RemoteDeletion, channel: RemoteChannel) throws -> Bool {
        try checkpoint()
        progress.currentName = node.path.name
        report()
        var emptied = true
        for child in node.children {
            emptied = try delete(child, channel: channel) && emptied
        }
        defer { progress.completedItems += 1 }
        guard emptied else { return false }
        return try attempt(node.path.url) {
            let client = try channel.client()
            do {
                if node.isDirectory {
                    try client.rmdir(node.path.path)
                } else {
                    try client.remove(node.path.path)
                }
            } catch SFTPError.status(.noSuchFile, _) {
                // Already gone: that's what was wanted.
            }
        }
    }

    // MARK: Rename

    func runRemoteRename(_ path: RemotePath, to name: String) {
        progress.totalItems = 1
        if let message = Self.remoteNameError(name) {
            result.failures.append(FileOperationFailure(url: path.url, reason: .invalidName, message: message))
            return
        }
        guard let parent = path.parent else { return }
        let destination = parent.appending(name)
        guard destination.path != path.path else { return }

        let channel = RemoteChannel(host: path.host, open: environment.openSFTP)
        defer { channel.close() }
        do {
            let client = try channel.client()
            if name.lowercased() == path.name.lowercased() {
                // Case only: on a case-insensitive server the "new" name is the item itself,
                // and a plain rename would refuse. Go through a temporary name.
                let temporary = parent.appending(".\(path.name).panes-rename-\(UInt32.random(in: 0...UInt32.max))")
                try client.rename(path.path, to: temporary.path)
                try client.rename(temporary.path, to: destination.path)
            } else {
                guard (try? client.lstat(destination.path)) == nil else {
                    result.failures.append(FileOperationFailure(
                        url: path.url,
                        reason: .alreadyExists,
                        message: "There is already a file with the same name in this location."
                    ))
                    return
                }
                try client.rename(path.path, to: destination.path)
            }
        } catch {
            result.failures.append(FileOperationFailure(url: path.url, error: error))
            return
        }
        progress.completedItems = 1
        result.resultingItems = [destination.url]
        result.inverse = .remoteRename(destination, to: path.name)
    }

    // MARK: New folder

    func runRemoteCreateFolder(in folder: RemotePath, name: String) {
        progress.totalItems = 1
        if let message = Self.remoteNameError(name) {
            result.failures.append(FileOperationFailure(url: folder.url, reason: .invalidName, message: message))
            return
        }
        let channel = RemoteChannel(host: folder.host, open: environment.openSFTP)
        defer { channel.close() }
        do {
            let client = try channel.client()
            let isTaken = { (candidate: String) in (try? client.lstat(folder.appending(candidate).path)) != nil }
            // Retry a few times in case something else takes the name between check and create.
            for _ in 0..<5 {
                let path = folder.appending(FileNaming.uniqueName(name, hasExtension: false, isTaken: isTaken))
                do {
                    try client.mkdir(path.path)
                } catch SFTPError.status(.failure, _) where isTaken(path.name) {
                    continue
                }
                progress.completedItems = 1
                result.resultingItems = [path.url]
                return
            }
            result.failures.append(
                FileOperationFailure(url: folder.url, reason: .alreadyExists, message: "Couldn't find a free name.")
            )
        } catch {
            result.failures.append(FileOperationFailure(url: folder.url, error: error))
        }
    }

    /// Why `name` can't be used on a server; `nil` if it can. Servers allow more than the Mac
    /// does (a colon is fine), so this is `FileNaming.validationError` without the colon.
    static func remoteNameError(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "You must type a file name." }
        if name.contains("/") || name.contains("\0") { return "A file name can't contain a slash (/)." }
        if name == "." || name == ".." { return "The names “.” and “..” are reserved." }
        if name.utf8.count > 255 { return "The file name is too long." }
        return nil
    }
}
