import AppKit

/// `NSTableView` subclass that treats Return/Enter as "open the selection," the same way
/// double-click does, without disturbing normal arrow-key row navigation. The forward-delete
/// key (Del on PC keyboards) deletes, and Shift+Del deletes permanently, as on Windows.
final class FileTableView: NSTableView {
    var onActivateSelection: (() -> Void)?

    /// Virtual key codes for Return and the numeric keypad's Enter (see `HIToolbox/Events.h`;
    /// hardcoded to avoid pulling in the Carbon module for two constants).
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let forwardDeleteKeyCode: UInt16 = 117

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.returnKeyCode, Self.keypadEnterKeyCode:
            onActivateSelection?()
        case Self.forwardDeleteKeyCode:
            let action = event.modifierFlags.contains(.shift)
                ? #selector(ExplorerWindowController.deletePermanently(_:))
                : #selector(ExplorerWindowController.delete(_:))
            NSApp.sendAction(action, to: nil, from: self)
        default:
            super.keyDown(with: event)
        }
    }
}
