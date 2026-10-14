import AppKit
import ExplorerCore

/// The icon views, List, Tiles and Content: one `NSCollectionView` section per group, with the
/// group header as a section header. Collapsed groups keep their header but no items.
///
/// Home also uses the collection view, with a layout per section: Quick access as tiles,
/// Favorites and Recent as full-width rows (name, date used, folder), as on Windows 11.
extension ContentViewController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func configureCollectionView() {
        // Registrations made before the collection view has a layout are silently dropped,
        // so the first `makeItem` would throw. Give it one up front.
        collectionView.collectionViewLayout = FileCollectionLayout(viewMode: .mediumIcons, isGrouped: false)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [Theme.bodyColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FileCollectionItem.self, forItemWithIdentifier: FileCollectionItem.identifier)
        collectionView.register(
            GroupHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: GroupHeaderView.identifier
        )
        collectionView.onActivateSelection = { [weak self] in self?.activateSelection() }
        collectionView.onTypeAhead = { [weak self] text in self?.typeAhead(text) ?? false }
        collectionView.onMiddleClick = { [weak self] indexPath in
            guard let item = self?.listContent.item(section: indexPath.section, index: indexPath.item) else { return }
            self?.openInNewTab(item)
        }
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
        let viewMode = cellMode(forSection: indexPath.section)
        var image = icon(for: item)
        if viewMode.showsThumbnails, mode != .home, listsFiles {
            let url = item.url
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

    /// A folder path with the home folder shortened to "~", or named when it's the home folder
    /// itself (a lone "~" reads as a typo).
    static func displayPath(_ path: String) -> String {
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        return abbreviated == "~" ? FileManager.default.displayName(atPath: path) : abbreviated
    }

    /// How items in `section` are drawn: the view mode, or Home's tiles and rows.
    private func cellMode(forSection section: Int) -> ViewMode {
        guard mode == .home else { return settings.viewMode }
        let group = HomeSection(groupID: listContent.sections[section].group?.id)
        return group == .quickAccess ? .tiles : .details
    }

    /// Tiles: type and size under the name. Content: type (or, in search results, the folder)
    /// under the name; date modified and size on the right. Home: the folder, and when a
    /// file was last used.
    private func detailText(for item: FileItem, mode viewMode: ViewMode) -> ItemDetailText {
        let size = item.size.map { FileSizeFormat.string(for: $0) } ?? ""
        let folder = Self.displayPath(item.folderPath)
        if let volume = item.volume {
            return driveDetailText(volume, mode: viewMode)
        }
        if mode == .network {
            let address = item.url.absoluteString
            return viewMode == .content ? ItemDetailText(line2: address, right1: "Computer")
                : ItemDetailText(line2: "Computer", line3: address)
        }
        if mode == .home {
            if viewMode == .tiles {
                return ItemDetailText(line2: folder, line3: QuickAccess.store.isPinned(item.url) ? "Pinned" : "")
            }
            let used = homeDates[item.url.path] ?? item.dateModified
            return ItemDetailText(line2: folder, right1: used.map { dateFormatter.string(from: $0) } ?? "")
        }
        switch viewMode {
        case .tiles:
            return ItemDetailText(line2: item.typeDescription, line3: size)
        case .content:
            let modified = item.dateModified.map { "Date modified: " + dateFormatter.string(from: $0) } ?? ""
            return ItemDetailText(
                line2: mode == .search ? folder : item.typeDescription,
                right1: modified,
                right2: size.isEmpty ? "" : "Size: \(size)"
            )
        default:
            return ItemDetailText()
        }
    }

    /// This PC: the capacity bar and "X free of Y" on tiles; type, free space and size in Content.
    private func driveDetailText(_ volume: MountedVolume, mode viewMode: ViewMode) -> ItemDetailText {
        switch viewMode {
        case .tiles:
            return ItemDetailText(line3: volume.capacityText, capacity: volume.usedFraction,
                                  capacityIsLow: volume.isNearlyFull)
        case .content:
            let free = volume.availableCapacity.map { "Free space: " + FileSizeFormat.string(for: $0) } ?? ""
            let total = volume.totalCapacity.map { "Total size: " + FileSizeFormat.string(for: $0) } ?? ""
            return ItemDetailText(line2: volume.typeDescription, right1: free, right2: total)
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
        let inset = self.collectionView(collectionView, layout: layout, insetForSectionAt: indexPath.section)
        let fullWidth = max(300, collectionView.bounds.width - inset.left - inset.right)
        if mode == .home {
            return cellMode(forSection: indexPath.section) == .tiles
                ? FileCollectionLayout.itemSize(for: .tiles)
                : NSSize(width: fullWidth, height: Theme.detailsRowHeight)
        }
        var size = layout.itemSize
        if layout.viewMode == .content {
            size.width = fullWidth
        }
        return size
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        let layout = collectionViewLayout as? FileCollectionLayout
        if mode == .home, cellMode(forSection: section) != .tiles {
            return NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        }
        return layout?.sectionInset ?? NSEdgeInsetsZero
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
        if mode == .home, cellMode(forSection: section) != .tiles { return 0 }
        return (collectionViewLayout as? FileCollectionLayout)?.minimumLineSpacing ?? 0
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }
}
