import AppKit
import ExplorerCore

/// Windows' sync-state glyphs: a blue cloud (online-only), a green check (on this device), a
/// solid green check (always on this device), blue arrows (syncing), a red cross (a problem).
@MainActor
enum CloudStatusGlyph {
    static func image(for status: CloudStatus, pointSize: CGFloat = 12) -> NSImage? {
        let (symbol, color): (String, NSColor) = switch status {
        case .onlineOnly: ("cloud", .systemBlue)
        case .alwaysAvailable: ("checkmark.circle.fill", .systemGreen)
        case .availableOnDevice: ("checkmark.circle", .systemGreen)
        case .syncing: ("arrow.triangle.2.circlepath", .systemBlue)
        case .error: ("xmark.circle.fill", .systemRed)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: status.title)?
            .withSymbolConfiguration(configuration)
    }
}

/// The Status column's cell: the glyph alone, its wording as the tooltip and for VoiceOver.
final class StatusCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        self.imageView = imageView
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func show(_ status: CloudStatus?) {
        imageView?.image = status.flatMap { CloudStatusGlyph.image(for: $0) }
        toolTip = status?.title
        setAccessibilityLabel(status?.title)
    }
}
