import AppKit
import ExplorerCore

/// The Details view: one table column per `FileColumn`, shown, hidden and ordered from the
/// folder's settings. Group headers are full-width group rows. Column widths are app-wide.
extension ContentViewController: NSTableViewDataSource, NSTableViewDelegate {
    private static let columnWidthsKey = "DetailsColumnWidths"

    func configureTableView() {
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .fullWidth
        tableView.backgroundColor = Theme.paneColor
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.allowsTypeSelect = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.floatsGroupRows = false
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Theme.detailsRowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.onActivateSelection = { [weak self] in self?.activateSelection() }
        tableView.onTypeAhead = { [weak self] text in self?.typeAhead(text) ?? false }
        tableView.onMiddleClick = { [weak self] row in
            guard let item = self?.listContent.item(atRow: row) else { return }
            self?.openInNewTab(item)
        }
        tableView.selectableRows = { [weak self] rows in
            rows.filteredIndexSet { self?.listContent.item(atRow: $0) != nil }
        }
        tableView.dragColumnIdentifier = Self.identifier(.name)
        tableView.menu = makeContextMenu()
        tableView.headerView = FileHeaderView(frame: tableView.headerView?.frame ?? .zero)
        tableView.headerView?.menu = makeHeaderMenu()
        configureDragAndDrop()

        let widths = UserDefaults.standard.dictionary(forKey: Self.columnWidthsKey) as? [String: Double] ?? [:]
        for column in FileColumn.allCases {
            let tableColumn = NSTableColumn(identifier: Self.identifier(column))
            tableColumn.headerCell = FileHeaderCell(textCell: column.title)
            tableColumn.title = column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableColumn.minWidth = column == .name ? 120 : 50
            tableColumn.width = widths[column.rawValue].map { CGFloat($0) } ?? Self.defaultWidth(column)
            tableView.addTableColumn(tableColumn)
        }
    }

