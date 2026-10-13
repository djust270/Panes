import AppKit
import ExplorerCore

/// One item in the icon, List, Tiles or Content view.
final class FileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileCollectionItem")

    /// The item's checkbox was clicked.
    var onToggleCheckbox: ((FileCollectionItem) -> Void)?
    /// The URL the item currently shows, for matching late thumbnails.
    private(set) var fileURL: URL?

    private var itemView: FileItemView {
        view as! FileItemView // swiftlint:disable:this force_cast
    }

    override func loadView() {
        let itemView = FileItemView()
        view = itemView
        imageView = itemView.iconView
        textField = itemView.nameField
        itemView.checkbox.target = self
        itemView.checkbox.action = #selector(checkboxClicked)
    }

    var showsCheckbox: Bool {
        get { itemView.showsCheckbox }
        set { itemView.showsCheckbox = newValue }
    }

    override var isSelected: Bool {
        didSet { itemView.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { itemView.isDropTarget = highlightState == .asDropTarget }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        fileURL = nil
        itemView.isHovered = false
        itemView.isDropTarget = false
        itemView.alphaValue = 1
    }

    func configure(
        with item: FileItem,
        mode: ViewMode,
        image: NSImage,
        details: ItemDetailText,
        isCut: Bool
    ) {
        fileURL = item.url.standardizedFileURL
        itemView.viewMode = mode
        itemView.iconView.image = image
        itemView.nameField.stringValue = item.name
        itemView.setDetails(details)
        itemView.alphaValue = isCut ? 0.45 : 1
        itemView.isSelected = isSelected
    }

    func setImage(_ image: NSImage, for url: URL) {
        guard url == fileURL else { return }
        itemView.iconView.image = image
    }

    @objc private func checkboxClicked() {
        onToggleCheckbox?(self)
    }
}

/// The secondary lines of a Tiles or Content item.
struct ItemDetailText {
    var line2 = ""
    var line3 = ""
    var right1 = ""
    var right2 = ""
    /// A drive's used space (0…1), drawn as a capacity bar in place of `line2`.
    var capacity: Double?
    /// Draws the capacity bar red, as Windows does for a nearly full drive.
    var capacityIsLow = false
}

/// Draws an item: a rounded selection/hover highlight, the icon, the name and (Tiles,
/// Content) detail lines, laid out by hand for each view mode.
final class FileItemView: NSView {
    let iconView = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let line2 = FileItemView.detailLabel()
    private let line3 = FileItemView.detailLabel()
    private let right1 = FileItemView.detailLabel()
    private let right2 = FileItemView.detailLabel()
    private let capacityBar = CapacityBarView()

    var viewMode: ViewMode = .mediumIcons {
        didSet {
            guard viewMode != oldValue else { return }
            applyMode()
        }
    }

