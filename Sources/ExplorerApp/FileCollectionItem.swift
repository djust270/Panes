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
        fileURL = item.url
        itemView.viewMode = mode
        itemView.iconView.image = image
        itemView.nameField.stringValue = item.displayName(showingExtensions: AppSettings.showsFileExtensions)
        itemView.setDetails(details)
        itemView.kindDescription = item.typeDescription
        itemView.cloudStatus = item.cloudStatus
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
/// Content) detail lines, laid out by hand for each view mode. In Windows 98 style only the
/// name is highlighted, navy with white text.
final class FileItemView: NSView {
    let iconView = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let line2 = FileItemView.detailLabel()
    private let line3 = FileItemView.detailLabel()
    private let right1 = FileItemView.detailLabel()
    private let right2 = FileItemView.detailLabel()
    private let capacityBar = CapacityBarView()
    /// The sync-state glyph over the icon's corner, in cloud folders.
    private let statusBadge = NSImageView()

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
    /// "Folder", "JPEG image"…: what VoiceOver calls the item.
    var kindDescription = ""
    var cloudStatus: CloudStatus? {
        didSet {
            guard cloudStatus != oldValue else { return }
            statusBadge.image = cloudStatus.flatMap { CloudStatusGlyph.image(for: $0, pointSize: 10) }
            statusBadge.toolTip = cloudStatus?.title
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    // VoiceOver reads an item as one element: "report, PDF document, 12/10/2026, 1.2 MB".

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityRoleDescription() -> String? { kindDescription }

    override func accessibilityLabel() -> String? { nameField.stringValue }

    override func accessibilityValue() -> Any? {
        let details = [line2, line3, right1, right2].filter { !$0.isHidden && !$0.stringValue.isEmpty }
        return (details.map(\.stringValue) + [cloudStatus?.title].compactMap { $0 }).joined(separator: ", ")
    }

    override func isAccessibilitySelected() -> Bool { isSelected }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameField.cell?.truncatesLastVisibleLine = true
        checkbox.isHidden = true
        checkbox.setAccessibilityLabel("Select")
        capacityBar.isHidden = true
        statusBadge.wantsLayer = true
        statusBadge.imageScaling = .scaleNone
        for subview in [iconView, statusBadge, nameField, line2, line3, right1, right2, capacityBar, checkbox] {
            addSubview(subview)
        }
        applyFonts()
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setDetails(_ details: ItemDetailText) {
        applyFonts()
        line2.stringValue = details.line2
        line3.stringValue = details.line3
        right1.stringValue = details.right1
        right2.stringValue = details.right2
        capacityBar.fraction = details.capacity ?? 0
        capacityBar.isLow = details.capacityIsLow
        capacityBar.isHidden = details.capacity == nil || viewMode != .tiles
        line2.isHidden = !capacityBar.isHidden || (viewMode != .tiles && viewMode != .content && viewMode != .details)
    }

    /// Set whenever the item is configured, so reused items follow a style change.
    private func applyFonts() {
        nameField.font = Theme.font(ofSize: 12)
        for label in [line2, line3, right1, right2] { label.font = Theme.font(ofSize: 11) }
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
        nameField.textColor = Theme.isClassic && isSelected ? Classic.selectionText : .labelColor
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
            let barHeight: CGFloat = Theme.isClassic ? 12 : 8
            capacityBar.frame = NSRect(x: x, y: top + 24 - barHeight / 2, width: max(0, min(200, width - x - 12)),
                                       height: barHeight)
        case .content:
            iconView.frame = NSRect(x: 8 + inset, y: (height - icon) / 2, width: icon, height: icon)
            let x = 58 + inset
            let split = max(x + 120, width * 0.55)
            nameField.frame = NSRect(x: x, y: height / 2 - 17, width: split - x - 12, height: 16)
            line2.frame = NSRect(x: x, y: height / 2 + 1, width: split - x - 12, height: 15)
            right1.frame = NSRect(x: split, y: height / 2 - 16, width: max(0, width - split - 8), height: 15)
            right2.frame = NSRect(x: split, y: height / 2 + 1, width: max(0, width - split - 8), height: 15)
        }
        layoutStatusBadge()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true // the badge's background is a layer colour
    }

    /// Over the bottom-left corner of icons of 32 pt and up; small icons have no room.
    private func layoutStatusBadge() {
        statusBadge.isHidden = cloudStatus == nil || iconView.frame.width < 32
        guard !statusBadge.isHidden else { return }
        let size: CGFloat = 16
        let icon = iconView.frame
        statusBadge.frame = NSRect(x: icon.minX - 2, y: icon.maxY - size + 2, width: size, height: size)
        statusBadge.layer?.cornerRadius = size / 2
        statusBadge.layer?.backgroundColor = Theme.paneColor.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        if Theme.isClassic {
            drawClassic()
            return
        }
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

    /// Navy behind the name only, hugging the text; a navy outline for a drop target.
    private func drawClassic() {
        if isDropTarget {
            Classic.selection.setFill()
            bounds.insetBy(dx: 1, dy: 1).frame(withWidth: 1)
        }
        guard isSelected, let cell = nameField.cell else { return }
        let field = nameField.frame
        let size = cell.cellSize(forBounds: field)
        let width = min(field.width, size.width)
        let x = nameField.alignment == .center ? field.midX - width / 2 : field.minX
        Classic.selection.setFill()
        NSRect(x: x - 1, y: field.minY, width: width + 2, height: min(field.height, size.height)).integral.fill()
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

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }

    override func accessibilityLabel() -> String? { "Used space" }

    override func accessibilityValue() -> Any? { "\(Int((fraction * 100).rounded()))%" }

    override func draw(_ dirtyRect: NSRect) {
        if Theme.isClassic {
            drawClassic()
            return
        }
        let radius = bounds.height / 2
        Self.trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var used = bounds
        used.size.width = max(bounds.height, bounds.width * CGFloat(fraction))
        (isLow ? Self.lowColor : Theme.accent).setFill()
        NSBezierPath(roundedRect: used, xRadius: radius, yRadius: radius).fill()
    }

    /// Windows 98's progress bar: a thin sunken track filled with blocks.
    private func drawClassic() {
        Classic.window.setFill()
        bounds.fill()
        Bevel.thinSunken.draw(in: bounds, flipped: true)
        let inner = bounds.insetBy(dx: 2, dy: 2)
        let used = inner.width * CGFloat(fraction)
        (isLow ? Self.lowColor : Classic.selection).setFill()
        var x = inner.minX
        while x < inner.minX + used {
            NSRect(x: x, y: inner.minY, width: min(6, inner.maxX - x), height: inner.height).fill()
            x += 8
        }
    }
}
