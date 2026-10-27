import AppKit
import ExplorerCore

/// The icon, List, Tiles and Content views. Rubber-band selection and ⌘/⇧-click come from
/// `NSCollectionView`; this adds double-click and Return to open, Del to delete, and records
/// which item a context menu was opened on.
final class FileCollectionView: NSCollectionView {
    var onActivateSelection: (() -> Void)?
    var onTypeAhead: ((String) -> Bool)?
    /// Middle-click on an item.
    var onMiddleClick: ((IndexPath) -> Void)?
    /// The item under the last right-click, or `nil` for the background.
    private(set) var clickedIndexPath: IndexPath?

    override func keyDown(with event: NSEvent) {
        if !FileViewKeys.handle(event, from: self, activate: onActivateSelection, typeAhead: onTypeAhead) {
            super.keyDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onMiddleClick?(indexPath)
        } else {
            super.otherMouseUp(with: event)
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
/// delegate); List view runs in columns and scrolls sideways, unless grouped. Home mixes
/// tiles and full-width rows, sized by the delegate.
final class FileCollectionLayout: NSCollectionViewFlowLayout {
    let viewMode: ViewMode
    let isGrouped: Bool
    let isHome: Bool
    /// The zoom the item sizes were made for.
    let zoom = Theme.zoom

    init(viewMode: ViewMode, isGrouped: Bool, isHome: Bool = false) {
        self.viewMode = viewMode
        self.isGrouped = isGrouped
        self.isHome = isHome
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

    /// At 100%: icon grids 280×304, 120×144, 84×96 (two lines of name under the icon); rows
    /// 22 high; tiles 260×64; content rows 60 high. Zooming grows the text's share; the
    /// icons keep their size.
    static func itemSize(for mode: ViewMode) -> NSSize {
        switch mode {
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            let width: CGFloat = mode == .extraLargeIcons ? 280 : (mode == .largeIcons ? 120 : 84)
            return NSSize(width: width + Theme.zoomed(60) - 60, height: mode.iconSize + 10 + Theme.zoomed(38))
        case .smallIcons: return NSSize(width: Theme.zoomed(220), height: Theme.zoomed(22))
        case .list: return NSSize(width: Theme.zoomed(240), height: Theme.zoomed(22))
        case .tiles: return NSSize(width: 60 + Theme.zoomed(200), height: max(64, Theme.zoomed(46) + 18))
        case .content: return NSSize(width: 600, height: max(60, Theme.zoomed(34) + 26))
        case .details: return NSSize(width: Theme.zoomed(300), height: Theme.zoomed(22))
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        if viewMode == .content || isHome, let collectionView, newBounds.width != collectionView.bounds.width {
            return true
        }
        return super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}
