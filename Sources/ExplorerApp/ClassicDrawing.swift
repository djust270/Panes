import AppKit

/// Windows 98's "Windows Standard" colour scheme.
enum Classic {
    static let face = NSColor(hex: 0xC0C0C0)
    static let highlight = NSColor(hex: 0xFFFFFF)
    static let light = NSColor(hex: 0xDFDFDF)
    static let shadow = NSColor(hex: 0x808080)
    static let darkShadow = NSColor(hex: 0x0A0A0A)
    static let window = NSColor(hex: 0xFFFFFF)
    static let text = NSColor(hex: 0x000000)
    static let grayText = NSColor(hex: 0x808080)
    static let selection = NSColor(hex: 0x000080)
    static let selectionText = NSColor(hex: 0xFFFFFF)

    /// The title bar: navy to light blue when active, greys when not (Windows 98's gradient).
    static func captionGradient(active: Bool) -> NSGradient? {
        active
            ? NSGradient(starting: NSColor(hex: 0x000080), ending: NSColor(hex: 0x1084D0))
            : NSGradient(starting: NSColor(hex: 0x808080), ending: NSColor(hex: 0xB5B5B5))
    }
}

/// Windows 98's 3D edges: two rings of light and dark lines (one for the thin kinds), lit from
/// the top left.
enum Bevel {
    /// A push button or caption button.
    case raised
    /// A pushed-in button.
    case pressed
    /// A text box or list: white inside a frame that dips into the face.
    case sunkenField
    /// A flat toolbar button under the mouse.
    case thinRaised
    /// A flat toolbar button being pressed, or a status bar panel.
    case thinSunken

    private var rings: [(topLeft: NSColor, bottomRight: NSColor)] {
        switch self {
        case .raised: return [(Classic.highlight, Classic.darkShadow), (Classic.light, Classic.shadow)]
        case .pressed: return [(Classic.darkShadow, Classic.highlight), (Classic.shadow, Classic.light)]
        case .sunkenField: return [(Classic.shadow, Classic.highlight), (Classic.darkShadow, Classic.light)]
        case .thinRaised: return [(Classic.highlight, Classic.shadow)]
        case .thinSunken: return [(Classic.shadow, Classic.highlight)]
        }
    }

    /// The edge's width; content goes inside it.
    var width: CGFloat { CGFloat(rings.count) }

    /// Draws the edge just inside `rect`, in a view whose coordinates are `flipped` or not.
    func draw(in rect: NSRect, flipped: Bool) {
        var rect = rect
        for ring in rings {
            Self.ring(rect, topLeft: ring.topLeft, bottomRight: ring.bottomRight, flipped: flipped)
            rect = rect.insetBy(dx: 1, dy: 1)
        }
    }

    /// The bottom and right lines go over the corners, as on Windows.
    private static func ring(_ rect: NSRect, topLeft: NSColor, bottomRight: NSColor, flipped: Bool) {
        guard rect.width >= 2, rect.height >= 2 else { return }
        let topY = flipped ? rect.minY : rect.maxY - 1
        let bottomY = flipped ? rect.maxY - 1 : rect.minY
        topLeft.setFill()
        NSRect(x: rect.minX, y: topY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        bottomRight.setFill()
        NSRect(x: rect.minX, y: bottomY, width: rect.width, height: 1).fill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    /// An etched separator: a shadow line beside a highlight line, 2 pt in all.
    static func etchedLine(in rect: NSRect, vertical: Bool, flipped: Bool) {
        Classic.shadow.setFill()
        if vertical {
            NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            Classic.highlight.setFill()
            NSRect(x: rect.minX + 1, y: rect.minY, width: 1, height: rect.height).fill()
        } else {
            NSRect(x: rect.minX, y: flipped ? rect.minY : rect.minY + 1, width: rect.width, height: 1).fill()
            Classic.highlight.setFill()
            NSRect(x: rect.minX, y: flipped ? rect.minY + 1 : rect.minY, width: rect.width, height: 1).fill()
        }
    }
}

/// Holds a list or tree. In Windows 98 style it draws a sunken frame around it, a little in from
/// its edges so the grey face shows between panes; otherwise it's invisible and the content
/// fills it.
final class BevelView: NSView, StyleObserving {
    private static let margin: CGFloat = 2
    private var insets: [NSLayoutConstraint] = []

    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        insets = [
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        NSLayoutConstraint.activate(insets)
        styleDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Puts `content` in a frame that fills `container`.
    static func embed(_ content: NSView, in container: NSView) {
        let frame = BevelView(content: content)
        frame.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.topAnchor.constraint(equalTo: container.topAnchor),
            frame.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            frame.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override var isFlipped: Bool { true }

    func styleDidChange() {
        let inset = Theme.isClassic ? Self.margin + Bevel.sunkenField.width : 0
        for constraint in insets { constraint.constant = inset }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard Theme.isClassic else { return }
        Bevel.sunkenField.draw(in: bounds.insetBy(dx: Self.margin, dy: Self.margin), flipped: true)
    }
}
