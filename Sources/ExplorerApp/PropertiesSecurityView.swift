import AppKit
import ExplorerCore

/// The Properties dialog's Security tab, in Windows' form: "Group or user names" (the owner,
/// the group, Everyone, then any access control entries) and, for the selected name, Allow and
/// Deny for Full control, Modify, Read & execute, Read and Write. The owner can change the
/// owner, group and Everyone rows (POSIX permissions); access control entries are read-only.
@MainActor
final class PropertiesSecurityView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: (() -> Void)?

    private let url: URL
    private let isDirectory: Bool
    private let owner: String
    private let group: String
    private let canEdit: Bool
    private var mode: Int
    private var appliedMode: Int
    private var entries: [PermissionEntry] = []
    private let accessControl: [PermissionEntry]

    private let table = NSTableView()
    private let permissionsTitle = NSTextField(labelWithString: "")
    private var allowBoxes: [WindowsPermission: NSButton] = [:]
    private var denyBoxes: [WindowsPermission: NSButton] = [:]

    init(url: URL) {
        self.url = url
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        owner = attributes[.ownerAccountName] as? String ?? "unknown"
        group = attributes[.groupOwnerAccountName] as? String ?? "unknown"
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        canEdit = getuid() == 0 || ownerID == getuid()
        mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        appliedMode = mode
        accessControl = WindowsPermissions.accessControlEntries(of: url, isDirectory: isDirectory)
        super.init(frame: .zero)
        rebuildEntries()
        buildContent()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPermissions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func rebuildEntries() {
        entries = WindowsPermissions.combined(
            posix: WindowsPermissions.posixEntries(mode: mode, owner: owner, group: group, isDirectory: isDirectory),
            accessControl: accessControl
        )
    }

    // MARK: Layout

    private func buildContent() {
        let objectName = PropertiesLayout.value(url.path)
        let objectRow = NSStackView(views: [PropertiesLayout.label("Object name:"), objectName])
        objectRow.alignment = .firstBaseline

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let grid = makePermissionGrid()

        let note = NSTextField(wrappingLabelWithString: canEdit
            ? "You can change the owner, group and Everyone. Access control entries are shown but not changed here."
            : "Only \(owner), the owner, can change these permissions.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let ownerRow = NSStackView(views: [PropertiesLayout.label("Owner:"), PropertiesLayout.value(owner)])
        ownerRow.alignment = .firstBaseline

        let stack = NSStackView(views: [
            objectRow, PropertiesLayout.label("Group or user names:"), scroll, grid,
            PropertiesLayout.separator(), ownerRow, note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(14, after: scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            objectName.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -90),
        ])
    }

    /// "Permissions for …" with Allow and Deny checkboxes for each permission.
    private func makePermissionGrid() -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        permissionsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        permissionsTitle.lineBreakMode = .byTruncatingTail
        let header = grid.addRow(with: [
            permissionsTitle, PropertiesLayout.label("Allow"), PropertiesLayout.label("Deny"),
        ])
        header.bottomPadding = 4
        for permission in WindowsPermission.rows(forDirectory: isDirectory) {
            let allow = NSButton(checkboxWithTitle: "", target: self, action: #selector(allowChanged(_:)))
            let deny = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            allow.identifier = NSUserInterfaceItemIdentifier(permission.rawValue)
            allowBoxes[permission] = allow
            denyBoxes[permission] = deny
            grid.addRow(with: [PropertiesLayout.value(permission.title), allow, deny])
        }
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).xPlacement = .center
        permissionsTitle.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return grid
    }

    // MARK: Names list

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(
            systemSymbolName: entry.source == .owner ? "person.fill" : "person.2.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        let text = NSTextField(labelWithString: entry.name)
        text.lineBreakMode = .byTruncatingTail
        for view in [icon, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showPermissions()
    }

    // MARK: Permissions

    private var selectedEntry: PermissionEntry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func showPermissions() {
        guard let entry = selectedEntry else {
            permissionsTitle.stringValue = "Permissions"
            allowBoxes.values.forEach { $0.state = .off; $0.isEnabled = false }
            denyBoxes.values.forEach { $0.state = .off; $0.isEnabled = false }
            return
        }
        permissionsTitle.stringValue = "Permissions for \(entry.name)"
        for (permission, box) in allowBoxes {
            box.state = entry.allowed.contains(permission) ? .on : .off
            // Full control needs ownership; Special has no POSIX bits.
            let editable = canEdit && entry.isPosix && permission != .special
                && (permission != .fullControl || entry.source == .owner)
            box.isEnabled = editable
        }
        for (permission, box) in denyBoxes {
            box.state = entry.denied.contains(permission) ? .on : .off
            box.isEnabled = false
        }
    }

    @objc private func allowChanged(_ sender: NSButton) {
        guard let entry = selectedEntry, entry.isPosix,
              let raw = sender.identifier?.rawValue, let permission = WindowsPermission(rawValue: raw) else { return }
        let shift: Int
        switch entry.source {
        case .owner: shift = 6
        case .group: shift = 3
        default: shift = 0
        }
        let current = PosixAccess(rawValue: (mode >> shift) & 7)
        let updated = WindowsPermissions.access(current, setting: permission, to: sender.state == .on,
                                                isDirectory: isDirectory)
        mode = WindowsPermissions.mode(mode, setting: updated, for: entry.source)
        let row = table.selectedRow
        rebuildEntries()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        showPermissions()
        onChange?()
    }

    /// Writes changed POSIX permissions. Returns an error message on failure.
    func apply() async -> String? {
        guard mode != appliedMode else { return nil }
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            appliedMode = mode
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
