import AppKit
import ExplorerCore

/// The icon, List, Tiles and Content views. Rubber-band selection and ⌘/⇧-click come from
/// `NSCollectionView`; this adds double-click and Return to open, Del to delete, and records
/// which item a context menu was opened on.
final class FileCollectionView: NSCollectionView {
    var onActivateSelection: (() -> Void)?
    /// The item under the last right-click, or `nil` for the background.
    private(set) var clickedIndexPath: IndexPath?

    override func keyDown(with event: NSEvent) {
        if !FileViewKeys.handle(event, from: self, activate: onActivateSelection) {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, indexPathForItem(at: point) != nil {
            onActivateSelection?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickedIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }
}

/// Flow layout for one view mode. Content view items span the full width (sized by the
/// delegate); List view runs in columns and scrolls sideways, unless grouped.
final class FileCollectionLayout: NSCollectionViewFlowLayout {
    let viewMode: ViewMode
    let isGrouped: Bool

    init(viewMode: ViewMode, isGrouped: Bool) {
        self.viewMode = viewMode
        self.isGrouped = isGrouped
        super.init()
        itemSize = Self.itemSize(for: viewMode)
        switch viewMode {
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            minimumInteritemSpacing = 4
            minimumLineSpacing = 4
            sectionInset = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
        case .smallIcons, .list:
            minimumInteritemSpacing = 2
            minimumLineSpacing = 2
            sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        case .tiles:
            minimumInteritemSpacing = 6
            minimumLineSpacing = 6
            sectionInset = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
        case .content, .details:
            minimumInteritemSpacing = 0
            minimumLineSpacing = 0
            sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        }
        if viewMode == .list, !isGrouped {
            scrollDirection = .horizontal
            minimumLineSpacing = 12
        }
        headerReferenceSize = isGrouped ? NSSize(width: 0, height: GroupHeaderView.height) : .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func itemSize(for mode: ViewMode) -> NSSize {
        switch mode {
        case .extraLargeIcons: return NSSize(width: 280, height: 304)
        case .largeIcons: return NSSize(width: 120, height: 144)
        case .mediumIcons: return NSSize(width: 84, height: 96)
        case .smallIcons: return NSSize(width: 220, height: 22)
        case .list: return NSSize(width: 240, height: 22)
        case .tiles: return NSSize(width: 260, height: 64)
        case .content: return NSSize(width: 600, height: 60)
        case .details: return NSSize(width: 300, height: 22)
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        if viewMode == .content, let collectionView, newBounds.width != collectionView.bounds.width {
            return true
        }
        return super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}
