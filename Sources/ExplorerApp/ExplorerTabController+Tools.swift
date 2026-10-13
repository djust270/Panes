import AppKit
import ExplorerCore

/// Extract All, Open in Terminal, Copy as Windows path, and dual-pane commands.
extension ExplorerTabController {
    /// The selected archive, if exactly one archive is selected.
    private var selectedArchive: URL? {
        let selection = content.selectedItems
        guard selection.count == 1, let item = selection.first, item.kind == .file,
              Archive.isExtractable(item.url) else { return nil }
        return item.url
    }

    // MARK: Extract All

    /// "Extract All…": asks for a destination, unpacks there, and opens it in a new tab.
    @objc func extractAll(_ sender: Any?) {
        guard let archive = selectedArchive, let window = view.window else { return }
        Task {
            guard let choice = await ExtractWizard.ask(for: archive, on: window) else { return }
            await extract(archive, to: choice.destination, showingFiles: choice.showsFiles)
        }
    }

    /// Unpacks into a staging folder on the destination's volume, then moves the contents in
    /// with the file-operation engine, so existing files get the usual Replace or Skip prompt.
    private func extract(_ archive: URL, to destination: URL, showingFiles: Bool) async {
        let fileManager = FileManager.default
        let staging: URL
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
        } catch {
            await inform("Couldn’t create “\(destination.lastPathComponent)”. \(error.localizedDescription)")
            return
        }
        defer { try? fileManager.removeItem(at: staging) }

        let sheet = ActivitySheet(message: "Extracting “\(archive.lastPathComponent)”…")
        let command = Archive.extractionCommand(for: archive, into: staging)
        let work = Task { await CommandLineTool.run(command.tool, command.arguments) }
        sheet.onCancel = { work.cancel() }
        sheet.present(on: view.window)
        let failure = await work.value
        sheet.dismiss()
        if work.isCancelled { return }
        if let failure {
            await inform("Couldn’t extract “\(archive.lastPathComponent)”. \(failure)")
            return
        }

        let extracted = (try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        if !extracted.isEmpty {
            let result = await FileOperationCenter.shared.perform(.move(extracted, into: destination),
                                                                  registersUndo: false)
            if result.wasCancelled { return }
        }
        if showingFiles {
            host?.openTab(at: .folder(destination), besides: self, select: true)
        } else if currentFolder == destination.deletingLastPathComponent() {
            content.select([destination])
        }
    }

    // MARK: Terminal

    /// The folder for "Open in Terminal": the one selected folder, or the folder shown.
    private var terminalFolder: URL? {
        let selection = content.selectedItems
        if selection.count == 1, let item = selection.first, item.isFolder { return item.url }
        return selection.isEmpty ? currentFolder : nil
    }

    /// Windows 11's "Open in Terminal": a Terminal window in the folder.
    @objc func openInTerminal(_ sender: Any?) {
        let workspace = NSWorkspace.shared
        guard let folder = terminalFolder,
              let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Copy as Windows path

    /// `\\server\share\…` for items on SMB shares, `D:\…` with drive letters on; `nil` if no
    /// item has a Windows form.
    private func windowsPaths(for urls: [URL]) -> [String]? {
        var found = false
        let paths = urls.map { url -> String in
            guard let volume = VolumeLister.volume(containing: url),
                  let path = WindowsPath.string(for: url, volumeRoot: volume.url, shareURL: volume.remountURL,
                                                driveLetter: DriveCenter.letter(forVolumeAt: volume.url))
            else { return url.path }
            found = true
            return path
        }
        return found ? paths : nil
    }

    /// "Copy as Windows path": each path quoted, one per line, as Windows' Copy as path does.
    @objc func copyAsWindowsPath(_ sender: Any?) {
        let urls = selectedURLs.isEmpty ? currentFolder.map { [$0] } ?? [] : selectedURLs
        guard let paths = windowsPaths(for: urls) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.map { "\"\($0)\"" }.joined(separator: "\n"), forType: .string)
    }

    /// Whether "Copy as Windows path" means anything here (shown only then).
    var canCopyAsWindowsPath: Bool {
        let urls = selectedURLs.isEmpty ? currentFolder.map { [$0] } ?? [] : selectedURLs
        return !urls.isEmpty && windowsPaths(for: Array(urls.prefix(1))) != nil
    }

    // MARK: Dual pane

    /// The folder the other pane shows, in dual-pane mode.
    private var otherPaneFolder: URL? {
        host?.otherPane(of: self)?.currentFolder
    }

    @objc func copyToOtherPane(_ sender: Any?) {
        guard let folder = otherPaneFolder, !selectedURLs.isEmpty else { return }
        let urls = selectedURLs
        Task { await perform(.copy(urls, into: folder)) }
    }

    @objc func moveToOtherPane(_ sender: Any?) {
        guard let folder = otherPaneFolder, !selectedURLs.isEmpty else { return }
        let urls = selectedURLs
        Task { await perform(.move(urls, into: folder)) }
    }

    /// Moves the keyboard focus to the other pane.
    @objc func switchPane(_ sender: Any?) {
        host?.otherPane(of: self)?.focusContent()
    }

    // MARK: Validation

    /// Validates the commands above; `nil` for anything else.
    func validateToolsMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(extractAll(_:)):
            return selectedArchive != nil && (currentFolder != nil || inSearchResults)
        case #selector(openInTerminal(_:)):
            return terminalFolder != nil
        case #selector(copyAsWindowsPath(_:)):
            return canCopyAsWindowsPath
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            let listsFiles = currentFolder != nil || inSearchResults || history.current == .home
            return listsFiles && !content.selectedItems.isEmpty && otherPaneFolder != nil
        case #selector(switchPane(_:)):
            return host?.otherPane(of: self) != nil
        default:
            return nil
        }
    }
}
