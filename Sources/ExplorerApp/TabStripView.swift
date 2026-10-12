import AppKit
import ExplorerCore

/// What the tab strip asks of its window.
@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelectTabAt index: Int)
    func tabStrip(_ strip: TabStripView, didCloseTabAt index: Int)
    func tabStripDidRequestNewTab(_ strip: TabStripView)
    func tabStrip(_ strip: TabStripView, moveTabFrom from: Int, to: Int)
    func tabStrip(_ strip: TabStripView, menuForTabAt index: Int) -> NSMenu?
    /// Starts dragging the tab at `index`; returns `false` if it can't be dragged out (the
    /// window's only tab drags the window instead).
    func tabStrip(_ strip: TabStripView, canDragTabAt index: Int) -> Bool
    /// A tab dragged from another window was dropped at `index`.
    func tabStrip(_ strip: TabStripView, acceptDraggedTabAt index: Int)
    /// A tab dragged out of this strip was dropped outside any tab strip.
    func tabStrip(_ strip: TabStripView, detachTabAt index: Int, at screenPoint: NSPoint)
}

/// Windows 11's title-bar tabs: the selected tab is joined to the header layer below it,
/// others are separated by thin lines and highlight on hover. Tabs can be reordered, dragged
/// to another window, or dragged out into a new window. Optional Windows-style caption buttons
/// sit on the right. Empty space drags the window; double-clicking it zooms.
@MainActor
final class TabStripView: NSView {
    struct Tab: Equatable {
        var title: String
        var icon: NSImage
    }

    static let tabPasteboardType = NSPasteboard.PasteboardType("com.example.explorer.tab")

    weak var delegate: TabStripDelegate?

    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex = 0
    /// Room left for the traffic lights.
    var leadingInset: CGFloat = 8 { didSet { needsLayout = true } }
    var showsCaptionButtons = false {
        didSet {
            captionButtons.isHidden = !showsCaptionButtons
            needsLayout = true
        }
    }

