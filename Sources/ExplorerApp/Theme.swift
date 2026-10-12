import AppKit

/// Windows 11 look: colours, corner radii and fonts used by the custom-drawn parts of the UI.
///
/// The window is layered like Explorer's: a Mica-style translucent base (title bar and tabs),
/// a lighter header layer (address and command bars, selected tab), and a solid body (panes).
@MainActor
enum Theme {
    // MARK: Metrics

    static let controlCornerRadius: CGFloat = 4
    static let tabCornerRadius: CGFloat = 8
    static let tabStripHeight: CGFloat = 38
    static let addressBarHeight: CGFloat = 44
    static let commandBarHeight: CGFloat = 44

    /// Details and navigation pane row heights; Compact view tightens them.
    static var detailsRowHeight: CGFloat { AppSettings.compactView ? 22 : 30 }
    static var navigationRowHeight: CGFloat { AppSettings.compactView ? 24 : 30 }

    // MARK: Colours

    static var accent: NSColor { AppSettings.accent.color }

    /// Laid over the translucent window background to give Mica's base colour (#202020 in dark,
    /// #F3F3F3 in light), still tinted by the wallpaper.
    static let micaTintColor = NSColor.dynamic(
        light: NSColor(white: 0.95, alpha: 0.55),
        dark: NSColor(white: 0.125, alpha: 0.82)
    )

    /// Address bar, command bar and the selected tab.
    static let headerColor = NSColor.dynamic(
        light: NSColor(white: 1, alpha: 0.72),
        dark: NSColor(white: 1, alpha: 0.06)
    )

    /// Navigation pane, content and status bar.
    static let bodyColor = NSColor.dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1C1C1C))

    /// Thin dividers between layers.
    static let dividerColor = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 0, alpha: 0.35)
    )

    /// Hover fill for buttons, tabs and list items.
    static let hoverColor = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.045),
        dark: NSColor(white: 1, alpha: 0.06)
    )

    /// Pressed fill for buttons.
    static let pressedColor = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.1)
    )

    /// The address bar's text box.
    static let fieldColor = NSColor.dynamic(
        light: NSColor(white: 1, alpha: 0.9),
        dark: NSColor(white: 1, alpha: 0.06)
    )

    /// Selected list items: a light tint of the accent colour, with the text left as is.
    static func selectionColor(emphasized: Bool, hovered: Bool = false) -> NSColor {
        let accent = self.accent
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var alpha: CGFloat = dark ? 0.32 : 0.18
            if !emphasized { alpha *= 0.6 }
            if hovered { alpha += 0.06 }
            return accent.withAlphaComponent(alpha)
        }
    }

    /// The navigation pane's selected row: neutral, as in Windows 11.
    static let navigationSelectionColor = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.075),
        dark: NSColor(white: 1, alpha: 0.085)
    )

    // MARK: Fonts

    /// Segoe UI when the user has it installed (it can't be bundled), otherwise the system font.
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if hasSegoe {
            let name = weight >= .semibold ? "SegoeUI-Semibold" : "SegoeUI"
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    private static let hasSegoe = NSFont(name: "SegoeUI", size: 12) != nil

    // MARK: Appearance

    /// Applies the Light / Dark / system choice to the whole app.
    static func applyAppearance() {
        switch AppSettings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// A view filled with a (dynamic) colour, re-resolved when the appearance changes. Painted as
/// the layer's background colour rather than in `draw(_:)`, which proved unreliable among the
/// window's layer-backed views.
final class LayerView: NSView {
    var fillColor: NSColor { didSet { needsDisplay = true } }
    /// Draws a divider along the bottom edge.
    var drawsBottomDivider = false {
        didSet {
            divider.isHidden = !drawsBottomDivider
            needsLayout = true
        }
    }

    private let divider = CALayer()

    init(color: NSColor) {
        fillColor = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        divider.isHidden = true
        layer?.addSublayer(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
            divider.backgroundColor = Theme.dividerColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer isn't flipped: y = 0 is the bottom edge.
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A borderless button with Windows 11's rounded hover and pressed fills. Used by the tab strip,
/// address bar and command bar.
class FluentButton: NSButton {
    private var isHovered = false { didSet { needsDisplay = true } }
    /// Shows a small chevron after the title, for buttons that open a menu.
    var showsMenuIndicator = false { didSet { invalidateIntrinsicContentSize() } }
    /// A menu shown below the button when it is clicked, instead of sending its action.
    var dropDownMenu: NSMenu?

    convenience init(symbol: String, title: String = "", toolTip: String) {
        self.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        self.title = title
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        font = Theme.font(ofSize: 12)
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        refusesFirstResponder = true
        updateColors()
    }

    override var isEnabled: Bool {
        didSet { updateColors() }
    }

    /// Text and icon colours are set explicitly: AppKit's own choice for borderless buttons
    /// varies (some titles come out grey for no visible reason).
    private func updateColors() {
        let color: NSColor = isEnabled ? .labelColor : .tertiaryLabelColor
        contentTintColor = color
        guard !title.isEmpty else { return }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? Theme.font(ofSize: 12),
            .foregroundColor: color,
        ])
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += title.isEmpty ? 16 : 20
        if showsMenuIndicator { size.width += 14 }
        size.height = max(size.height, 30)
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = isHighlighted ? Theme.pressedColor : (isHovered && isEnabled ? Theme.hoverColor : nil)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.controlCornerRadius, yRadius: Theme.controlCornerRadius)
                .fill()
        }
        var content = bounds
        if showsMenuIndicator { content.size.width -= 14 }
        cell?.drawInterior(withFrame: content, in: self)
        if showsMenuIndicator {
            let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor])))
            let rect = NSRect(x: bounds.maxX - 18, y: bounds.midY - 4, width: 9, height: 8)
            chevron?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 0.7 : 0.3,
                          respectFlipped: true, hints: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let dropDownMenu, isEnabled else {
            super.mouseDown(with: event)
            return
        }
        isHighlighted = true
        dropDownMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
        isHighlighted = false
        isHovered = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}