    var isSelected = false { didSet { stateChanged() } }
    var isHovered = false { didSet { stateChanged() } }
    var isDropTarget = false { didSet { stateChanged() } }
    var showsCheckbox = false { didSet { stateChanged() } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameField.font = Theme.font(ofSize: 12)
        nameField.cell?.truncatesLastVisibleLine = true
        checkbox.isHidden = true
        capacityBar.isHidden = true
        for subview in [iconView, nameField, line2, line3, right1, right2, capacityBar, checkbox] {
            addSubview(subview)
        }
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setDetails(_ details: ItemDetailText) {
        line2.stringValue = details.line2
        line3.stringValue = details.line3
        right1.stringValue = details.right1
        right2.stringValue = details.right2
        capacityBar.fraction = details.capacity ?? 0
        capacityBar.isLow = details.capacityIsLow
        capacityBar.isHidden = details.capacity == nil || viewMode != .tiles
        line2.isHidden = !capacityBar.isHidden || (viewMode != .tiles && viewMode != .content && viewMode != .details)
    }

    private static func detailLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = Theme.font(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func applyMode() {
        let isGrid = viewMode.isIconGrid
        nameField.alignment = isGrid ? .center : .left
        nameField.maximumNumberOfLines = isGrid ? 2 : 1
        nameField.lineBreakMode = isGrid ? .byWordWrapping : .byTruncatingMiddle
        nameField.cell?.wraps = isGrid
        line2.isHidden = viewMode != .tiles && viewMode != .content && viewMode != .details
        line3.isHidden = viewMode != .tiles
        right1.isHidden = viewMode != .content && viewMode != .details
        right2.isHidden = viewMode != .content
        needsLayout = true
        needsDisplay = true
    }

    private func stateChanged() {
        checkbox.isHidden = !showsCheckbox || !(isSelected || isHovered)
        checkbox.state = isSelected ? .on : .off
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let icon = viewMode.iconSize
        let inset: CGFloat = showsCheckbox && !viewMode.isIconGrid ? 20 : 0
        checkbox.frame = NSRect(x: 4, y: viewMode.isIconGrid ? 4 : (height - 16) / 2, width: 16, height: 16)

        switch viewMode {
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            iconView.frame = NSRect(x: (width - icon) / 2, y: 6, width: icon, height: icon)
            let top = 6 + icon + 4
            nameField.frame = NSRect(x: 4, y: top, width: width - 8, height: max(0, height - top - 2))
        case .smallIcons, .list:
            iconView.frame = NSRect(x: 4 + inset, y: (height - 16) / 2, width: 16, height: 16)
            nameField.frame = NSRect(x: 24 + inset, y: (height - 16) / 2, width: width - 28 - inset, height: 16)
        case .details:
            // Home's rows: Name | date | folder, like Windows' Recent list.
            let x = 30 + inset
            iconView.frame = NSRect(x: 8 + inset, y: (height - 16) / 2, width: 16, height: 16)
            let nameWidth = max(140, (width - x) * 0.45)
            nameField.frame = NSRect(x: x, y: (height - 16) / 2, width: nameWidth - 12, height: 16)
            right1.frame = NSRect(x: x + nameWidth, y: (height - 15) / 2, width: 140, height: 15)
            let folderX = x + nameWidth + 150
            line2.frame = NSRect(x: folderX, y: (height - 15) / 2, width: max(0, width - folderX - 8), height: 15)
        case .tiles:
            iconView.frame = NSRect(x: 6 + inset, y: (height - icon) / 2, width: icon, height: icon)
            let x = 60 + inset
            let top = (height - 46) / 2
            nameField.frame = NSRect(x: x, y: top, width: width - x - 4, height: 16)
            line2.frame = NSRect(x: x, y: top + 16, width: width - x - 4, height: 15)
            line3.frame = NSRect(x: x, y: top + 31, width: width - x - 4, height: 15)
            capacityBar.frame = NSRect(x: x, y: top + 20, width: max(0, min(200, width - x - 12)), height: 8)
        case .content:
            iconView.frame = NSRect(x: 8 + inset, y: (height - icon) / 2, width: icon, height: icon)
            let x = 58 + inset
            let split = max(x + 120, width * 0.55)
            nameField.frame = NSRect(x: x, y: height / 2 - 17, width: split - x - 12, height: 16)
            line2.frame = NSRect(x: x, y: height / 2 + 1, width: split - x - 12, height: 15)
            right1.frame = NSRect(x: split, y: height / 2 - 16, width: max(0, width - split - 8), height: 15)
            right2.frame = NSRect(x: split, y: height / 2 + 1, width: max(0, width - split - 8), height: 15)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: highlight, xRadius: 4, yRadius: 4)
        if isDropTarget {
            Theme.accent.withAlphaComponent(0.35).setFill()
            path.fill()
        } else if isSelected {
            Theme.selectionColor(emphasized: true, hovered: isHovered).setFill()
            path.fill()
        } else if isHovered {
            Theme.hoverColor.setFill()
            path.fill()
        }
        if viewMode == .content {
            NSColor.separatorColor.setFill()
            NSRect(x: 8, y: bounds.maxY - 1, width: bounds.width - 16, height: 1).fill()
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

/// A drive's capacity bar: used space in the accent colour, or red when nearly full.
final class CapacityBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var isLow = false { didSet { needsDisplay = true } }

    private static let trackColor = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.1),
        dark: NSColor(white: 1, alpha: 0.14)
    )
    /// Windows' "critical" red.
    private static let lowColor = NSColor(hex: 0xC42B1C)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Self.trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var used = bounds
        used.size.width = max(bounds.height, bounds.width * CGFloat(fraction))
        (isLow ? Self.lowColor : Theme.accent).setFill()
        NSBezierPath(roundedRect: used, xRadius: radius, yRadius: radius).fill()
    }
}
