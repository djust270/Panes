import AppKit
import ExplorerCore

/// The Properties dialog's Details tab: Property | Value, under Windows' headings (Description,
/// Origin, Image, Camera…), ending with the File section. Read from Spotlight in the background.
@MainActor
final class PropertiesDetailsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case heading(String)
        case value(String, String)
    }

    private let table = NSTableView()
    private var rows: [Row] = []

    init(url: URL) {
        super.init(frame: .zero)
        let property = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("property"))
        property.title = "Property"
        property.width = 130
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = "Value"
        value.width = 200
        table.addTableColumn(property)
        table.addTableColumn(value)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.style = .plain
        table.floatsGroupRows = false
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 400),
        ])

        let file = fileSection(url)
        Task { [weak self] in
            let sections = await Task.detached(priority: .userInitiated) { FileMetadata.sections(for: url) }.value
            self?.show(sections + [file])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Windows' "File" section: name, type, folder, dates, size, attributes, owner, computer.
    private func fileSection(_ url: URL) -> MetadataSection {
        let item = FileItem.load(url)
        let keys: Set<URLResourceKey> = [.isHiddenKey, .isUserImmutableKey]
        let values = try? url.resourceValues(forKeys: keys)
        let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountName] as? String
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var attributes: [String] = []
        if values?.isUserImmutable == true { attributes.append("Read-only") }
        if values?.isHidden == true { attributes.append("Hidden") }
        let rows: [(String, String?)] = [
            ("Name", url.lastPathComponent),
            ("Item type", item?.typeDescription),
            ("Folder path", url.deletingLastPathComponent().path),
            ("Date created", item?.dateCreated.map(formatter.string)),
            ("Date modified", item?.dateModified.map(formatter.string)),
            ("Size", item?.size.map { FileSizeFormat.string(for: $0) }),
            ("Attributes", attributes.joined(separator: ", ")),
            ("Owner", owner),
            ("Computer", Host.current().localizedName.map { "\($0) (this Mac)" }),
        ]
        return MetadataSection(title: "File", rows: rows.compactMap { name, value in
            guard let value, !value.isEmpty else { return nil }
            return MetadataSection.Row(name: name, value: value)
        })
    }

    private func show(_ sections: [MetadataSection]) {
        rows = sections.flatMap { section in
            [Row.heading(section.title)] + section.rows.map { Row.value($0.name, $0.value) }
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        let field: NSTextField
        switch rows[row] {
        case .heading(let title):
            field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: 12, weight: .semibold)
            text = title
        case .value(let name, let value):
            let isName = tableColumn?.identifier.rawValue == "property"
            text = isName ? name : value
            field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = isName ? .secondaryLabelColor : .labelColor
            field.isSelectable = !isName
            field.toolTip = isName ? nil : value
        }
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
