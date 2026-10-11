import AppKit
import ExplorerCore

/// Details view: a sortable, resizable `NSTableView` of the current folder's contents.
///
/// Phase 3 adds the other view modes (icons, list, tiles); Phase 1 is Details-only.
@MainActor
final class ContentViewController: NSViewController {
    private enum Column: String, CaseIterable {
        case name
        case dateModified = "date-modified"
        case type
        case size

        var title: String {
            switch self {
            case .name: return "Name"
            case .dateModified: return "Date modified"
            case .type: return "Type"
            case .size: return "Size"
            }
        }

        var sortKey: FileItemSortKey {
            switch self {
            case .name: return .name
            case .dateModified: return .dateModified
            case .type: return .type
            case .size: return .size
            }
        }
    }

    var onNavigate: ((ExplorerLocation) -> Void)?
    var onSelectionChange: (() -> Void)?

    /// The current folder's unsorted contents, as last supplied by `setItems`.
    private(set) var items: [FileItem] = []
    /// What the table actually shows, after applying `sort`.
    private(set) var sortedItems: [FileItem] = []
    var sort = FileItemSort() {
        didSet {
            guard sort != oldValue else { return }
            resortAndReload()
        }
    }

    /// Items currently selected, in table order.
    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { sortedItems.indices.contains($0) ? sortedItems[$0] : nil }
    }

    private let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let unavailableLabel = NSTextField(labelWithString: "")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            switch column {
            case .name:
                tableColumn.width = 320
                tableColumn.minWidth = 120
            case .dateModified:
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
    }

    /// Replaces the folder's contents, preserving the selection by URL where possible.
    func setItems(_ newItems: [FileItem]) {
        unavailableLabel.isHidden = true
        scrollView.isHidden = false

        let selectedURLs = Set(selectedItems.map(\.url))
        items = newItems
        resortAndReload()

        let rowsToSelect = IndexSet(sortedItems.indices.filter { selectedURLs.contains(sortedItems[$0].url) })
        tableView.selectRowIndexes(rowsToSelect, byExtendingSelection: false)
    }

    /// Shows a centered message instead of the table, for locations with no Details view yet.
    func showUnavailable(_ message: String) {
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

    @objc private func activateSelection() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
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
        case .dateModified: return item.dateModified.map { dateFormatter.string(from: $0) } ?? ""
        case .type: return item.typeDescription
        case .size: return item.size.map { FileSizeFormat.string(for: $0) } ?? ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }
}
