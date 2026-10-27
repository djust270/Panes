import AppKit
import ExplorerCore

/// Windows 11 look: colours, corner radii and fonts used by the custom-drawn parts of the UI.
///
/// The window is layered like Explorer's: a Mica-style translucent base (title bar and tabs),
/// a lighter header layer (address and command bars, selected tab), and a solid body (panes).
///
/// Settings › View › Style switches to Windows 98 (`isClassic`): grey 3D faces, sunken white
/// lists, navy selection and MS Sans Serif, in the same layout. Colours resolve the style when
/// drawn, so a switch only needs a redraw (`restyle(_:)`).
@MainActor
enum Theme {
    /// Windows 98 style. Read from the defaults directly: colour providers resolve off the main
    /// actor too.
    nonisolated static var isClassic: Bool {
        UserDefaults.standard.string(forKey: AppSettings.visualStyleKey) == AppSettings.VisualStyle.classic.rawValue
    }

    // MARK: Metrics

    static var controlCornerRadius: CGFloat { isClassic ? 0 : 4 }
    static let tabCornerRadius: CGFloat = 8
    static let tabStripHeight: CGFloat = 38
    static let addressBarHeight: CGFloat = 44
    static let commandBarHeight: CGFloat = 44
    /// The address bar's text boxes (inside the sunken frame, in Windows 98 style).
    static var fieldHeight: CGFloat { isClassic ? 18 : 32 }

    /// Details and navigation pane row heights; Compact view tightens them. Windows 98's rows
    /// are always tight. Both follow the zoom.
    static var detailsRowHeight: CGFloat { zoomed(isClassic ? 18 : (AppSettings.compactView ? 22 : 30)) }
    static var navigationRowHeight: CGFloat { zoomed(isClassic ? 20 : (AppSettings.compactView ? 24 : 30)) }

    /// View › Zoom In / Zoom Out, which scales the file list and the navigation pane (not the
    /// tabs, address bar or command bar).
    static var zoom: CGFloat { CGFloat(TextZoom.clamped(AppSettings.textZoom)) }

    /// A file list or navigation pane metric at the current zoom, in whole points.
    static func zoomed(_ value: CGFloat) -> CGFloat { (value * zoom).rounded() }

    // MARK: Colours

    static var accent: NSColor { isClassic ? Classic.selection : AppSettings.accent.color }

    /// Laid over the translucent window background to give Mica's base colour (#202020 in dark,
    /// #F3F3F3 in light), still tinted by the wallpaper.
    static let micaTintColor = styled(
        light: NSColor(white: 0.95, alpha: 0.55),
        dark: NSColor(white: 0.125, alpha: 0.82),
        classic: Classic.face
    )

    /// Address bar, command bar and the selected tab.
    static let headerColor = styled(
        light: NSColor(white: 1, alpha: 0.72),
        dark: NSColor(white: 1, alpha: 0.06),
        classic: Classic.face
    )

