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

    /// "Open with ▸ Choose another app…".
    @objc func openWithOtherApp(_ sender: Any?) {
        let files = content.selectedItems.filter { !$0.isFolder }.map(\.url)
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open “\(files[0].lastPathComponent)”"
        Task {
            guard let window = view.window, await panel.beginSheetModal(for: window) == .OK,
                  let app = panel.url else { return }
            open(files, with: app)
        }
    }

    private func open(_ files: [URL], with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration, completionHandler: nil)
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
            let failure = await Self.run(arguments.tool, arguments.args, in: folder)
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

    /// Runs a command-line tool off the main thread; returns its error output on failure.
    private static func run(_ tool: String, _ arguments: [String], in directory: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            return (String(data: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    // MARK: Validation

    /// Validates the commands above; `nil` for anything else.
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
        case #selector(sendTo(_:)), #selector(sendToMail(_:)), #selector(shareSelection(_:)),
             #selector(compressSelection(_:)):
            return !selection.isEmpty && inFolder
        case #selector(copyAsPath(_:)):
            return !selection.isEmpty || inFolder
        default:
            return nil
        }
    }
}
