import AppKit
import ExplorerCore

/// A group's header, e.g. "⌄ Today (4) ─────". The chevron collapses or expands the group;
/// clicking the title selects the group's items, as on Windows. Used as a Details-view group
/// row and as an icon-view section header.
final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let height: CGFloat = 30
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeader")

    var onToggle: (() -> Void)?
    var onSelect: (() -> Void)?

    private let chevron = NSButton()
    private let titleButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        titleButton.isBordered = false
        titleButton.target = self
        titleButton.action = #selector(select)
        titleButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(chevron)
        addSubview(titleButton)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            titleButton.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(group: FileGroup, isCollapsed: Bool) {
        let symbol = isCollapsed ? "chevron.right" : "chevron.down"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isCollapsed ? "Expand" : "Collapse")
        chevron.contentTintColor = .secondaryLabelColor
        let title = NSMutableAttributedString(string: group.title, attributes: [
            .font: Theme.font(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: " (\(group.items.count))", attributes: [
            .font: Theme.font(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        titleButton.attributedTitle = title
        setAccessibilityLabel("\(group.title), \(group.items.count) items")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = titleButton.frame.maxX + 8
        guard start < bounds.maxX - 8 else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: start, y: bounds.midY.rounded(), width: bounds.maxX - 8 - start, height: 1).fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    @objc private func toggle() {
        onToggle?()
    }

    @objc private func select() {
        onSelect?()
    }
}
