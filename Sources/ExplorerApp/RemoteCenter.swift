import AppKit
import ExplorerCore
import UniformTypeIdentifiers

/// SSH servers: connecting (with sign-in prompts in the window that asked), listing folders,
/// opening remote files through a local cache, saved connections and `~/.ssh/config` hosts,
/// and a notification when the list of servers changes.
@MainActor
enum RemoteCenter {
    static let didChangeNotification = Notification.Name("RemoteCenterDidChange")

    static let store = RemoteConnectionStore()
    private static var prompter: AskpassPrompter?
    private static var command = SSHCommand()
    /// The window to show sign-in prompts on, per host.
    private static var windows: [String: WeakWindow] = [:]
    private static var cachedConfigHosts: (date: Date?, hosts: [SSHConfigHost]) = (nil, [])

    /// Sets up sign-in prompts and the connection pool. Called once at launch.
    static func start() {
        // For testing against a private server: an ssh config file to use instead of ~/.ssh/config.
        let configFile = ProcessInfo.processInfo.environment["EXPLORER_SSH_CONFIG"]
        command = SSHCommand(configFile: configFile)
        do {
            try command.prepareSocketDirectory()
            let socket = command.socketDirectory.appendingPathComponent("askpass-\(getpid()).sock").path
            prompter = try AskpassPrompter(socketPath: socket) { key in windows[key]?.window }
        } catch {
            NSLog("SSH sign-in prompts unavailable: \(error)")
        }
        let environment = prompter?.environment ?? [:]
        let configuration = SSHConnectionPool.Configuration(command: command) { host in
            environment.merging([AskpassEnvironment.connection: host.key]) { $1 }
        }
        Task { await SSHConnectionPool.shared.configure(configuration) }
        Task.detached(priority: .background) { cleanCache() }
    }

