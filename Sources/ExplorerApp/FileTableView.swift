import AppKit

/// Keys shared by the Details table and the icon views: Return/Enter opens the selection, the
/// forward-delete key (Del on PC keyboards) deletes, and Shift+Del deletes permanently, as on
/// Windows.
@MainActor
enum FileViewKeys {
    /// Virtual key codes (see `HIToolbox/Events.h`; hardcoded to avoid pulling in the Carbon
    /// module for three constants).
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let forwardDeleteKeyCode: UInt16 = 117

    /// Returns `true` if the event was handled.
    static func handle(_ event: NSEvent, from sender: NSView, activate: (() -> Void)?) -> Bool {
        switch event.keyCode {
        case returnKeyCode, keypadEnterKeyCode:
            activate?()
            return true
        case forwardDeleteKeyCode:
            let action = event.modifierFlags.contains(.shift)
                ? #selector(ExplorerWindowController.deletePermanently(_:))
                : #selector(ExplorerWindowController.delete(_:))
            NSApp.sendAction(action, to: nil, from: sender)
            return true
        default:
            return false
        }
    }
}

/// The Details view's table. Adds Windows' rubber-band selection: dragging from empty space,
/// or from any column but Name, draws a selection rectangle; dragging a name drags the files.
final class FileTableView: NSTableView {
    var onActivateSelection: (() -> Void)?
    /// Limits a selection to rows that hold items (not group headers).
    var selectableRows: ((IndexSet) -> IndexSet)?
    /// The column where a drag moves files instead of starting a rubber band.
    var dragColumnIdentifier: NSUserInterfaceItemIdentifier?

    override func keyDown(with event: NSEvent) {
        if !FileViewKeys.handle(event, from: self, activate: onActivateSelection) {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        let onDragColumn = column >= 0 && tableColumns[column].identifier == dragColumnIdentifier
        let isHeader = row >= 0 && delegate?.tableView?(self, isGroupRow: row) == true
        guard event.clickCount == 1, !isHeader, row < 0 || !onDragColumn, selectableRows != nil else {
            super.mouseDown(with: event)
            return
        }
        trackRubberBand(from: event, startRow: row)
    }

    /// Runs the mouse-tracking loop: a click without movement selects like a normal click; a drag
    /// selects every row the rectangle touches (added to the existing selection with ⌘ or ⇧).
    private func trackRubberBand(from event: NSEvent, startRow: Int) {
        window?.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        let initialSelection = selectedRowIndexes
        var band: RubberBandView?
        defer { band?.removeFromSuperview() }

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if band == nil { click(row: startRow, modifiers: modifiers) }
                return
            }
            if band == nil {
                guard hypot(point.x - start.x, point.y - start.y) > 3 else { continue }
                let view = RubberBandView()
                addSubview(view)
                band = view
            }
            autoscroll(with: next)
            let rect = NSRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
            band?.frame = rect
            let range = rows(in: rect)
            var rows = IndexSet(integersIn: range.location..<range.location + range.length)
            rows = selectableRows?(rows) ?? rows
            selectRowIndexes(modifiers.isEmpty ? rows : rows.union(initialSelection), byExtendingSelection: false)
        }
    }

    private func click(row: Int, modifiers: NSEvent.ModifierFlags) {
        guard row >= 0 else {
            if modifiers.isEmpty { deselectAll(nil) }
            return
        }
        if modifiers.contains(.command) {
            if isRowSelected(row) {
                deselectRow(row)
            } else {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
        } else if modifiers.contains(.shift), selectedRow >= 0 {
            let anchor = selectedRowIndexes.first ?? row
            let range = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
            selectRowIndexes(selectableRows?(range) ?? range, byExtendingSelection: false)
        } else {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}

/// The translucent rectangle drawn during a rubber-band selection.
final class RubberBandView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    }
}
