import AppKit
import ExplorerCore

/// Receives drops on the content view and the navigation pane. `nil` locations mean "the
/// location the window is showing".
@MainActor
protocol FileDropHandling: AnyObject {
    func dropOperation(
        for urls: [URL],
        into location: ExplorerLocation?,
        sourceMask: NSDragOperation
    ) -> NSDragOperation
    func performDrop(of urls: [URL], into location: ExplorerLocation?, operation: NSDragOperation)
    func canReceivePromises(into location: ExplorerLocation?) -> Bool
    func receivePromises(_ receivers: [NSFilePromiseReceiver], into location: ExplorerLocation?)
    /// Items dragged out to the Dock's Trash.
    func trashDraggedItems(_ urls: [URL])
}

/// Details view: a sortable, resizable `NSTableView` of the current folder's contents.
///
/// Phase 3 adds the other view modes (icons, list, tiles).
@MainActor
final class ContentViewController: NSViewController {
    enum Mode {
        /// A real folder.
        case folder
        /// The Recycle Bin: adds Original Location and Date Deleted columns.
        case recycleBin
        /// This PC's volume list: no file operations.
        case volumes
    }

    enum Column: String, CaseIterable {
        case name
        case originalLocation = "original-location"
        case dateDeleted = "date-deleted"
        case dateModified = "date-modified"
        case type
        case size

        var title: String {
            switch self {
            case .name: return "Name"
            case .originalLocation: return "Original Location"
            case .dateDeleted: return "Date Deleted"
            case .dateModified: return "Date modified"
            case .type: return "Type"
            case .size: return "Size"
            }
        }

        var sortKey: FileItemSortKey {
            switch self {
            case .name: return .name
            case .originalLocation: return .originalLocation
            case .dateDeleted: return .dateDeleted
            case .dateModified: return .dateModified
            case .type: return .type
            case .size: return .size
            }
        }

        var isRecycleBinOnly: Bool { self == .originalLocation || self == .dateDeleted }
    }

    var onNavigate: ((ExplorerLocation) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// The user finished renaming `item` to the given name.
    var onRename: ((FileItem, String) -> Void)?
    weak var dropHandler: FileDropHandling?

    var mode: Mode = .folder {
        didSet {
            guard mode != oldValue else { return }
            applyColumnVisibility()
        }
    }

    /// Items waiting in the clipboard after Cut, drawn dimmed.
    var cutURLs: Set<URL> = [] {
        didSet {
            guard cutURLs != oldValue, renaming == nil else { return }
            reloadVisibleRows()
        }
    }

    /// The current folder's unsorted contents, as last supplied by `setItems`.
    private(set) var items: [FileItem] = []
    /// What the table actually shows, after applying `sort`.
    private(set) var sortedItems: [FileItem] = []
    var sort = FileItemSort() {
        didSet {
            guard sort != oldValue else { return }
            finishRenaming(commit: true)
            resortAndReload()
        }
    }

    /// Items currently selected, in table order.
    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { sortedItems.indices.contains($0) ? sortedItems[$0] : nil }
    }

    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let unavailableLabel = NSTextField(labelWithString: "")
    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Selection (and optionally an item to rename) to apply once those items are loaded.
    private var pendingSelection: [URL]?
    private var pendingRename: URL?
    /// The in-place rename in progress, if any.
    var renaming: (item: FileItem, field: NSTextField)?
    /// Items that arrived while renaming; applied when the rename ends.
    var deferredItems: [FileItem]?

    override func loadView() {
        let container = NSView()

        configureTableView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        unavailableLabel.textColor = .secondaryLabelColor
        unavailableLabel.alignment = .center
        unavailableLabel.isHidden = true
        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(unavailableLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            unavailableLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            unavailableLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
        ])

