import AppKit

/// The row of icon buttons at the top of Windows 11's context menu (Cut, Copy, Rename, Share,
/// Delete). Each button closes the menu, then sends its action up the responder chain from
/// `source` (the view the menu was opened on). Buttons are enabled by the same validation as
/// menu items.
@MainActor
final class ContextMenuIconRow: NSView {
    struct Button {
        let symbol: String
        let title: String
        let action: Selector
    }

    private let buttons: [Button]
    private weak var source: NSView?

    static func item(buttons: [Button], from source: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ContextMenuIconRow(buttons: buttons, source: source)
        return item
    }

    private init(buttons: [Button], source: NSView) {
        self.buttons = buttons
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: 14 + CGFloat(buttons.count) * 40, height: 40))

        let target = { (action: Selector) in NSApp.target(forAction: action, to: nil, from: source) }
        for (index, button) in buttons.enumerated() {
            let view = FluentButton(symbol: button.symbol, toolTip: button.title)
            view.frame = NSRect(x: 10 + CGFloat(index) * 40, y: 4, width: 36, height: 32)
            view.tag = index
            view.target = self
            view.action = #selector(buttonClicked(_:))
            let probe = NSMenuItem(title: button.title, action: button.action, keyEquivalent: "")
            let validator = target(button.action) as? NSMenuItemValidation
            view.isEnabled = validator?.validateMenuItem(probe) ?? (target(button.action) != nil)
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard buttons.indices.contains(sender.tag) else { return }
        let action = buttons[sender.tag].action
        let source = self.source
        enclosingMenuItem?.menu?.cancelTracking()
        // After the menu has closed, so sheets and popovers attach to the window.
        DispatchQueue.main.async {
            NSApp.sendAction(action, to: nil, from: source)
        }
    }
}
