import AppKit
import ExplorerCore

/// The icon views, List, Tiles and Content: one `NSCollectionView` section per group, with the
/// group header as a section header. Collapsed groups keep their header but no items.
extension ContentViewController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func configureCollectionView() {
        // Registrations made before the collection view has a layout are silently dropped,
        // so the first `makeItem` would throw. Give it one up front.
        collectionView.collectionViewLayout = FileCollectionLayout(viewMode: .mediumIcons, isGrouped: false)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FileCollectionItem.self, forItemWithIdentifier: FileCollectionItem.identifier)
        collectionView.register(
            GroupHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: GroupHeaderView.identifier
        )
        collectionView.onActivateSelection = { [weak self] in self?.activateSelection() }
        collectionView.menu = makeContextMenu()
        configureCollectionDragAndDrop()
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        listContent.sections.count
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        listContent.sections[section].items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let made = collectionView.makeItem(withIdentifier: FileCollectionItem.identifier, for: indexPath)
        if let cell = made as? FileCollectionItem {
            configure(cell, at: indexPath)
        }
        return made
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: GroupHeaderView.identifier,
            for: indexPath
        )
        if let header = view as? GroupHeaderView {
            configure(header, section: indexPath.section)
        }
        return view
    }

    func configure(_ cell: FileCollectionItem, at indexPath: IndexPath) {
        guard let item = listContent.item(section: indexPath.section, index: indexPath.item) else { return }
        let viewMode = settings.viewMode
        var image = icon(for: item)
        if viewMode.showsThumbnails {
            let url = item.url.standardizedFileURL
            let scale = view.window?.backingScaleFactor ?? 2
            let thumbnail = ThumbnailProvider.shared.thumbnail(
                for: item,
                size: viewMode.iconSize,
                scale: scale
            ) { [weak cell] image in
                cell?.setImage(image, for: url)
            }
            image = thumbnail ?? image
        }
        cell.configure(
            with: item,
            mode: viewMode,
            image: image,
            details: detailText(for: item, mode: viewMode),
            isCut: isCut(item)
        )
        cell.showsCheckbox = showsCheckboxes
        cell.onToggleCheckbox = { [weak self] _ in self?.toggleSelection(of: item.url) }
    }

    /// Tiles: type and size under the name. Content: type under the name; date modified and
    /// size on the right.
    private func detailText(for item: FileItem, mode: ViewMode) -> ItemDetailText {
        let size = item.size.map { FileSizeFormat.string(for: $0) } ?? ""
        switch mode {
        case .tiles:
            return ItemDetailText(line2: item.typeDescription, line3: size)
        case .content:
            let modified = item.dateModified.map { "Date modified: " + dateFormatter.string(from: $0) } ?? ""
            return ItemDetailText(
                line2: item.typeDescription,
                right1: modified,
                right2: size.isEmpty ? "" : "Size: \(size)"
            )
        default:
            return ItemDetailText()
        }
    }

    // MARK: Layout

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        guard let layout = collectionViewLayout as? FileCollectionLayout else { return .zero }
        var size = layout.itemSize
        if layout.viewMode == .content {
            size.width = max(300, collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right)
        }
        return size
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }
}
