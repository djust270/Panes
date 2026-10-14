import AppKit

/// Keyboard focus between the tab's areas.
extension ExplorerTabController {
    /// F6 / Shift+F6, as on Windows: the address bar, search box, navigation pane and file
    /// list in turn.
    @objc func focusNextPane(_ sender: Any?) {
        cycleFocus(by: 1)
    }

    @objc func focusPreviousPane(_ sender: Any?) {
        cycleFocus(by: -1)
    }

    private func cycleFocus(by step: Int) {
        let regions = rootViewController.focusRegions
        guard let window = view.window, !regions.isEmpty else { return }
        var responder = window.firstResponder as? NSView
        // While a text field is edited, the field editor has focus on its behalf.
        if let editor = responder as? NSText, editor.isFieldEditor { responder = editor.delegate as? NSView }
        let current = responder.flatMap { responder in
            regions.firstIndex { responder === $0 || responder.isDescendant(of: $0) }
        }
        let next = current.map { ($0 + step + regions.count) % regions.count } ?? (step > 0 ? 0 : regions.count - 1)
        switch regions[next] {
        case addressBar.breadcrumbBar: addressBar.beginEditing()
        case addressBar.searchKeyView: addressBar.focusSearch()
        default: window.makeFirstResponder(regions[next])
        }
    }

    /// Puts keyboard focus in the file list (after the tab is shown).
    func focusContent() {
        view.window?.makeFirstResponder(content.activeView)
    }
}