    /// Disconnects from every server, waiting at most two seconds. Called at quit.
    static func shutdown() {
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await SSHConnectionPool.shared.shutdown()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 2)
        prompter?.stop()
    }

    static func observe(_ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    private static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: Servers

    /// A server listed under Network: saved connections, then `~/.ssh/config` hosts.
    struct Server {
        let title: String
        let location: RemotePath
        let isSaved: Bool
    }

    static func servers() -> [Server] {
        let saved = store.connections.map { Server(title: $0.host.displayName, location: $0.location, isSaved: true) }
        let savedKeys = Set(store.connections.map(\.host.key))
        let configured = configHosts().compactMap { entry -> Server? in
            guard let host = entry.remoteHost, !savedKeys.contains(host.key) else { return nil }
            return Server(title: entry.alias, location: RemotePath(host: host, path: ""), isSaved: false)
        }
        return saved + configured
    }

    /// Hosts from the ssh config, read again only when the file changes.
    static func configHosts() -> [SSHConfigHost] {
        let file = command.configFile.map { URL(fileURLWithPath: $0) } ?? SSHConfigParser.defaultFile
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != cachedConfigHosts.date || date == nil {
            cachedConfigHosts = (date, SSHConfigParser.hosts(in: file))
        }
        return cachedConfigHosts.hosts
    }

    static func save(_ connection: SavedRemoteConnection) {
        store.save(connection)
        postChange()
    }

    static func remove(_ host: RemoteHost) {
        store.remove(host)
        postChange()
    }

    // MARK: Connecting and listing

    /// Signs in to `host` if needed, with prompts on `window`.
    static func connect(_ host: RemoteHost, from window: NSWindow?) async throws {
        if let window { windows[host.key] = WeakWindow(window: window) }
        prompter?.resetAttempts(for: host.key)
        do {
            try await SSHConnectionPool.shared.connect(host)
        } catch let error as SSHError {
            throw prompter?.takeCancellation(for: host.key) == true ? SSHError.cancelled : error
        }
    }

    /// The items in `folder`, resolving it first if it's relative to the home folder.
    static func list(
        _ folder: RemotePath,
        includeHidden: Bool,
        from window: NSWindow?
    ) async throws -> (folder: RemotePath, items: [FileItem]) {
        try await connect(folder.host, from: window)
        return try await SSHConnectionPool.shared.browse(folder.host) { client in
            let resolved = folder.isResolved
                ? folder
                : RemotePath(host: folder.host, path: try client.realpath(folder.path))
            return (resolved, try RemoteListing.items(in: resolved, includeHidden: includeHidden, using: client))
        }
    }

    static func isConnected(_ host: RemoteHost) async -> Bool {
        await SSHConnectionPool.shared.isConnected(host)
    }

    static func disconnect(_ host: RemoteHost) {
        Task {
            await SSHConnectionPool.shared.disconnect(host)
            postChange()
        }
    }

    /// Windows-style wording for an error from connecting to or listing `path`.
    static func message(for error: Error, at path: RemotePath) -> String {
        switch error {
        case let error as SSHError: return error.message(for: path.host)
        case let error as SFTPError: return error.message(for: path.isResolved ? path.path : path.addressString)
        default: return error.localizedDescription
        }
    }

    // MARK: Transfers

    /// Downloads remote items into a local folder, with the usual progress and conflicts.
    /// Undoable unless `registersUndo` is false (copies made only to open files).
    @discardableResult
    static func download(
        _ paths: [RemotePath],
        into folder: URL,
        from window: NSWindow?,
        registersUndo: Bool = true
    ) async -> FileOperationResult? {
        guard let host = paths.first?.host else { return nil }
        do {
            try await connect(host, from: window)
        } catch {
            await showConnectionError(error, at: paths[0], on: window, verb: "download")
            return nil
        }
        return await FileOperationCenter.shared.perform(.remoteDownload(paths, into: folder),
                                                        registersUndo: registersUndo)
    }

    /// Uploads local items into a remote folder.
    @discardableResult
    static func upload(_ urls: [URL], into folder: RemotePath, from window: NSWindow?) async -> FileOperationResult? {
        do {
            try await connect(folder.host, from: window)
        } catch {
            await showConnectionError(error, at: folder, on: window, verb: "upload")
            return nil
        }
        return await FileOperationCenter.shared.perform(.remoteUpload(urls, into: folder))
    }

    /// "Couldn't <verb> — no connection to <server>", unless the user cancelled signing in.
    static func showConnectionError(_ error: Error, at path: RemotePath, on window: NSWindow?, verb: String) async {
        if case SSHError.cancelled = error { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t \(verb) — no connection to “\(path.host.displayName)”"
        alert.informativeText = message(for: error, at: path)
        if let window {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Opening

    private static let editNoticeKey = "RemoteEditNoticeShown"

    /// Opens remote files: downloads them to a cache (reusing an up-to-date copy), then opens
    /// the copies, with `app` or each file's default app.
    static func open(_ items: [FileItem], with app: URL? = nil, from window: NSWindow?) {
        let files = items.filter { !$0.isFolder }.compactMap { item in RemotePath(url: item.url).map { (item, $0) } }
        guard !files.isEmpty else { return }
        Task {
            var local: [URL] = []
            var stale: [RemotePath] = []
            for (item, path) in files {
                let copy = cacheURL(for: path)
                local.append(copy)
                if !isCurrent(copy, for: item) {
                    try? FileManager.default.removeItem(at: copy)
                    stale.append(path)
                }
            }
            for (folder, group) in Dictionary(grouping: stale, by: { cacheURL(for: $0).deletingLastPathComponent() }) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = await download(group, into: folder, from: window, registersUndo: false)
                guard let result, !result.wasCancelled else { return }
            }
            let available = local.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !available.isEmpty else { return }
            CloudCenter.open(available, withApplicationAt: app)
            showEditNoticeOnce(on: window)
        }
    }

    private static func showEditNoticeOnce(on window: NSWindow?) {
        guard !UserDefaults.standard.bool(forKey: editNoticeKey) else { return }
        UserDefaults.standard.set(true, forKey: editNoticeKey)
        let alert = NSAlert()
        alert.messageText = "You’re working on a copy"
        alert.informativeText = "Files on SSH servers open as a copy on this Mac. Changes you save stay in the "
            + "copy; to put them back on the server, copy the file to the server’s folder."
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    static var cacheFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "Panes"
        return caches.appendingPathComponent(bundle).appendingPathComponent("Remote Files", isDirectory: true)
    }

    /// `<cache>/<host>/<folder>/<name>`: one folder per remote folder, so names don't clash.
    private static func cacheURL(for path: RemotePath) -> URL {
        let folder = path.parent?.path ?? "/"
        return cacheFolder
            .appendingPathComponent(stableHash(path.host.key))
            .appendingPathComponent(stableHash(folder))
            .appendingPathComponent(path.name)
    }

    /// Whether the cached copy matches the remote file's size and date.
    private static func isCurrent(_ copy: URL, for item: FileItem) -> Bool {
        guard let values = try? copy.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let date = values.contentModificationDate, let remoteDate = item.dateModified else { return false }
        return Int64(values.fileSize ?? -1) == item.size && abs(date.timeIntervalSince(remoteDate)) < 1
    }

    private static func stableHash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }

    /// Removes cached folders not written to for a week.
    nonisolated private static func cleanCache() {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Panes")
            .appendingPathComponent("Remote Files", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let hosts = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for host in hosts {
            let folders = (try? fileManager.contentsOfDirectory(
                at: host, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for folder in folders {
                let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let date, date < cutoff { try? fileManager.removeItem(at: folder) }
            }
        }
    }
}

private struct WeakWindow {
    weak var window: NSWindow?
}

/// Icons for items, local or remote. Remote items have no file to ask, so their icon comes
/// from their type, cached per type.
@MainActor
enum FileIcons {
    private static var byType: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        icon(for: item.url, isDirectory: item.isFolder)
    }

    static func icon(for url: URL, isDirectory: Bool) -> NSImage {
        guard url.scheme == RemotePath.urlScheme else { return NSWorkspace.shared.icon(forFile: url.path) }
        let type: UTType = isDirectory ? .folder : UTType(filenameExtension: url.pathExtension) ?? .data
        if let cached = byType[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        byType[type.identifier] = image
        return image
    }
}
