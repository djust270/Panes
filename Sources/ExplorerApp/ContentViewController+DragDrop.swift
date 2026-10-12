import AppKit
import ExplorerCore

/// Drag and drop: rows drag out as file URLs (to Finder, other apps, or other windows), and
/// files or file promises can be dropped onto folder rows or the view's background.
extension ContentViewController {
    func configureDragAndDrop() {
        tableView.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard mode != .volumes, sortedItems.indices.contains(row), !isRenaming else { return nil }
        return sortedItems[row].url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard operation == .delete else { return }
        let urls = session.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        dropHandler?.trashDraggedItems(urls)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let dropHandler, mode != .volumes else { return [] }
        let target = dropTarget(row: row, dropOperation: dropOperation)
        if target == nil {
            // Highlight the whole view: the drop goes into the folder being shown.
            tableView.setDropRow(-1, dropOperation: .on)
        }

        if let urls = Self.fileURLs(in: info.draggingPasteboard) {
            return dropHandler.dropOperation(for: urls, into: target, sourceMask: info.draggingSourceOperationMask)
        }
        if Self.hasPromises(info.draggingPasteboard), dropHandler.canReceivePromises(into: target) {
            return .copy
        }
        return []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let dropHandler else { return false }
        let target = dropTarget(row: row, dropOperation: dropOperation)
        if let urls = Self.fileURLs(in: info.draggingPasteboard) {
            let mask = info.draggingSourceOperationMask
            let operation = dropHandler.dropOperation(for: urls, into: target, sourceMask: mask)
            guard !operation.isEmpty else { return false }
            dropHandler.performDrop(of: urls, into: target, operation: operation)
            return true
        }
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
        guard let receivers = objects as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }
        dropHandler.receivePromises(receivers, into: target)
        return true
    }

    /// The folder row under the drop, or `nil` for the folder being shown.
    private func dropTarget(row: Int, dropOperation: NSTableView.DropOperation) -> ExplorerLocation? {
        guard dropOperation == .on, mode == .folder, sortedItems.indices.contains(row) else { return nil }
        let item = sortedItems[row]
        return item.isFolder ? .folder(item.url) : nil
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls.map(\.standardizedFileURL)
    }

    static func hasPromises(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }
}