        view = container
    }

    private func configureTableView() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.onActivateSelection = { [weak self] in self?.activateSelection() }
        tableView.menu = makeContextMenu()
        configureDragAndDrop()

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            switch column {
            case .name:
                tableColumn.width = 320
                tableColumn.minWidth = 120
            case .originalLocation:
                tableColumn.width = 220
                tableColumn.minWidth = 100
            case .dateDeleted, .dateModified:
                tableColumn.width = 150
                tableColumn.minWidth = 100
            case .type:
                tableColumn.width = 120
                tableColumn.minWidth = 80
            case .size:
                tableColumn.width = 90
                tableColumn.minWidth = 60
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        applyColumnVisibility()
    }

    private func applyColumnVisibility() {
        for column in Column.allCases where column.isRecycleBinOnly {
            let tableColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn?.isHidden = mode != .recycleBin
        }
        if mode != .recycleBin, sort.key == .originalLocation || sort.key == .dateDeleted {
            tableView.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        }
    }

    /// Replaces the folder's contents, preserving the selection by URL where possible.
    func setItems(_ newItems: [FileItem]) {
        if renaming != nil {
            deferredItems = newItems
            return
        }
        unavailableLabel.isHidden = true
        scrollView.isHidden = false

        let selectedURLs = Set(selectedItems.map(\.url))
        items = newItems
        resortAndReload()

        var rowsToSelect = IndexSet(sortedItems.indices.filter { selectedURLs.contains(sortedItems[$0].url) })
        if let pending = pendingSelection.map(Set.init) {
            let pendingRows = IndexSet(sortedItems.indices.filter {
                pending.contains(sortedItems[$0].url.standardizedFileURL)
            })
            if !pendingRows.isEmpty {
                rowsToSelect = pendingRows
                pendingSelection = nil
                tableView.scrollRowToVisible(pendingRows.first ?? 0)
            }
        }
        tableView.selectRowIndexes(rowsToSelect, byExtendingSelection: false)

        if let rename = pendingRename, sortedItems.contains(where: { $0.url.standardizedFileURL == rename }) {
            pendingRename = nil
            beginRenaming(rename)
        }
    }

    /// Selects `urls` (now, or once they appear after a reload) and optionally starts renaming one.
    func select(_ urls: [URL], renaming renameURL: URL? = nil) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        let rows = IndexSet(sortedItems.indices.filter { wanted.contains(sortedItems[$0].url.standardizedFileURL) })
        if rows.count == wanted.count, !rows.isEmpty {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            tableView.scrollRowToVisible(rows.first ?? 0)
            if let renameURL { beginRenaming(renameURL) }
        } else {
            pendingSelection = urls.map(\.standardizedFileURL)
            pendingRename = renameURL?.standardizedFileURL
        }
    }

    /// Shows a centered message instead of the table, for locations with no Details view yet.
    func showUnavailable(_ message: String) {
        finishRenaming(commit: false)
        items = []
        sortedItems = []
        tableView.reloadData()
        unavailableLabel.stringValue = message
        unavailableLabel.isHidden = false
        scrollView.isHidden = true
    }

    private func resortAndReload() {
        sortedItems = sort.sorted(items)
        tableView.reloadData()
    }

    private func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
    }

    @objc func activateSelection() {
        let selected = selectedItems
        guard !selected.isEmpty, mode != .recycleBin else { return }
        if selected.count == 1, let only = selected.first, only.isFolder {
            onNavigate?(.folder(only.url))
            return
        }
        for item in selected where !item.isFolder {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func icon(for item: FileItem) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }
}

extension ContentViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedItems.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else { return }
        sort = FileItemSort(key: column.sortKey, ascending: descriptor.ascending)
    }
}

extension ContentViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else {
            return nil
        }
        let item = sortedItems[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("cell-\(column.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeCell(for: column, identifier: cellIdentifier)
        }

        cell.textField?.stringValue = text(for: column, item: item)
        if column == .name {
            cell.imageView?.image = icon(for: item)
        }
        cell.alphaValue = cutURLs.contains(item.url.standardizedFileURL) ? 0.45 : 1
        return cell
    }

    private func makeCell(for column: Column, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        if column == .name {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    private func text(for column: Column, item: FileItem) -> String {
        switch column {
        case .name: return item.name
        case .originalLocation: return item.originalFolderPath
        case .dateDeleted: return item.trashInfo?.dateDeleted.map { dateFormatter.string(from: $0) } ?? ""
        case .dateModified: return item.dateModified.map { dateFormatter.string(from: $0) } ?? ""
        case .type: return item.typeDescription
        case .size: return item.size.map { FileSizeFormat.string(for: $0) } ?? ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }
}