    private var tabViews: [TabView] = []
    private let newTabButton = FluentButton(symbol: "plus", toolTip: "New tab")
    private let captionButtons = CaptionButtonsView()
    /// The tab being dragged from this strip, if any.
    private var draggedIndex: Int?
    /// Where a tab from another window would be inserted.
    private var insertionIndex: Int? { didSet { needsDisplay = true } }
    /// Switches to the tab under a file drag after a short hover, as browsers do.
    private var springLoadTimer: Timer?
    private var springLoadIndex: Int?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        addSubview(newTabButton)
        captionButtons.isHidden = true
        addSubview(captionButtons)
        registerForDraggedTypes([Self.tabPasteboardType, .fileURL])
        setAccessibilityRole(.tabGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setTabs(_ tabs: [Tab], selectedIndex: Int) {
        let countChanged = tabs.count != tabViews.count
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        if countChanged {
            tabViews.forEach { $0.removeFromSuperview() }
            tabViews = tabs.indices.map { _ in
                let view = TabView()
                view.strip = self
                addSubview(view, positioned: .below, relativeTo: newTabButton)
                return view
            }
        }
        for (index, view) in tabViews.enumerated() {
            view.index = index
            view.tab = tabs[index]
            view.isSelected = index == selectedIndex
            view.showsSeparator = index != selectedIndex && index + 1 != selectedIndex
        }
        newTabButton.toolTip = KeyboardShortcuts.toolTip("New tab", .newTab)
        needsLayout = true
    }

    // MARK: Layout

    private var tabsArea: (x: CGFloat, width: CGFloat) {
        let captionWidth = showsCaptionButtons ? CaptionButtonsView.width : 0
        let available = bounds.width - leadingInset - captionWidth - 40 - 48
        return (leadingInset, max(0, available))
    }

    private var tabWidth: CGFloat {
        CGFloat(TabStripLayout.tabWidth(count: tabs.count, available: Double(tabsArea.width)))
    }

    override func layout() {
        super.layout()
        let width = tabWidth
        var x = tabsArea.x
        let top: CGFloat = 4
        for view in tabViews {
            view.frame = NSRect(x: x, y: top, width: width, height: bounds.height - top)
            x += width
        }
        newTabButton.frame = NSRect(x: x + 4, y: top + 2, width: 30, height: bounds.height - top - 6)
        captionButtons.frame = NSRect(
            x: bounds.maxX - CaptionButtonsView.width, y: 0,
            width: CaptionButtonsView.width, height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let insertionIndex else { return }
        let x = tabsArea.x + CGFloat(insertionIndex) * tabWidth
        Theme.accent.setFill()
        NSRect(x: x - 1, y: 8, width: 2, height: bounds.height - 12).fill()
    }

    // MARK: Window dragging

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            Self.performTitleBarDoubleClick(in: window)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// Zooms or minimises, following System Settings › Desktop & Dock › "Double-click a
    /// window's title bar to".
    static func performTitleBarDoubleClick(in window: NSWindow?) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }

    // MARK: Actions from tabs

    @objc private func newTab() {
        delegate?.tabStripDidRequestNewTab(self)
    }

    fileprivate func select(_ index: Int) {
        delegate?.tabStrip(self, didSelectTabAt: index)
    }

    fileprivate func close(_ index: Int) {
        delegate?.tabStrip(self, didCloseTabAt: index)
    }

    fileprivate func menu(for index: Int) -> NSMenu? {
        delegate?.tabStrip(self, menuForTabAt: index)
    }

    fileprivate func tabDidChangeHover() {
        for (index, view) in tabViews.enumerated() {
            let next = tabViews.indices.contains(index + 1) ? tabViews[index + 1] : nil
            view.showsSeparator = !view.isSelected && !view.isHovered
                && next?.isSelected != true && next?.isHovered != true
        }
    }

    // MARK: Dragging tabs out

    fileprivate func beginDragging(_ index: Int, event: NSEvent) -> Bool {
        guard delegate?.tabStrip(self, canDragTabAt: index) == true else { return false }
        let view = tabViews[index]
        let item = NSPasteboardItem()
        item.setString(String(index), forType: Self.tabPasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(view.bounds, contents: view.snapshot())
        draggedIndex = index
        let session = view.beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    private func dropIndex(for sender: NSDraggingInfo, count: Int) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        let x = Double(point.x - tabsArea.x + tabWidth / 2)
        if draggedIndex != nil {
            return TabStripLayout.insertionIndex(forX: Double(point.x - tabsArea.x), tabWidth: Double(tabWidth),
                                                 count: count)
        }
        return min(max(Int(x / Double(tabWidth)), 0), count)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        tabViews.firstIndex { $0.frame.contains(point) }
    }
}

// MARK: - Drag source and destination

extension TabStripView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            draggedIndex = nil
            TabDragging.tab = nil
        }
        guard operation.isEmpty, let index = draggedIndex else { return }
        delegate?.tabStrip(self, detachTabAt: index, at: screenPoint)
    }
}

extension TabStripView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.tabPasteboardType) {
            if let from = draggedIndex {
                // Reordering within this strip: move the tab live.
                let to = dropIndex(for: sender, count: tabs.count)
                if to != from {
                    delegate?.tabStrip(self, moveTabFrom: from, to: to)
                    draggedIndex = to
                }
            } else {
                insertionIndex = dropIndex(for: sender, count: tabs.count)
            }
            return .move
        }
        // Files hovering over a tab switch to it, so they can be dropped into its folder.
        let index = tabIndex(at: convert(sender.draggingLocation, from: nil))
        if index != springLoadIndex {
            springLoadTimer?.invalidate()
            springLoadIndex = index
            if let index, index != selectedIndex {
                springLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.select(index) }
                }
            }
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionIndex = nil
        springLoadTimer?.invalidate()
        springLoadIndex = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { insertionIndex = nil }
        guard sender.draggingPasteboard.types?.contains(Self.tabPasteboardType) == true else { return false }
        if draggedIndex != nil { return true }
        guard TabDragging.tab != nil else { return false }
        delegate?.tabStrip(self, acceptDraggedTabAt: insertionIndex ?? tabs.count)
        return true
    }
}

/// The tab being dragged, so another window's strip can take it. In-process only.
@MainActor
enum TabDragging {
    static var tab: ExplorerTabController?
}

// MARK: - Tab

