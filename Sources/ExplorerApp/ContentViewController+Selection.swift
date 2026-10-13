import AppKit
import ExplorerCore

/// Selection commands: Select all / none, Invert selection, and item checkboxes.
extension ContentViewController {
    func selectAllItems() {
        setSelection(Set(listContent.sections.flatMap(\.items).map(\.url.standardizedFileURL)), scroll: false)
    }

    func selectNone() {
        setSelection([], scroll: false)
    }

    func invertSelection() {
        let selected = selectedURLs
        let visible = listContent.sections.flatMap(\.items).map(\.url.standardizedFileURL)
        setSelection(Set(visible.filter { !selected.contains($0) }), scroll: false)
    }

    /// Toggles one item without touching the rest of the selection (item checkboxes).
    func toggleSelection(of url: URL) {
        var selection = selectedURLs
        let key = url.standardizedFileURL
        if selection.contains(key) {
            selection.remove(key)
        } else {
            selection.insert(key)
        }
        setSelection(selection, scroll: false)
        view.window?.makeFirstResponder(activeView)
    }
}
