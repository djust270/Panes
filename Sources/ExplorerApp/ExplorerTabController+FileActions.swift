import AppKit
import ExplorerCore

/// File commands (menus, context menu, keyboard) and drop handling for one tab. The
/// operations themselves run in `FileOperationCenter`.
extension ExplorerTabController {
    var selectedURLs: [URL] { content.selectedItems.map(\.url) }

    // MARK: Commands

    @objc func openSelection(_ sender: Any?) {
        content.activateSelection()
    }

    @objc func cut(_ sender: Any?) {
        FileClipboard.shared.write(selectedURLs, cut: true)
    }

    @objc func copy(_ sender: Any?) {
        FileClipboard.shared.write(selectedURLs, cut: false)
    }

    @objc func paste(_ sender: Any?) {
        guard let folder = currentFolder, let (urls, isCut) = FileClipboard.shared.read() else { return }
        Task {
            if isCut {
                let result = await perform(.move(urls, into: folder))
                if !result.wasCancelled { FileClipboard.shared.clearAfterMove() }
            } else {
                await perform(.copy(urls, into: folder))
            }
        }
    }

    /// Delete: to the Recycle Bin, or — inside the Recycle Bin — permanently.
    @objc func delete(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        if history.current == .recycleBin {
            deletePermanently(sender)
        } else {
            trash(selectedURLs)
        }
    }

    @objc func deletePermanently(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        Task {
            guard await confirmPermanentDelete(of: urls) else { return }
            await perform(.delete(urls))
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        content.beginRenamingSelection()
    }

    @objc func newFolder(_ sender: Any?) {
        guard let folder = currentFolder else { return }
        Task { await perform(.createFolder(in: folder, name: FileNaming.newFolderName), renamingResult: true) }
    }

    @objc func newTextDocument(_ sender: Any?) {
        guard let folder = currentFolder else { return }
        Task { await perform(.createFile(in: folder, name: FileNaming.newTextDocumentName), renamingResult: true) }
    }

    @objc func restoreSelection(_ sender: Any?) {
        restore(content.selectedItems)
    }

    @objc func restoreAll(_ sender: Any?) {
        restore(content.allItems)
    }

    @objc func emptyRecycleBin(_ sender: Any?) {
        // Everything, including hidden items the view may not be showing.
        let urls = ((try? RecycleBin.contents(includeHidden: true)) ?? content.allItems).map(\.url)
        guard !urls.isEmpty else { return }
        Task {
            guard await confirmPermanentDelete(of: urls) else { return }
            await perform(.delete(urls))
        }
    }

    // MARK: Helpers

    /// Runs `request`, then selects whatever it produced in the folder being shown.
    @discardableResult
    func perform(_ request: FileOperationRequest, renamingResult: Bool = false) async -> FileOperationResult {
        let result = await FileOperationCenter.shared.perform(request)
        let shown = result.resultingItems.filter {
            $0.standardizedFileURL.deletingLastPathComponent().path == currentFolder?.standardizedFileURL.path
        }
        if !shown.isEmpty {
            content.select(shown, renaming: renamingResult ? shown.first : nil)
            reload()
        }
        // Search results and Home aren't watched: drop what was moved or deleted.
        if inSearchResults {
            content.removeMissingItems()
            updateStatusBar()
        } else if history.current == .home {
            reload()
        }
        // Copy/move/delete failures were already handled by the operation's Retry/Skip prompt.
        switch request {
        case .rename, .createFolder, .createFile:
            if let failure = result.failures.first { await inform(failure.message) }
        default:
            break
        }
        return result
    }

    private func trash(_ urls: [URL]) {
        Task {
            guard await confirmCloudDelete(of: urls) else { return }
            let result = await perform(.trash(urls))
            let unrecyclable = result.failures.filter { $0.reason == .trashUnavailable }.map(\.url)
            guard !unrecyclable.isEmpty else { return }
            let message = unrecyclable.count == 1
                ? "“\(unrecyclable[0].lastPathComponent)” can’t be moved to the Recycle Bin."
                : "\(unrecyclable.count) items can’t be moved to the Recycle Bin."
            guard await confirm(message, detail: "Do you want to permanently delete them instead?", button: "Delete")
            else { return }
            await perform(.delete(unrecyclable))
        }
    }

    private func restore(_ items: [FileItem]) {
        let relocations = items.compactMap { item in
            item.trashInfo?.originalURL.map { Relocation(source: item.url, destination: $0) }
        }
        let unknown = items.count - relocations.count
        Task {
            if !relocations.isEmpty {
                await perform(.relocate(relocations))
            }
            if unknown > 0 {
                await inform(unknown == 1
                    ? "The original location of 1 item is unknown, so it can’t be restored."
                    : "The original location of \(unknown) items is unknown, so they can’t be restored.")
            }
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        Task {
            let oldExtension = (item.name as NSString).pathExtension.lowercased()
            let newExtension = (newName as NSString).pathExtension.lowercased()
            if item.kind == .file, !oldExtension.isEmpty, oldExtension != newExtension {
                let proceed = await confirm(
                    "If you change a file name extension, the file might become unusable.",
                    detail: "Are you sure you want to change it?",
                    button: "Change"
                )
                guard proceed else { return }
            }

            let result = await FileOperationCenter.shared.perform(.rename(item.url, to: newName))
            guard let failure = result.failures.first else {
                content.select(result.resultingItems)
                reload()
                return
            }
            switch failure.reason {
            case .alreadyExists:
                let folder = item.url.deletingLastPathComponent()
                let suggestion = FileNaming.uniqueName(newName, hasExtension: item.kind != .directory) {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
                let accepted = await confirm(
                    failure.message,
                    detail: "Do you want to rename “\(item.name)” to “\(suggestion)”?",
                    button: "Yes",
                    cancel: "No"
                )
                if accepted {
                    await perform(.rename(item.url, to: suggestion))
                } else {
                    content.beginRenaming(item.url)
                }
            case .invalidName:
                await inform(failure.message)
                content.beginRenaming(item.url)
            default:
                await inform(failure.message)
            }
        }
    }

    private func confirmPermanentDelete(of urls: [URL]) async -> Bool {
        let message = urls.count == 1
            ? "Are you sure you want to permanently delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to permanently delete these \(urls.count) items?"
        var detail = "You can’t undo this action."
        if let provider = cloudProvider(of: urls) {
            let them = urls.count == 1 ? "It" : "They"
            detail = "\(them) will also be deleted from \(provider) and from all your devices. " + detail
        }
        return await confirm(message, detail: detail, button: "Delete")
    }
}

// MARK: Validation

extension ExplorerTabController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selection = content.selectedItems
        let location = history.current
        let inFolder = currentFolder != nil
        let inRecycleBin = location == .recycleBin
        // Lists of real files: folders, search results and Home.
        let listsFiles = inFolder || inSearchResults || location == .home

        switch menuItem.action {
        case #selector(openSelection(_:)):
            return !selection.isEmpty && !inRecycleBin
        case #selector(cut(_:)), #selector(delete(_:)), #selector(deletePermanently(_:)):
            return !selection.isEmpty && (listsFiles || inRecycleBin)
        case #selector(copy(_:)):
            return !selection.isEmpty && listsFiles
        case #selector(paste(_:)):
            return inFolder && FileClipboard.shared.canPaste
        case #selector(renameSelection(_:)):
            return selection.count == 1 && (inFolder || inSearchResults)
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)):
            return inFolder
        case #selector(restoreSelection(_:)):
            return inRecycleBin && !selection.isEmpty
        case #selector(restoreAll(_:)), #selector(emptyRecycleBin(_:)):
            return inRecycleBin && !content.allItems.isEmpty
        default:
            return validateViewMenuItem(menuItem) ?? validateCommandMenuItem(menuItem)
                ?? validateSearchMenuItem(menuItem) ?? validateToolsMenuItem(menuItem)
                ?? validateCloudMenuItem(menuItem) ?? true
        }
    }
}

