import AppKit
import ExplorerCore
import Quartz

/// The pane on the right of the window: Preview (Quick Look) or Details (thumbnail and
/// properties). Which one is shown is app-wide, as on Windows.
@MainActor
final class SidePaneViewController: NSViewController {
    enum Pane: String {
        case none
        case preview
        case details
    }

    private static let paneKey = "SidePane"

    static var savedPane: Pane {
        get { UserDefaults.standard.string(forKey: paneKey).flatMap(Pane.init) ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: paneKey) }
    }

    private(set) var pane: Pane = .none
    private let preview = PreviewPaneView()
    private let details = DetailsPaneView()
    /// The last selection shown, re-applied when switching panes.
    private var selection: [FileItem] = []
    private var folder: (name: String, itemCount: Int) = ("", 0)

    override func loadView() {
        let container = NSView()
        for pane in [preview, details] as [NSView] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: container.topAnchor),
                pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        view = container
        show(.none)
    }

    func show(_ pane: Pane) {
        self.pane = pane
        preview.isHidden = pane != .preview
        details.isHidden = pane != .details
        refresh()
    }

    /// Called whenever the selection or the folder's contents change.
    func update(selection: [FileItem], folderName: String, itemCount: Int) {
        self.selection = selection
        folder = (folderName, itemCount)
        refresh()
    }

    private func refresh() {
        switch pane {
        case .none: preview.show(nil)
        case .preview: preview.show(selection.count == 1 ? selection.first : nil)
        case .details: details.show(selection: selection, folderName: folder.name, itemCount: folder.itemCount)
        }
    }
}

/// Quick Look of the single selected file, or "Select a file to preview."
private final class PreviewPaneView: NSView {
    private let quickLook: QLPreviewView? = QLPreviewView(frame: .zero, style: .normal)
    private let message = NSTextField(labelWithString: "Select a file to preview.")
    private var shownURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
        if let quickLook {
            quickLook.autostarts = true
            quickLook.shouldCloseWithWindow = false
            quickLook.translatesAutoresizingMaskIntoConstraints = false
            addSubview(quickLook)
            NSLayoutConstraint.activate([
                quickLook.topAnchor.constraint(equalTo: topAnchor),
                quickLook.leadingAnchor.constraint(equalTo: leadingAnchor),
                quickLook.trailingAnchor.constraint(equalTo: trailingAnchor),
                quickLook.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ item: FileItem?) {
        let url = item.flatMap { $0.kind == .file || $0.kind == .package ? $0.url : nil }
        guard url != shownURL else { return }
        shownURL = url
        message.isHidden = url != nil
        quickLook?.isHidden = url == nil
        quickLook?.previewItem = url.map { $0 as NSURL }
    }
}

/// Thumbnail, name, type and properties of the selection; the folder's item count when
/// nothing is selected; the count and total size for several items.
private final class DetailsPaneView: NSView {
    private let imageView = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private var propertiesTask: Task<Void, Never>?
    private var shownItem: FileItem?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.maximumNumberOfLines = 3
        subtitle.textColor = .secondaryLabelColor
        grid.rowSpacing = 6
        grid.columnSpacing = 10

        let stack = NSStackView(views: [imageView, title, subtitle, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            imageView.heightAnchor.constraint(equalToConstant: 160),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(selection: [FileItem], folderName: String, itemCount: Int) {
        propertiesTask?.cancel()
        guard selection.count == 1, let item = selection.first else {
            shownItem = nil
            showSummary(selection: selection, folderName: folderName, itemCount: itemCount)
            return
        }
        guard item != shownItem else { return }
        shownItem = item

        title.stringValue = item.displayName(showingExtensions: AppSettings.showsFileExtensions)
        subtitle.stringValue = item.typeDescription
        imageView.image = NSWorkspace.shared.icon(forFile: item.url.path)
        let scale = window?.backingScaleFactor ?? 2
        let thumbnail = ThumbnailProvider.shared.thumbnail(for: item, size: 160, scale: scale) { [weak self] image in
            guard self?.shownItem?.url == item.url else { return }
            self?.imageView.image = image
        }
        if let thumbnail { imageView.image = thumbnail }
        setRows(rows(for: item, properties: nil))

        propertiesTask = Task { [weak self] in
            let properties = await Task.detached(priority: .userInitiated) { FilePropertiesReader.read(item) }.value
            guard !Task.isCancelled, let self, shownItem == item else { return }
            setRows(rows(for: item, properties: properties))
        }
    }

    private func showSummary(selection: [FileItem], folderName: String, itemCount: Int) {
        imageView.image = NSImage(systemSymbolName: selection.isEmpty ? "folder" : "doc.on.doc",
                                  accessibilityDescription: nil)
        if selection.isEmpty {
            title.stringValue = folderName
            subtitle.stringValue = itemCount == 1 ? "1 item" : "\(itemCount) items"
            setRows([])
        } else {
            title.stringValue = "\(selection.count) items selected"
            subtitle.stringValue = ""
            let files = selection.compactMap(\.size)
            setRows(files.isEmpty ? [] : [("Total size", FileSizeFormat.string(for: files.reduce(0, +)))])
        }
    }

    private func rows(for item: FileItem, properties: FileProperties?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let size = item.size { rows.append(("Size", FileSizeFormat.string(for: size))) }
        if let date = item.dateModified { rows.append(("Date modified", dateFormatter.string(from: date))) }
        if let date = item.dateCreated { rows.append(("Date created", dateFormatter.string(from: date))) }
        if let properties {
            if !properties.dimensionsText.isEmpty { rows.append(("Dimensions", properties.dimensionsText)) }
            if !properties.durationText.isEmpty { rows.append(("Duration", properties.durationText)) }
            if !properties.tags.isEmpty { rows.append(("Tags", properties.tagsText)) }
        }
        rows.append(("Location", item.url.deletingLastPathComponent().path))
        return rows
    }

    private func setRows(_ rows: [(String, String)]) {
        // removeRow(at:) leaves the row's views in the grid, still drawing where they were.
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        grid.subviews.forEach { $0.removeFromSuperview() }
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: 12)
            field.isSelectable = true
            grid.addRow(with: [label, field])
        }
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
        }
        updateValueWidths()
    }

    override func layout() {
        super.layout()
        updateValueWidths()
    }

    /// Wrapping labels report their one-line width unless told how wide they may be, so
    /// long values (Location) would run off the pane; give them what the names leave.
    private func updateValueWidths() {
        guard grid.numberOfRows > 0 else { return }
        let cells = (0..<grid.numberOfRows).map { grid.row(at: $0) }
        let nameWidth = cells.compactMap { $0.cell(at: 0).contentView?.fittingSize.width }.max() ?? 0
        let valueWidth = max(40, bounds.width - 32 - nameWidth - grid.columnSpacing).rounded(.down)
        for row in cells {
            guard let field = row.cell(at: 1).contentView as? NSTextField,
                  field.preferredMaxLayoutWidth != valueWidth else { continue }
            field.preferredMaxLayoutWidth = valueWidth
        }
    }
}
