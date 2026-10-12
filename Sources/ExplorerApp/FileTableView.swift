import AppKit

/// Keys shared by the Details table and the icon views: Return/Enter opens the selection, the
/// forward-delete key (Del on PC keyboards) deletes, Shift+Del deletes permanently, Backspace
/// goes back (Windows scheme), and typing a name selects it (type-ahead), as on Windows.
@MainActor
enum FileViewKeys {
    /// Virtual key codes (see `HIToolbox/Events.h`; hardcoded to avoid pulling in the Carbon
    /// module for a few constants).
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let forwardDeleteKeyCode: UInt16 = 117
    private static let backspaceKeyCode: UInt16 = 51

    /// Returns `true` if the event was handled.
    static func handle(
        _ event: NSEvent,
        from sender: NSView,
        activate: (() -> Void)?,
        typeAhead: ((String) -> Bool)?
    ) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case returnKeyCode, keypadEnterKeyCode:
            guard modifiers.isEmpty else { return false }
            activate?()
            return true
        case forwardDeleteKeyCode:
            let action = modifiers.contains(.shift)
                ? #selector(ExplorerTabController.deletePermanently(_:))
                : #selector(ExplorerTabController.delete(_:))
            NSApp.sendAction(action, to: nil, from: sender)
            return true
        case backspaceKeyCode where modifiers.isEmpty && KeyboardShortcuts.scheme.backspaceGoesBack:
            NSApp.sendAction(#selector(ExplorerTabController.goBack(_:)), to: nil, from: sender)
            return true
        default:
            guard modifiers.subtracting(.shift).isEmpty,
                  let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            return typeAhead?(text) ?? false
        }
    }
}

/// The Details view's table. Adds Windows' rubber-band selection: dragging from empty space,
/// or from any column but Name, draws a selection rectangle; dragging a name drags the files.
final class FileTableView: NSTableView {
    var onActivateSelection: (() -> Void)?
    var onTypeAhead: ((String) -> Bool)?
    /// Middle-click on a row.
    var onMiddleClick: ((Int) -> Void)?
    /// Limits a selection to rows that hold items (not group headers).
    var selectableRows: ((IndexSet) -> IndexSet)?
    /// The column where a drag moves files instead of starting a rubber band.
    var dragColumnIdentifier: NSUserInterfaceItemIdentifier?

    override func keyDown(with event: NSEvent) {
        if !FileViewKeys.handle(event, from: self, activate: onActivateSelection, typeAhead: onTypeAhead) {
            super.keyDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0 {
            onMiddleClick?(row)
        } else {
            super.otherMouseUp(with: event)
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
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.15).cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.8).cgColor
    }
}

/// Windows 11 list selection: a rounded, lightly tinted fill inset from the edges, with the
/// text left in its normal colour; and a subtle highlight under the mouse.
final class ExplorerRowView: NSTableRowView {
    /// The navigation pane uses a neutral grey instead of the accent colour.
    var usesNeutralSelection = false
    private var isHovered = false { didSet { needsDisplay = true } }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let fill = usesNeutralSelection
            ? Theme.navigationSelectionColor
            : Theme.selectionColor(emphasized: isEmphasized, hovered: isHovered)
        fill.setFill()
        selectionPath.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered, !isSelected, !isGroupRowStyle {
            Theme.hoverColor.setFill()
            selectionPath.fill()
        }
    }

    private var selectionPath: NSBezierPath {
        // Adjacent selected rows merge into one block, as on Windows.
        let rect = bounds.insetBy(dx: 4, dy: 0)
        var top: CGFloat = isPreviousRowSelected ? 0 : 1
        var bottom: CGFloat = isNextRowSelected ? 0 : 1
        if usesNeutralSelection { top = 1; bottom = 1 }
        let inset = NSRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: rect.height - top - bottom)
        return NSBezierPath(roundedRect: inset, xRadius: Theme.controlCornerRadius, yRadius: Theme.controlCornerRadius)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}
