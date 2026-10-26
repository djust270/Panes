import AppKit
import ExplorerCore

/// Navigation commands, and the Windows 11 context menu's extras: open in a new tab or
/// window, Open with, Send to, Share, Compress to ZIP file and Copy as path.
extension ExplorerTabController {
    // MARK: Navigation

    @objc func goBack(_ sender: Any?) {
        goBack(steps: 1)
    }

    @objc func goForward(_ sender: Any?) {
        goForward(steps: 1)
    }

    @objc func goUp(_ sender: Any?) {
        navigateUp()
    }

    @objc func refresh(_ sender: Any?) {
        reload()
    }

    /// Ctrl+L / Alt+D / F4: edit the path in the address bar.
    @objc func editAddress(_ sender: Any?) {
        addressBar.beginEditing()
    }

    // MARK: Opening

    @objc func openInNewTab(_ sender: Any?) {
        for folder in selectedFolders() {
            host?.openTab(at: .folder(folder), besides: self, select: false)
        }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        for folder in selectedFolders() {
            AppDelegate.shared.openWindow(at: .folder(folder))
        }
    }

    private func selectedFolders() -> [URL] {
        content.selectedItems.filter(\.isFolder).map(\.url)
    }

    /// "Open with ▸ <app>"; the menu item carries the app's URL.
    @objc func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let files = content.selectedItems.filter { !$0.isFolder }.map(\.url)
        open(files, with: app)
    }

    /// "Open with ▸ Choose another app…", with "Always use this app to open .ext files".
    @objc func openWithOtherApp(_ sender: Any?) {
        let files = content.selectedItems.filter { !$0.isFolder }.map(\.url)
        guard !files.isEmpty, let window = view.window else { return }
        Task {
            guard let choice = await DefaultApps.chooseApp(for: files, in: window, offerAlways: true) else { return }
            if choice.always, let error = await DefaultApps.setDefault(choice.app, for: files[0]) {
                await inform("Couldn’t make it the default app. \(error)")
            }
            open(files, with: choice.app)
        }
    }

    private func open(_ files: [URL], with app: URL) {
        CloudCenter.open(files, withApplicationAt: app)
    }

    /// The apps that can open every one of `files`: the default app, and the others by name.
    static func apps(toOpen files: [URL]) -> (default: URL?, others: [URL]) {
        guard let first = files.first else { return (nil, []) }
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: first)
        var apps = workspace.urlsForApplications(toOpen: first)
        for file in files.dropFirst().prefix(20) {
            let supported = Set(workspace.urlsForApplications(toOpen: file))
            apps = apps.filter(supported.contains)
        }
        var seen = Set<String>()
        let others = apps.filter { $0 != defaultApp && seen.insert($0.lastPathComponent).inserted }
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent) == .orderedAscending }
        return (defaultApp, others)
    }

    // MARK: Send to, Share

    /// "Send to ▸ Desktop / Documents / <drive>": copies the selection there.
    @objc func sendTo(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        Task { await perform(.copy(urls, into: folder)) }
    }

    /// "Send to ▸ Mail recipient".
    @objc func sendToMail(_ sender: Any?) {
        NSSharingService(named: .composeEmail)?.perform(withItems: selectedURLs)
    }

    /// Share (command bar or context menu): the system share sheet for the selection.
    @objc func shareSelection(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let button = sender as? NSButton, button.window != nil {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            let anchor = content.anchorRectForSelection()
            picker.show(relativeTo: anchor, of: content.activeView, preferredEdge: .minY)
        }
    }

    // MARK: Copy as path, Compress

    @objc func copyAsPath(_ sender: Any?) {
        let urls = selectedURLs.isEmpty ? currentFolder.map { [$0] } ?? [] : selectedURLs
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(FileNaming.quotedPaths(urls), forType: .string)
    }

    /// "Compress to ZIP file": a .zip named after the (first) selected item, next to it, then
    /// renamed in place, as on Windows. Uses `ditto` (Finder's own archiver) for one item, which
    /// keeps extended attributes; `zip` for several.
    @objc func compressSelection(_ sender: Any?) {
        guard let folder = currentFolder else { return }
        let items = content.selectedItems
        guard let first = items.first else { return }
        let name = FileNaming.uniqueName(FileNaming.zipName(for: first.name, hasExtension: first.kind != .directory)) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let archive = folder.appendingPathComponent(name)
        let arguments: (tool: String, args: [String])
        if items.count == 1 {
            let options = ["-c", "-k", "--sequesterRsrc", "--keepParent"]
            arguments = ("/usr/bin/ditto", options + [first.url.path, archive.path])
        } else {
            arguments = ("/usr/bin/zip", ["-r", "-y", "-q", archive.path] + items.map { "./" + $0.name })
        }
        rootViewController.statusBar.text = "Compressing…"
        Task {
            let failure = await CommandLineTool.run(arguments.tool, arguments.args, in: folder)
            updateStatusBar()
            if let failure {
                try? FileManager.default.removeItem(at: archive)
                await inform("Couldn’t compress the files. \(failure)")
                return
            }
            content.select([archive], renaming: archive)
            reload()
        }
    }

    // MARK: Properties

    /// Properties (Alt+Enter): of the selection, or of the folder when nothing is selected.
    @objc func showProperties(_ sender: Any?) {
        PropertiesWindowController.show(propertiesTargets)
    }

    private var propertiesTargets: [URL] {
        if !selectedURLs.isEmpty { return selectedURLs }
        return currentFolder.map { [$0] } ?? []
    }

    // MARK: Drives

    /// "Map network drive…": connects to a share and remembers it with a drive letter.
    @objc func mapNetworkDrive(_ sender: Any?) {
        guard let window = view.window else { return }
        // From a computer under Network, start with its address.
        var folder = ""
        if history.current == .network, let host = content.selectedItems.first?.url.host {
            folder = #"\\"# + host + #"\"#
        }
        Task {
            guard let choice = await MapDriveDialog.ask(folder: folder, on: window) else { return }
            connect(to: choice.path, signIn: choice.differentCredentials ? .ask : .automatic) { _ in
                DriveCenter.map(MappedDrive(shareURL: choice.path.shareURL, letter: choice.letter,
                                            reconnects: choice.reconnects))
            }
        }
    }

    /// Eject (disks) or Disconnect (network drives), from This PC.
    @objc func ejectSelection(_ sender: Any?) {
        for volume in content.selectedItems.compactMap(\.volume) where volume.canEject {
            DriveCenter.eject(at: volume.url, from: view.window)
        }
    }

    // MARK: Validation

    // Validates the commands above; `nil` for anything else.
    // swiftlint:disable:next cyclomatic_complexity
    func validateCommandMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        let selection = content.selectedItems
        let inFolder = currentFolder != nil
        switch menuItem.action {
        case #selector(goBack(_:)):
            return history.canGoBack
        case #selector(goForward(_:)):
            return history.canGoForward
        case #selector(goUp(_:)):
            return history.current.parent != nil
        case #selector(refresh(_:)), #selector(editAddress(_:)):
            return true
        case #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)):
            return selection.contains(where: \.isFolder) && history.current != .recycleBin
        case #selector(openWith(_:)), #selector(openWithOtherApp(_:)):
            return selection.contains { !$0.isFolder } && history.current != .recycleBin
        case #selector(sendTo(_:)), #selector(sendToMail(_:)), #selector(shareSelection(_:)):
            return !selection.isEmpty && (inFolder || inSearchResults || history.current == .home)
        case #selector(compressSelection(_:)):
            return !selection.isEmpty && inFolder
        case #selector(copyAsPath(_:)):
            return !selection.isEmpty || inFolder
        case #selector(showProperties(_:)):
            return !propertiesTargets.isEmpty
        case #selector(ejectSelection(_:)):
            return selection.contains { $0.volume?.canEject == true }
        default:
            return nil
        }
    }
}
