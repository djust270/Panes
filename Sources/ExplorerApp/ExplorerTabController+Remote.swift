import AppKit
import ExplorerCore

/// Folders on SSH servers: loading them, Connect to SSH Server, Download to… and Upload…,
/// copying and pasting between this Mac and a server, and which commands work there (browse,
/// open and copy in or out; no rename, delete or new items).
extension ExplorerTabController {
    var currentRemoteFolder: RemotePath? { history.current.remotePath }
    var inRemote: Bool { currentRemoteFolder != nil }

    /// The selected items' remote paths (empty unless they're on an SSH server).
    var selectedRemotePaths: [RemotePath] {
        content.selectedItems.compactMap { RemotePath(url: $0.url) }
    }

    // MARK: Loading

    /// Network's items: computers found on the network, then SSH servers.
    func networkItems() -> [FileItem] {
        let computers = NetworkBrowser.shared.computers().map { computer in
            FileItem(url: computer.url, name: computer.name, kind: .directory)
        }
        let servers = RemoteCenter.servers().map { server in
            FileItem(url: server.location.url, name: server.title, kind: .directory)
        }
        return computers + servers
    }

    func loadRemote(_ folder: RemotePath) {
        let includeHidden = loader.options.includeHidden
        loadTask = Task { [weak self] in
            guard let self else { return }
            if await !RemoteCenter.isConnected(folder.host) {
                rootViewController.statusBar.text = "Connecting to \(folder.host.displayName)…"
            }
            do {
                let (resolved, items) = try await RemoteCenter.list(folder, includeHidden: includeHidden,
                                                                    from: view.window)
                guard !Task.isCancelled, history.current == .remote(folder) else { return }
                if resolved != folder { adopt(.remote(resolved)) }
                content.setItems(items)
                updateStatusBar()
            } catch is CancellationError {
                // Superseded by a newer load.
            } catch {
                guard !Task.isCancelled, history.current == .remote(folder) else { return }
                showRemoteError(error, at: folder)
            }
        }
    }

    private func showRemoteError(_ error: Error, at folder: RemotePath) {
        let message = RemoteCenter.message(for: error, at: folder)
        switch error {
        case SSHError.cancelled, SSHError.authenticationFailed, SSHError.hostKeyRejected:
            content.showUnavailable(message, action: (title: "Connect", run: { [weak self] in self?.reload() }))
        default:
            content.showUnavailable(message, action: (title: "Try again", run: { [weak self] in self?.reload() }))
        }
        rootViewController.statusBar.text = ""
    }

    // MARK: Connecting

    /// "Connect to SSH Server…": asks for the server, signs in, then opens it, remembering it
    /// under Network if asked to.
    @objc func connectToSSHServer(_ sender: Any?) {
        guard let window = view.window else { return }
        let selected = history.current == .network ? selectedRemotePaths.first : currentRemoteFolder
        Task {
            guard let choice = await ConnectSSHDialog.ask(initial: selected, on: window) else { return }
            rootViewController.statusBar.text = "Connecting to \(choice.location.host.displayName)…"
            do {
                try await RemoteCenter.connect(choice.location.host, from: window)
            } catch {
                updateStatusBar()
                if case SSHError.cancelled = error { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t connect to “\(choice.location.host.displayName)”"
                alert.informativeText = RemoteCenter.message(for: error, at: choice.location)
                await present(alert)
                return
            }
            if choice.remember {
                RemoteCenter.save(SavedRemoteConnection(host: choice.location.host, startPath: choice.location.path))
            }
            navigate(to: .remote(choice.location))
        }
    }

    /// The server to act on: the one being browsed, or the one selected under Network.
    private var targetServer: RemoteHost? {
        currentRemoteFolder?.host ?? (history.current == .network ? selectedRemotePaths.first?.host : nil)
    }

    @objc func disconnectServer(_ sender: Any?) {
        guard let host = targetServer else { return }
        RemoteCenter.disconnect(host)
        if currentRemoteFolder != nil { navigate(to: .network) }
    }

    /// "Remove connection": forgets a saved server.
    @objc func forgetServer(_ sender: Any?) {
        guard let host = targetServer else { return }
        RemoteCenter.remove(host)
    }

    // MARK: Transfers

    /// "Download to…": copies the selected remote items into a folder chosen in a panel.
    @objc func downloadSelection(_ sender: Any?) {
        let paths = selectedRemotePaths
        guard !paths.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Choose where to download \(paths.count == 1 ? "“\(paths[0].name)”" : "\(paths.count) items")."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { await RemoteCenter.download(paths, into: folder, from: window) }
        }
    }