// MARK: Drag and drop

extension ExplorerTabController: FileDropHandling {
    /// Windows' Ctrl = copy and Shift = move, plus the Mac's Option = copy and Command = move.
    private static var currentIntent: DropPolicy.Intent {
        let flags = NSEvent.modifierFlags
        if flags.contains(.control) || flags.contains(.option) { return .forceCopy }
        if flags.contains(.shift) || flags.contains(.command) { return .forceMove }
        return .automatic
    }

    func dropOperation(
        for urls: [URL],
        into location: ExplorerLocation?,
        sourceMask: NSDragOperation
    ) -> NSDragOperation {
        let moveOperation: NSDragOperation = sourceMask.contains(.move) ? .move : sourceMask.intersection(.generic)
        switch location ?? history.current {
        case .recycleBin:
            let trashes = RecycleBin.trashDirectories().map(\.path)
            let alreadyTrashed = urls.allSatisfy { trashes.contains($0.deletingLastPathComponent().path) }
            return alreadyTrashed ? [] : moveOperation
        case .folder(let folder):
            switch DropPolicy.operation(for: urls, into: folder, intent: Self.currentIntent) {
            case .copy: return sourceMask.intersection(.copy)
            case .move: return moveOperation
            case nil: return []
            }
        default:
            return []
        }
    }

    func performDrop(of urls: [URL], into location: ExplorerLocation?, operation: NSDragOperation) {
        switch location ?? history.current {
        case .recycleBin:
            trash(urls)
        case .folder(let folder):
            let request: FileOperationRequest = operation == .copy
                ? .copy(urls, into: folder)
                : .move(urls, into: folder)
            Task { await perform(request) }
        default:
            break
        }
    }

    func canReceivePromises(into location: ExplorerLocation?) -> Bool {
        (location ?? history.current).fileURL != nil
    }

    func receivePromises(_ receivers: [NSFilePromiseReceiver], into location: ExplorerLocation?) {
        guard let folder = (location ?? history.current).fileURL else { return }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, operationQueue: Self.promiseQueue) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t receive a dropped file"
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }

    func trashDraggedItems(_ urls: [URL]) {
        trash(urls)
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()
}
