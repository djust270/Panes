import AppKit
import ExplorerCore

/// Drag and drop: items drag out as file URLs (to Finder, other apps, or other windows), and
/// files or file promises can be dropped onto folder items or the view's background. The
/// table and the collection view share the same rules.
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
        guard listsFiles, !isRenaming, let item = listContent.item(atRow: row) else { return nil }
        return item.url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        draggingSessionEnded(session, operation: operation)
    }

    private func draggingSessionEnded(_ session: NSDraggingSession, operation: NSDragOperation) {
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
        let target = dropOperation == .on ? dropTarget(listContent.item(atRow: row)) : nil
        if target == nil {
            // Highlight the whole view: the drop goes into the folder being shown.
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return validateDrop(info, into: target)
    }

    private func validateDrop(_ info: NSDraggingInfo, into target: ExplorerLocation?) -> NSDragOperation {
        guard let dropHandler, listsFiles else { return [] }
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
        let target = dropOperation == .on ? dropTarget(listContent.item(atRow: row)) : nil
        return acceptDrop(info, into: target)
    }

    private func acceptDrop(_ info: NSDraggingInfo, into target: ExplorerLocation?) -> Bool {
        guard let dropHandler else { return false }
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

    /// The folder under the drop, or `nil` for the folder being shown.
    private func dropTarget(_ item: FileItem?) -> ExplorerLocation? {
        guard mode == .folder, let item, item.isFolder else { return nil }
        return .folder(item.url)
    }

    // MARK: Collection view

    func configureCollectionDragAndDrop() {
        collectionView.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        canDragItemsAt indexPaths: Set<IndexPath>,
        with event: NSEvent
    ) -> Bool {
        listsFiles && !isRenaming
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard listsFiles, !isRenaming,
              let item = listContent.item(section: indexPath.section, index: indexPath.item) else { return nil }
        return item.url as NSURL
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        dragOperation operation: NSDragOperation
    ) {
        draggingSessionEnded(session, operation: operation)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        let item = listContent.item(section: indexPath.section, index: indexPath.item)
        let target = proposedDropOperation.pointee == .on ? dropTarget(item) : nil
        if target == nil {
            // Not onto a folder: the drop goes into the folder being shown.
            proposedDropOperation.pointee = .before
        }
        return validateDrop(draggingInfo, into: target)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let item = listContent.item(section: indexPath.section, index: indexPath.item)
        return acceptDrop(draggingInfo, into: dropOperation == .on ? dropTarget(item) : nil)
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
