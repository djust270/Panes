import AppKit
import ExplorerCore

/// An in-place rename: the item's name label, temporarily made editable.
struct RenameSession {
    let item: FileItem
    let field: NSTextField
    /// The label's line breaking, restored afterwards.
    let lineBreakMode: NSLineBreakMode
}

/// Rename in place (F2): the item's name label becomes editable with the name, minus its
/// extension, selected. Return, Tab or clicking elsewhere commits; Escape cancels. Works in
/// every view mode.
extension ContentViewController: NSTextFieldDelegate {
    var isRenaming: Bool { renaming != nil }

    func beginRenamingSelection() {
        guard let item = selectedItems.first else { return }
        beginRenaming(item.url)
    }

    func beginRenaming(_ url: URL) {
        finishRenaming(commit: true)
        guard mode == .folder,
              let item = listContent.allItems.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              let (field, container) = nameField(for: item) else { return }

        renaming = RenameSession(item: item, field: field, lineBreakMode: field.lineBreakMode)
        container.alphaValue = 1
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        if field.maximumNumberOfLines == 1 { field.lineBreakMode = .byClipping }
        field.delegate = self
        view.window?.makeFirstResponder(field)

        let hasExtension = item.kind != .directory
        field.currentEditor()?.selectedRange = FileNaming.renameSelection(for: item.name, hasExtension: hasExtension)
    }

    /// Selects and reveals `item`, returning its name label and the view to un-dim.
    private func nameField(for item: FileItem) -> (NSTextField, NSView)? {
        let url = item.url.standardizedFileURL
        if isDetailsMode {
            guard let row = listContent.row(of: url), nameColumnIndex >= 0 else { return nil }
            setSelection([url], scroll: true)
            let cell = tableView.view(atColumn: nameColumnIndex, row: row, makeIfNecessary: true) as? NSTableCellView
            guard let cell, let field = cell.textField else { return nil }
            return (field, cell)
        }
        guard let position = listContent.position(of: url) else { return nil }
        let indexPath = IndexPath(item: position.index, section: position.section)
        setSelection([url], scroll: true)
        collectionView.layoutSubtreeIfNeeded()
        guard let cell = collectionView.item(at: indexPath) as? FileCollectionItem,
              let field = cell.textField else { return nil }
        return (field, cell.view)
    }

    /// Ends any rename in progress. Committing reports the new name through `onRename`.
    func finishRenaming(commit: Bool) {
        guard let session = renaming else { return }
        let field = session.field
        let newName = field.currentEditor()?.string ?? field.stringValue
        renaming = nil

        if view.window?.firstResponder === field.currentEditor() {
            view.window?.makeFirstResponder(activeView)
        }
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = session.lineBreakMode
        field.delegate = nil
        field.stringValue = session.item.name

        if commit, newName != session.item.name {
            onRename?(session.item, newName)
        }
        if let deferred = deferredItems {
            deferredItems = nil
            setItems(deferred)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renaming?.field else { return }
        finishRenaming(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renaming?.field else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            finishRenaming(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            finishRenaming(commit: true)
            return true
        default:
            return false
        }
    }
}
