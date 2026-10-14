import AppKit

/// Windows-style minimise, maximise/restore and close buttons (46 × 40 pt, close turns red), or
/// Windows 98's small raised grey ones.
@MainActor
final class CaptionButtonsView: NSView {
    /// Windows 98's are 16 × 14 pt, with a gap before Close.
    static var width: CGFloat { Theme.isClassic ? 16 * 3 + 2 + 4 : 46 * 3 }

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
        if Theme.isClassic {
            let y = ((bounds.height - 14) / 2).rounded()
            close.frame = NSRect(x: bounds.maxX - 4 - 16, y: y, width: 16, height: 14)
            maximize.frame = NSRect(x: close.frame.minX - 2 - 16, y: y, width: 16, height: 14)
            minimize.frame = NSRect(x: maximize.frame.minX - 16, y: y, width: 16, height: 14)
        } else {
            for (index, button) in [minimize, maximize, close].enumerated() {
                button.frame = NSRect(x: CGFloat(index) * 46, y: 0, width: 46, height: bounds.height)
            }
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
final class CaptionButton: NSButton {
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
        if Theme.isClassic {
            Classic.face.setFill()
            bounds.fill()
            (isHighlighted ? Bevel.pressed : Bevel.raised).draw(in: bounds, flipped: isFlipped)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .black)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [Classic.text])))
            if let image {
                let offset: CGFloat = isHighlighted ? 1 : 0
                let rect = NSRect(x: ((bounds.width - image.size.width) / 2).rounded() + offset,
                                  y: ((bounds.height - image.size.height) / 2).rounded() + offset,
                                  width: image.size.width, height: image.size.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: nil)
            }
            return
        }
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