    static func identifier(_ column: FileColumn) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(column.rawValue)
    }

    private static func defaultWidth(_ column: FileColumn) -> CGFloat {
        switch column {
        case .name: return 320
        case .originalLocation, .folder: return 260
        case .dateDeleted, .dateModified, .dateCreated: return 150
        case .type: return 120
        case .tags: return 120
        case .size, .dimensions, .duration: return 90
        case .totalSize, .freeSpace: return 110
        }
    }

    /// Pushes visible columns, their order and the sort indicator into the table.
    func applyTableSettings() {
        for tableColumn in tableView.tableColumns {
            guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.isHidden = !settings.columns.contains(column)
        }
        for (target, column) in settings.columns.enumerated() {
            let current = tableView.column(withIdentifier: Self.identifier(column))
            if current >= 0, current != target {
                tableView.moveColumn(current, toColumn: target)
            }
        }
        let descriptor = NSSortDescriptor(key: sortColumn.rawValue, ascending: settings.sort.ascending)
        if tableView.sortDescriptors.first != descriptor {
            tableView.sortDescriptors = [descriptor]
        }
    }

    /// The column whose header shows the sort indicator.
    private var sortColumn: FileColumn {
        FileColumn.allCases.first { $0.sortKey == settings.sort.key } ?? .name
    }

    var nameColumnIndex: Int {
        tableView.column(withIdentifier: Self.identifier(.name))
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        listContent.rows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSettings,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = FileColumn(rawValue: key) else { return }
        updateSettings { $0.sort = FileItemSort(key: column.sortKey, ascending: descriptor.ascending) }
    }

    // MARK: Delegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ExplorerRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        listContent.header(atRow: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        listContent.header(atRow: row) != nil ? GroupHeaderView.height : tableView.rowHeight
    }

    func tableView(
        _ tableView: NSTableView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        proposedSelectionIndexes.filteredIndexSet { listContent.item(atRow: $0) != nil }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let section = listContent.header(atRow: row) {
            let header = tableView.makeView(withIdentifier: GroupHeaderView.identifier, owner: self) as? GroupHeaderView
                ?? GroupHeaderView()
            configure(header, section: section)
            return header
        }
        guard let identifier = tableColumn?.identifier,
              let column = FileColumn(rawValue: identifier.rawValue),
              let item = listContent.item(atRow: row) else { return nil }

        let cellIdentifier = NSUserInterfaceItemIdentifier("cell-\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell(for: column, identifier: cellIdentifier)

        cell.textField?.stringValue = text(for: column, item: item)
        // Set on every use, so reused cells follow a style change. Windows 98 has no grey columns.
        cell.textField?.font = Theme.font(ofSize: 12)
        if column != .name { cell.textField?.textColor = Theme.isClassic ? .labelColor : .secondaryLabelColor }
        if let nameCell = cell as? NameCellView {
            nameCell.imageView?.image = icon(for: item)
            nameCell.showsCheckbox = showsCheckboxes
            nameCell.checkbox.state = tableView.isRowSelected(row) ? .on : .off
            nameCell.onToggle = { [weak self] in self?.toggleSelection(of: item.url) }
        }
        cell.alphaValue = isCut(item) ? 0.45 : 1
        return cell
    }

    func configure(_ header: GroupHeaderView, section: Int) {
        guard let group = listContent.sections[section].group else { return }
        header.configure(group: group, isCollapsed: listContent.sections[section].isCollapsed)
        header.onToggle = { [weak self] in self?.toggleGroup(group.id) }
        header.onSelect = { [weak self] in self?.selectGroup(group.id) }
    }

    private func makeCell(for column: FileColumn, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if column == .name {
            let cell = NameCellView()
            cell.identifier = identifier
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = Theme.font(ofSize: 12)
        textField.textColor = .secondaryLabelColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // swiftlint:disable:next cyclomatic_complexity
    func text(for column: FileColumn, item: FileItem) -> String {
        switch column {
        case .name: return item.displayName(showingExtensions: AppSettings.showsFileExtensions)
        case .originalLocation: return item.originalFolderPath
        case .dateDeleted: return item.trashInfo?.dateDeleted.map { dateFormatter.string(from: $0) } ?? ""
        case .dateModified: return item.dateModified.map { dateFormatter.string(from: $0) } ?? ""
        case .dateCreated: return item.dateCreated.map { dateFormatter.string(from: $0) } ?? ""
        case .type: return mode == .network ? "Computer" : item.typeDescription
        case .size: return item.size.map { FileSizeFormat.string(for: $0) } ?? ""
        case .tags: return item.properties?.tagsText ?? ""
        case .dimensions: return item.properties?.dimensionsText ?? ""
        case .duration: return item.properties?.durationText ?? ""
        case .folder: return Self.displayPath(item.folderPath)
        case .totalSize: return item.volume?.totalCapacity.map { FileSizeFormat.string(for: $0) } ?? ""
        case .freeSpace: return item.volume?.availableCapacity.map { FileSizeFormat.string(for: $0) } ?? ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionDidChange()
    }

    func updateVisibleCheckboxes() {
        let column = nameColumnIndex
        guard column >= 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<visible.location + visible.length {
            let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NameCellView
            cell?.checkbox.state = tableView.isRowSelected(row) ? .on : .off
        }
    }

    // MARK: Column changes by the user

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !isApplyingSettings else { return }
        let order = tableView.tableColumns.compactMap { tableColumn -> FileColumn? in
            guard !tableColumn.isHidden else { return nil }
            return FileColumn(rawValue: tableColumn.identifier.rawValue)
        }
        updateSettings { $0.columns = order }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isApplyingSettings,
              let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        var widths = UserDefaults.standard.dictionary(forKey: Self.columnWidthsKey) as? [String: Double] ?? [:]
        widths[tableColumn.identifier.rawValue] = Double(tableColumn.width)
        UserDefaults.standard.set(widths, forKey: Self.columnWidthsKey)
    }

    /// Widens `column` to fit its longest value (Windows' "Size column to fit").
    func sizeColumnToFit(_ column: FileColumn) {
        guard let tableColumn = tableView.tableColumn(withIdentifier: Self.identifier(column)) else { return }
        let font = Theme.font(ofSize: 12)
        let header = (column.title as NSString).size(withAttributes: [.font: font]).width + 24
        let widest = allItems.prefix(5000).reduce(header) { widest, item in
            let width = (text(for: column, item: item) as NSString).size(withAttributes: [.font: font]).width
            return max(widest, width)
        }
        let extra: CGFloat = column == .name ? (showsCheckboxes ? 52 : 32) : 12
        tableColumn.width = max(tableColumn.minWidth, ceil(widest + extra))
    }
}

/// The Name cell: optional checkbox, icon, name.
final class NameCellView: NSTableCellView {
    let checkbox: NSButton = {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.setAccessibilityLabel("Select")
        return checkbox
    }()
    var onToggle: (() -> Void)?

    var showsCheckbox = false {
        didSet {
            checkbox.isHidden = !showsCheckbox
            iconLeading.constant = showsCheckbox ? 22 : 2
        }
    }

    private var iconLeading: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let imageView = NSImageView()
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = Theme.font(ofSize: 12)
        checkbox.target = self
        checkbox.action = #selector(toggle)
        checkbox.isHidden = true
        for subview in [checkbox, imageView, textField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        self.imageView = imageView
        self.textField = textField

        iconLeading = imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLeading,
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggle() {
        onToggle?()
    }
}