/// One tab: icon, title and a close button (shown on the selected or hovered tab).
@MainActor
private final class TabView: NSView {
    weak var strip: TabStripView?
    var index = 0
    var tab = TabStripView.Tab(title: "", icon: NSImage()) {
        didSet {
            guard tab != oldValue else { return }
            titleField.stringValue = tab.title
            iconView.image = tab.icon
            toolTip = tab.title
            setAccessibilityLabel(tab.title)
        }
    }
    var isSelected = false { didSet { stateChanged() } }
    var isHovered = false { didSet { stateChanged() } }
    var showsSeparator = true { didSet { needsDisplay = true } }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = FluentButton(symbol: "xmark", toolTip: "Close tab")
    private var dragStart: NSEvent?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = Theme.font(ofSize: 12)
        titleField.lineBreakMode = .byTruncatingTail
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        for subview in [iconView, titleField, closeButton] as [NSView] {
            addSubview(subview)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        stateChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func stateChanged() {
        closeButton.isHidden = !(isSelected || isHovered) || bounds.width < 90
        titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        setAccessibilityValue(isSelected)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2 - 1
        iconView.frame = NSRect(x: 12, y: midY - 8, width: 16, height: 16)
        let closeWidth: CGFloat = closeButton.isHidden ? 0 : 28
        closeButton.frame = NSRect(x: bounds.maxX - 32, y: midY - 12, width: 24, height: 24)
        let titleX: CGFloat = 36
        titleField.frame = NSRect(x: titleX, y: midY - 8, width: max(0, bounds.width - titleX - closeWidth - 10),
                                  height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let radius = Theme.tabCornerRadius
            let rect = bounds
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
            path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                           startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                           startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()
            Theme.headerColor.setFill()
            path.fill()
        } else if isHovered {
            Theme.hoverColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        if showsSeparator {
            Theme.dividerColor.setFill()
            NSRect(x: bounds.maxX - 1, y: bounds.midY - 8, width: 1, height: 16).fill()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return }
        strip?.select(index)
        dragStart = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x,
                             event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 4 else { return }
        dragStart = nil
        if strip?.beginDragging(index, event: start) != true {
            window?.performDrag(with: start)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    /// Middle-click closes the tab.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { closeTab() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.menu(for: index)
    }

    @objc private func closeTab() {
        strip?.close(index)
    }

    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        strip?.tabDidChangeHover()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        strip?.tabDidChangeHover()
    }
}

// MARK: - Caption buttons

/// Windows-style minimise, maximise/restore and close buttons (46 × 40 pt, close turns red).
@MainActor
private final class CaptionButtonsView: NSView {
    static let width: CGFloat = 46 * 3

    private let minimize = CaptionButton(symbol: "minus", label: "Minimize")
    private let maximize = CaptionButton(symbol: "square", label: "Maximize")
    private let close = CaptionButton(symbol: "xmark", label: "Close", isClose: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minimize.target = self
        minimize.action = #selector(minimizeWindow)
        maximize.target = self
        maximize.action = #selector(zoomWindow)
        close.target = self
        close.action = #selector(closeWindow)
        [minimize, maximize, close].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (index, button) in [minimize, maximize, close].enumerated() {
            button.frame = NSRect(x: CGFloat(index) * 46, y: 0, width: 46, height: bounds.height)
        }
        let zoomed = window?.isZoomed == true
        maximize.symbol = zoomed ? "square.on.square" : "square"
        maximize.toolTip = zoomed ? "Restore Down" : "Maximize"
    }

    @objc private func minimizeWindow() { window?.performMiniaturize(nil) }
    @objc private func zoomWindow() { window?.performZoom(nil) }
    @objc private func closeWindow() { window?.performClose(nil) }
}

@MainActor
private final class CaptionButton: NSButton {
    private let isClose: Bool
    private var isHovered = false { didSet { needsDisplay = true } }
    var symbol: String { didSet { updateImage() } }

    init(symbol: String, label: String, isClose: Bool = false) {
        self.symbol = symbol
        self.isClose = isClose
        super.init(frame: .zero)
        isBordered = false
        title = ""
        toolTip = label
        setAccessibilityLabel(label)
        refusesFirstResponder = true
        updateImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateImage() {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .light))
        imagePosition = .imageOnly
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            let fill: NSColor = isClose
                ? NSColor(hex: 0xC42B1C, alpha: isHighlighted ? 0.85 : 1)
                : (isHighlighted ? Theme.pressedColor : Theme.hoverColor)
            fill.setFill()
            bounds.fill()
        }
        contentTintColor = isClose && isHovered ? .white : .labelColor
        cell?.drawInterior(withFrame: bounds, in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override var mouseDownCanMoveWindow: Bool { false }
}
