import AppKit
import ExplorerCore

/// Windows' Properties dialog (Alt+Enter): General, Security and (for files) Details tabs,
/// with OK, Cancel and Apply. Drives get a General tab with a capacity chart. Several can be
/// open at once; asking again for the same items brings their dialog forward.
@MainActor
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    /// Keeps the dialogs alive while they're open.
    private static var open: [PropertiesWindowController] = []

    /// Shows the Properties of `urls` (one item, several, or a drive).
    static func show(_ urls: [URL]) {
        let urls = urls.map(\.standardizedFileURL)
        guard !urls.isEmpty else { return }
        if let existing = open.first(where: { $0.urls == urls }) {
            existing.showWindow(nil)
            return
        }
        let controller = PropertiesWindowController(urls: urls)
        if let last = open.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            controller.window?.center()
        }
        open.append(controller)
        controller.showWindow(nil)
    }

    private(set) var urls: [URL]
    private let general: PropertiesGeneralView
    private let security: PropertiesSecurityView?
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    private init(urls: [URL]) {
        self.urls = urls
        let isDrive = urls.count == 1 && ExplorerLocation.isVolumeRoot(urls[0])
        general = isDrive ? PropertiesGeneralView(drive: urls[0]) : PropertiesGeneralView(items: urls)
        security = urls.count == 1 ? PropertiesSecurityView(url: urls[0]) : nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.title = Self.title(for: urls)
        super.init(window: window)
        window.delegate = self

        let tabs = NSTabView()
        tabs.addTabViewItem(Self.tab("General", general))
        if let security { tabs.addTabViewItem(Self.tab("Security", security)) }
        if urls.count == 1, !isDrive, !(FileItem.load(urls[0])?.isFolder ?? true) {
            tabs.addTabViewItem(Self.tab("Details", PropertiesDetailsView(url: urls[0])))
        }
        general.onChange = { [weak self] in self?.applyButton.isEnabled = true }
        security?.onChange = { [weak self] in self?.applyButton.isEnabled = true }
        window.contentView = makeContent(tabs: tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// "report.docx Properties", or "a.txt, b.txt, … Properties" for several items.
    private static func title(for urls: [URL]) -> String {
        let names = urls.map { FileManager.default.displayName(atPath: $0.path) }
        if names.count == 1 { return "\(names[0]) Properties" }
        return names.prefix(2).joined(separator: ", ") + ", … Properties"
    }

    private static func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        // Tab views start tiny until the tab view sizes them; give them their real size so
        // the content's constraints hold from the start.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 376, height: 460))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        let trailing = view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        trailing.priority = .defaultHigh
        let bottom = view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            trailing,
            bottom,
        ])
        item.view = container
        return item
    }

    private func makeContent(tabs: NSTabView) -> NSView {
        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        applyButton.isEnabled = false
        let buttons = NSStackView(views: [ok, cancel, applyButton])
        buttons.spacing = 8

        let container = NSView()
        for view in [tabs, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            cancel.widthAnchor.constraint(equalTo: ok.widthAnchor),
            applyButton.widthAnchor.constraint(equalTo: ok.widthAnchor),
        ])
        return container
    }

    // MARK: Buttons

    @objc private func okPressed() {
        Task {
            guard await apply() else { return }
            close()
        }
    }

    @objc private func cancelPressed() {
        close()
    }

    @objc private func applyPressed() {
        Task { await apply() }
    }

    /// Applies the changes on every tab; `false` (after telling the user) if one failed.
    @discardableResult
    private func apply() async -> Bool {
        guard applyButton.isEnabled else { return true }
        // Permissions first: a rename on the General tab changes the path.
        var error = await security?.apply()
        if error == nil { error = await general.apply() }
        if let error {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t apply the changes"
            alert.informativeText = error
            if let window { _ = await alert.beginSheetModal(for: window) }
            return false
        }
        applyButton.isEnabled = false
        urls = general.urls
        window?.title = Self.title(for: urls)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        general.stop()
        Self.open.removeAll { $0 === self }
    }
}

// MARK: - Layout helpers

/// Building blocks for the Properties tabs: Windows' two-column "label: value" rows with
/// separators between groups.
@MainActor
enum PropertiesLayout {
    static let labelWidth: CGFloat = 96

    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    static func value(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// A grid of `rows`; a `nil` label with a separator makes a full-width divider.
    static func grid(_ rows: [(String?, NSView)]) -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        for (label, view) in rows {
            if let label {
                grid.addRow(with: [Self.label(label), view])
            } else {
                let row = grid.addRow(with: [view])
                row.mergeCells(in: NSRange(location: 0, length: 2))
                row.topPadding = 3
                row.bottomPadding = 3
            }
        }
        if grid.numberOfColumns == 2 {
            grid.column(at: 0).width = labelWidth
            grid.column(at: 0).xPlacement = .leading
        }
        return grid
    }
}
