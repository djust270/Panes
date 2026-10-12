import AppKit
import ExplorerCore

/// Rename in place (F2): the Name cell becomes editable with the name, minus its extension,
/// selected. Return, Tab or clicking elsewhere commits; Escape cancels.
extension ContentViewController: NSTextFieldDelegate {
    var isRenaming: Bool { renaming != nil }

    func beginRenamingSelection() {
        guard let item = selectedItems.first else { return }
        beginRenaming(item.url)
    }

    func beginRenaming(_ url: URL) {
        finishRenaming(commit: true)
        guard mode == .folder,
              let row = sortedItems.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
        else { return }
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        guard column >= 0 else { return }

        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }

        let item = sortedItems[row]
        renaming = (item, field)
        cell.alphaValue = 1
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.lineBreakMode = .byClipping
        field.delegate = self
        view.window?.makeFirstResponder(field)

        let hasExtension = item.kind != .directory
        field.currentEditor()?.selectedRange = FileNaming.renameSelection(for: item.name, hasExtension: hasExtension)
    }

    /// Ends any rename in progress. Committing reports the new name through `onRename`.
    func finishRenaming(commit: Bool) {
        guard let (item, field) = renaming else { return }
        let newName = field.currentEditor()?.string ?? field.stringValue
        renaming = nil

        if view.window?.firstResponder === field.currentEditor() {
            view.window?.makeFirstResponder(tableView)
        }
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = nil
        field.stringValue = item.name

        if commit, newName != item.name {
            onRename?(item, newName)
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
