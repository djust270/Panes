import AppKit
import ExplorerCore

/// Cloud folders (OneDrive, iCloud Drive…): sync status, "Download now" and "Free up space",
/// and the warning that deleting there deletes in the cloud too.
extension ExplorerTabController {
    // MARK: Status

    /// Asks the File Provider about items in a cloud folder that might be syncing (the listing
    /// only tells online-only from downloaded), and looks again every few seconds while any are:
    /// uploads finishing don't change the folder, so FSEvents doesn't say. Items "Download now"
    /// is still fetching show as syncing.
    func refineCloudStatus(of items: [FileItem]) async throws {
        guard items.contains(where: { $0.cloudStatus != nil }) || !cloudDownloads.isEmpty else { return }
        var refined = await Task.detached(priority: .utility) { CloudStatusReader.refined(items) }.value
        try Task.checkCancellation()
        for index in refined.indices where cloudDownloads.contains(refined[index].url) {
            let item = refined[index]
            if item.isOnlineOnly || item.isFolder, item.cloudStatus != .error { refined[index].cloudStatus = .syncing }
        }
        if refined != items { content.setItems(refined) }
        guard refined.contains(where: { $0.cloudStatus == .syncing }) else { return }
        try await Task.sleep(for: .seconds(3))
        reload()
    }

    // MARK: Commands

    /// "Download now": downloads the selected online-only files, and everything in selected
    /// folders, with the progress dialog. No "Always keep on this device": sync clients don't
    /// let other apps set it.
    @objc func downloadNow(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if currentFolder != nil {
            cloudDownloads.formUnion(urls)
            reload()
        }
        Task {
            await perform(.download(urls))
            cloudDownloads.subtract(urls)
            if currentFolder != nil { reload() }
        }
    }

    /// "Free up space": keeps only placeholders of the selected items, downloaded again when
    /// opened.
    @objc func freeUpSpace(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        Task {
            let failures = await Task.detached(priority: .userInitiated) { CloudSync.freeUpSpace(urls) }.value
            if currentFolder != nil { reload() }
            guard let first = failures.first else { return }
            let message = failures.count == 1
                ? "Couldn’t free up space for “\(first.url.lastPathComponent)”."
                : "Couldn’t free up space for \(failures.count) items."
            await inform("\(message) \(first.error.localizedDescription)")
        }
    }

    /// Whether every selected item is in a cloud folder, where Download now and Free up space
    /// apply.
    var selectionIsInCloud: Bool {
        let selection = content.selectedItems
        return !selection.isEmpty && selection.allSatisfy {
            $0.cloudStatus != nil || CloudStorage.isInCloudFolder($0.url)
                || showsCloudFolder && currentFolder != nil && !inSearchResults
        }
    }

    // Validates the commands above; `nil` for anything else.
    func validateCloudMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        let selection = content.selectedItems
        switch menuItem.action {
        case #selector(downloadNow(_:)):
            return selectionIsInCloud && selection.contains { $0.isFolder || $0.isOnlineOnly }
        case #selector(freeUpSpace(_:)):
            return selectionIsInCloud && selection.contains { $0.isFolder || !$0.isOnlineOnly }
        default:
            return nil
        }
    }

    // MARK: Deleting

    /// The cloud that deleting `urls` would delete from, if any ("OneDrive - Contoso").
    func cloudProvider(of urls: [URL]) -> String? {
        var checked = Set<String>()
        for url in urls {
            let folder = url.deletingLastPathComponent()
            guard checked.insert(folder.path).inserted, CloudStatusReader.isCloudFolder(folder) else { continue }
            return CloudSync.providerName(for: url) ?? "the cloud"
        }
        return nil
    }

    /// OneDrive's "Deleted files are removed everywhere": deleting from a cloud folder deletes
    /// in the cloud and on the user's other devices. True to go ahead. Asks until "Don't show
    /// this again", except that online-only items, which are deleted outright rather than moved
    /// to the Recycle Bin, are always asked about.
    func confirmCloudDelete(of urls: [URL]) async -> Bool {
        guard let provider = cloudProvider(of: urls) else { return true }
        let outright = await Task.detached(priority: .userInitiated) {
            urls.filter(CloudSync.hasOnlineOnlyContents)
        }.value
        guard AppSettings.warnsBeforeCloudDelete || !outright.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "Deleted files are removed everywhere"
        var detail = urls.count == 1
            ? "“\(urls[0].lastPathComponent)” will be deleted from \(provider) and from all your devices."
            : "These \(urls.count) items will be deleted from \(provider) and from all your devices."
        if !outright.isEmpty {
            detail += " " + Self.onlineOnlyNote(outright, of: urls.count)
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = outright.isEmpty
        alert.suppressionButton?.title = "Don’t show this again"
        guard await present(alert) == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { AppSettings.warnsBeforeCloudDelete = false }
        return true
    }

    /// Why some items can't come back from the Recycle Bin.
    private static func onlineOnlyNote(_ outright: [URL], of count: Int) -> String {
        let isFolder = outright.count == 1
            && (try? outright[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let restore = "so it can’t be restored from the Recycle Bin."
        switch (count, outright.count) {
        case (1, _):
            return isFolder ? "It holds files that are only online, \(restore)" : "It’s only online, \(restore)"
        case (_, 1):
            let what = isFolder ? "holds files that are only online" : "is only online"
            return "“\(outright[0].lastPathComponent)” \(what), \(restore)"
        default:
            let some = outright.count == count ? "They" : "\(outright.count) of them"
            return "\(some) are only online or hold online-only files, so they can’t be restored from the Recycle Bin."
        }
    }
}