    /// Navigation pane, content and status bar.
    static let bodyColor = styled(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1C1C1C), classic: Classic.face)

    /// Behind the file list and the navigation tree: the body colour, or Windows 98's white
    /// inside a sunken frame.
    static let paneColor = styled(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1C1C1C), classic: Classic.window)

    /// Thin dividers between layers.
    static let dividerColor = styled(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 0, alpha: 0.35),
        classic: Classic.shadow
    )

    /// Hover fill for buttons, tabs and list items. Windows 98 has none.
    static let hoverColor = styled(
        light: NSColor(white: 0, alpha: 0.045),
        dark: NSColor(white: 1, alpha: 0.06),
        classic: .clear
    )

    /// Pressed fill for buttons (Windows 98 sinks them instead).
    static let pressedColor = styled(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.1),
        classic: .clear
    )

    /// The address bar's text box.
    static let fieldColor = styled(
        light: NSColor(white: 1, alpha: 0.9),
        dark: NSColor(white: 1, alpha: 0.06),
        classic: Classic.window
    )

    /// Selected list items: a light tint of the accent colour, with the text left as is. In
    /// Windows 98, solid navy with white text (grey when the list isn't focused).
    static func selectionColor(emphasized: Bool, hovered: Bool = false) -> NSColor {
        if isClassic { return emphasized ? Classic.selection : Classic.face }
        let accent = self.accent
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var alpha: CGFloat = dark ? 0.32 : 0.18
            if !emphasized { alpha *= 0.6 }
            if hovered { alpha += 0.06 }
            return accent.withAlphaComponent(alpha)
        }
    }

    /// The navigation pane's selected row: neutral, as in Windows 11. (Windows 98 uses
    /// `selectionColor`.)
    static let navigationSelectionColor = NSColor.dynamic(
        light: NSColor(white: 0, alpha: 0.075),
        dark: NSColor(white: 1, alpha: 0.085)
    )

    /// A colour for each appearance, and one for Windows 98, chosen when it's drawn.
    private static func styled(light: NSColor, dark: NSColor, classic: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if isClassic { return classic }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: Fonts

    /// Segoe UI when the user has it installed (it can't be bundled), otherwise the system font.
    /// Windows 98 uses MS Sans Serif (macOS ships its TrueType version) at 8 pt, i.e. 11 px, and
    /// Tahoma Bold where it needs bold.
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if isClassic {
            let name = weight >= .semibold ? "Tahoma-Bold" : "MicrosoftSansSerif"
            if let font = NSFont(name: name, size: max(11, size - 2)) { return font }
        }
        if hasSegoe {
            let name = weight >= .semibold ? "SegoeUI-Semibold" : "SegoeUI"
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// `font(ofSize:weight:)` at the current zoom, for the file list and the navigation pane.
    static func contentFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(ofSize: size * zoom, weight: weight)
    }

    private static let hasSegoe = NSFont(name: "SegoeUI", size: 12) != nil

    // MARK: Appearance

    /// Applies the Light / Dark / system choice to the whole app. Windows 98 is always light.
    static func applyAppearance() {
        if isClassic {
            NSApp.appearance = NSAppearance(named: .aqua)
            return
        }
        switch AppSettings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// After a style change: lets views that cache fonts or metrics update
    /// (`StyleObserving`), and redraws everything under `view`.
    static func restyle(_ view: NSView) {
        (view as? StyleObserving)?.styleDidChange()
        view.needsLayout = true
        view.needsDisplay = true
        for subview in view.subviews { restyle(subview) }
    }
}

/// A view that caches something style-dependent (a font, a size) and refreshes it when the
/// style changes.
@MainActor
protocol StyleObserving: AnyObject {
    func styleDidChange()
}

/// A view filled with a (dynamic) colour, re-resolved when the appearance changes. Painted as
/// the layer's background colour rather than in `draw(_:)`, which proved unreliable among the
/// window's layer-backed views.
final class LayerView: NSView {
    var fillColor: NSColor { didSet { needsDisplay = true } }
    /// Draws a divider along the bottom edge (etched, in Windows 98 style).
    var drawsBottomDivider = false {
        didSet {
            divider.isHidden = !drawsBottomDivider
            needsLayout = true
        }
    }

    private let divider = CALayer()
    /// The etched divider's lower, white line.
    private let dividerHighlight = CALayer()

    init(color: NSColor) {
        fillColor = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        divider.isHidden = true
        dividerHighlight.isHidden = true
        layer?.addSublayer(divider)
        layer?.addSublayer(dividerHighlight)
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
            dividerHighlight.backgroundColor = Classic.highlight.cgColor
        }
    }

    override func layout() {
        super.layout()
        let etched = Theme.isClassic
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Windows 11 style draws its line at y = 0, which (the view being flipped, so is its layer's
        // geometry) is the top edge: the line under the tabs. Windows 98's etched line goes along
        // the real bottom edge, under the command bar, so the selected tab joins the face.
        let bottom = layer?.isGeometryFlipped == true ? bounds.height - 1 : 0
        let up: CGFloat = layer?.isGeometryFlipped == true ? -1 : 1
        divider.frame = CGRect(x: 0, y: etched ? bottom + up : 0, width: bounds.width, height: 1)
        dividerHighlight.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: 1)
        dividerHighlight.isHidden = !(drawsBottomDivider && etched)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A borderless button with Windows 11's rounded hover and pressed fills. Used by the tab strip,
/// address bar and command bar. In Windows 98 style it's a flat toolbar button that rises
/// under the mouse and sinks when pressed.
class FluentButton: NSButton, StyleObserving {
    private var isHovered = false { didSet { needsDisplay = true } }
    /// Shows a small chevron after the title, for buttons that open a menu.
    var showsMenuIndicator = false { didSet { invalidateIntrinsicContentSize() } }
    /// A menu shown below the button when it is clicked, instead of sending its action.
    var dropDownMenu: NSMenu?
    /// The icon and text colour in Windows 98 style, for buttons on the title bar's navy.
    var classicForeground: NSColor? { didSet { updateColors() } }

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

    func styleDidChange() {
        font = Theme.font(ofSize: 12)
        updateColors()
        invalidateIntrinsicContentSize()
    }

    /// Text and icon colours are set explicitly: AppKit's own choice for borderless buttons
    /// varies (some titles come out grey for no visible reason).
    private func updateColors() {
        let color: NSColor = Theme.isClassic
            ? (isEnabled ? classicForeground ?? Classic.text : Classic.grayText)
            : (isEnabled ? .labelColor : .tertiaryLabelColor)
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
        if Theme.isClassic {
            drawClassic()
            return
        }
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

    private func drawClassic() {
        if isHighlighted {
            Bevel.thinSunken.draw(in: bounds, flipped: isFlipped)
        } else if isHovered, isEnabled {
            Bevel.thinRaised.draw(in: bounds, flipped: isFlipped)
        }
        // Pressed content shifts down and right a pixel, as on Windows.
        var content = bounds
        if showsMenuIndicator { content.size.width -= 14 }
        if isHighlighted { content = content.offsetBy(dx: 1, dy: isFlipped ? 1 : -1) }
        cell?.drawInterior(withFrame: content, in: self)
        if showsMenuIndicator {
            // A small solid triangle.
            let x = content.maxX + 3
            let midY = content.midY
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: midY - (isFlipped ? 2 : -2)))
            path.line(to: NSPoint(x: x + 7, y: midY - (isFlipped ? 2 : -2)))
            path.line(to: NSPoint(x: x + 3.5, y: midY + (isFlipped ? 2 : -2)))
            path.close()
            (isEnabled ? Classic.text : Classic.grayText).setFill()
            path.fill()
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