    /// "Upload files…": copies files chosen in a panel into the remote folder being shown.
    @objc func uploadFiles(_ sender: Any?) {
        guard let folder = currentRemoteFolder, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files and folders to upload to “\(folder.name)”."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls.map(\.standardizedFileURL)
            Task { await self?.upload(urls, into: folder) }
        }
    }

    /// Uploads, then shows and selects what arrived if that folder is on screen.
    func upload(_ urls: [URL], into folder: RemotePath) async {
        guard let result = await RemoteCenter.upload(urls, into: folder, from: view.window) else { return }
        if currentRemoteFolder == folder, !result.resultingItems.isEmpty {
            content.select(result.resultingItems)
            reload()
        }
    }

    /// Downloads, then selects what arrived if that folder is on screen.
    func download(_ paths: [RemotePath], into folder: URL) async {
        guard let result = await RemoteCenter.download(paths, into: folder, from: view.window) else { return }
        if currentFolder?.standardizedFileURL == folder.standardizedFileURL, !result.resultingItems.isEmpty {
            content.select(result.resultingItems)
            reload()
        }
    }

    // MARK: Delete, rename, new folder

    /// Delete in a remote folder: permanent, after asking, as on Windows for network folders.
    func deleteRemoteSelection() {
        let paths = selectedRemotePaths
        guard !paths.isEmpty else { return }
        Task {
            let message = paths.count == 1
                ? "Are you sure you want to permanently delete “\(paths[0].name)”?"
                : "Are you sure you want to permanently delete these \(paths.count) items?"
            let detail = "Items on “\(paths[0].host.displayName)” don’t go to the Recycle Bin. "
                + "You can’t undo this action."
            guard await confirm(message, detail: detail, button: "Delete") else { return }
            await perform(.remoteDelete(paths))
            reload()
        }
    }

    /// The request renaming `item` (on this Mac or on a server).
    func renameRequest(for item: FileItem, to name: String) -> FileOperationRequest {
        RemotePath(url: item.url).map { .remoteRename($0, to: name) } ?? .rename(item.url, to: name)
    }

    /// Signs in to the server `request` works on, if any. False (after saying why) if that
    /// failed.
    func connectIfRemote(_ request: FileOperationRequest) async -> Bool {
        guard let host = request.remoteHost else { return true }
        do {
            try await RemoteCenter.connect(host, from: view.window)
            return true
        } catch {
            let place = request.sourceURLs.first.flatMap(RemotePath.init(url:)) ?? currentRemoteFolder
                ?? RemotePath(host: host, path: "")
            await RemoteCenter.showConnectionError(error, at: place, on: view.window,
                                                   verb: request.actionName.lowercased())
            return false
        }
    }

    // MARK: Copy and paste

    /// Copy in a remote folder: the items' addresses, which Paste in a local folder downloads.
    func copyRemoteSelection() {
        let paths = selectedRemotePaths
        guard !paths.isEmpty else { return }
        FileClipboard.shared.writeRemote(paths)
    }

    /// Paste in a remote folder uploads copied files; in a local folder, it downloads copied
    /// remote items. Returns false if there was nothing remote about it.
    func pasteRemote() -> Bool {
        if let folder = currentRemoteFolder {
            guard let (urls, _) = FileClipboard.shared.read() else { return true }
            Task { await upload(urls, into: folder) }
            return true
        }
        if let folder = currentFolder, let paths = FileClipboard.shared.readRemote() {
            Task { await download(paths, into: folder) }
            return true
        }
        return false
    }

    // MARK: Validation

    // Validates commands in a remote folder (most file commands don't apply there) and the
    // SSH commands anywhere; `nil` to leave the rest to the other validators.
    // swiftlint:disable:next cyclomatic_complexity
    func validateRemoteMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        let selection = content.selectedItems
        switch menuItem.action {
        case #selector(connectToSSHServer(_:)):
            return true
        case #selector(disconnectServer(_:)):
            return targetServer != nil
        case #selector(forgetServer(_:)):
            return targetServer.map { RemoteCenter.store.connection(for: $0) != nil } ?? false
        case #selector(downloadSelection(_:)):
            return inRemote && !selection.isEmpty
        case #selector(uploadFiles(_:)):
            return inRemote
        default:
            break
        }
        guard inRemote else { return nil }

        switch menuItem.action {
        case #selector(openSelection(_:)), #selector(copy(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)):
            return FileClipboard.shared.canPaste
        case #selector(delete(_:)), #selector(deletePermanently(_:)):
            return !selection.isEmpty
        case #selector(renameSelection(_:)):
            return selection.count == 1
        case #selector(newFolder(_:)):
            return true
        case #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)):
            return selection.contains(where: \.isFolder)
        case #selector(openWith(_:)), #selector(openWithOtherApp(_:)):
            return selection.contains { !$0.isFolder }
        case #selector(copyAsPath(_:)):
            return true
        case #selector(cut(_:)), #selector(newTextDocument(_:)),
             #selector(sendTo(_:)), #selector(sendToMail(_:)), #selector(shareSelection(_:)),
             #selector(compressSelection(_:)), #selector(showProperties(_:)), #selector(extractAll(_:)),
             #selector(openInTerminal(_:)), #selector(copyAsWindowsPath(_:)), #selector(copyToOtherPane(_:)),
             #selector(moveToOtherPane(_:)), #selector(pinToQuickAccess(_:)), #selector(unpinFromQuickAccess(_:)),
             #selector(removeFromFrequent(_:)), #selector(addToFavorites(_:)), #selector(removeFromFavorites(_:)),
             #selector(removeFromRecent(_:)), #selector(openFileLocation(_:)), #selector(downloadNow(_:)),
             #selector(freeUpSpace(_:)), #selector(performProviderAction(_:)):
            return false
        default:
            return nil
        }
    }
}
