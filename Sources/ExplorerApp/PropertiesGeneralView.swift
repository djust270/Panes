import AppKit
import ExplorerCore
import UniformTypeIdentifiers

/// The Properties dialog's General tab. For files and folders: name, type, "Opens with",
/// location, size and size on disk (counted as you watch, for folders), dates and the
/// Read-only and Hidden attributes. For a drive: type, file system, used and free space and a
/// capacity chart.
@MainActor
final class PropertiesGeneralView: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    /// The items shown; updated after a rename is applied.
    private(set) var urls: [URL]

    private let nameField = NSTextField()
    private var initialName = ""
    private let sizeValue = PropertiesLayout.value("")
    private let diskValue = PropertiesLayout.value("")
    private let containsValue = PropertiesLayout.value("")
    private let opensWithIcon = NSImageView()
    private let opensWithName = PropertiesLayout.value("")
    private let readOnly = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    private let hiddenBox = NSButton(checkboxWithTitle: "Hidden", target: nil, action: nil)
    private var initialReadOnly: NSControl.StateValue = .off
    private var initialHidden: NSControl.StateValue = .off
    private var countTask: Task<Void, Never>?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: Files and folders

    init(items urls: [URL]) {
        self.urls = urls
        super.init(frame: .zero)
        let items = urls.compactMap(FileItem.load)
        let rows = urls.count == 1 ? singleItemRows(urls[0], item: items.first) : multipleItemRows(items)
        let header = makeHeader(
            icon: urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path)
                : NSImage(named: NSImage.multipleDocumentsName) ?? NSImage(),
            name: urls.count == 1 ? (items.first?.name ?? urls[0].lastPathComponent) : Self.selectionSummary(items),
            editable: urls.count == 1
        )
        layOut(header: header, grid: PropertiesLayout.grid(rows))
        count(urls)
    }

    private func singleItemRows(_ url: URL, item: FileItem?) -> [(String?, NSView)] {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .isPackageKey, .contentTypeKey]
        let values = try? url.resourceValues(forKeys: keys)
        let isFolder = item?.isFolder ?? false
        var rows: [(String?, NSView)] = []
        let type = Self.typeText(url, isFolder: isFolder, type: values?.contentType)
        rows.append(("Type:", PropertiesLayout.value(type)))
        if !isFolder {
            rows.append(("Opens with:", makeOpensWithRow(for: url)))
        }
        rows.append((nil, PropertiesLayout.separator()))
        rows.append(("Location:", PropertiesLayout.value(url.deletingLastPathComponent().path)))
        rows.append(("Size:", sizeValue))
        rows.append(("Size on disk:", diskValue))
        if isFolder { rows.append(("Contains:", containsValue)) }
        rows.append((nil, PropertiesLayout.separator()))
        rows.append(("Created:", PropertiesLayout.value(item?.dateCreated.map(dateFormatter.string) ?? "")))
        rows.append(("Modified:", PropertiesLayout.value(item?.dateModified.map(dateFormatter.string) ?? "")))
        rows.append(("Accessed:", PropertiesLayout.value(values?.contentAccessDate.map(dateFormatter.string) ?? "")))
        rows.append((nil, PropertiesLayout.separator()))
        rows.append(("Attributes:", makeAttributeRow()))
        return rows
    }

    private func multipleItemRows(_ items: [FileItem]) -> [(String?, NSView)] {
        let types = Set(items.map(\.typeDescription))
        let folders = Set(items.map { $0.url.deletingLastPathComponent().path })
        return [
            ("Type:", PropertiesLayout.value(types.count == 1 ? "All of type \(types.first ?? "")" : "Multiple types")),
            ("Location:", PropertiesLayout.value(folders.count == 1 ? "All in \(folders.first ?? "")"
                : "Various locations")),
            (nil, PropertiesLayout.separator()),
            ("Size:", sizeValue),
            ("Size on disk:", diskValue),
            (nil, PropertiesLayout.separator()),
            ("Attributes:", makeAttributeRow()),
        ]
    }

    /// "3 Files, 2 Folders" — what's selected, not what's inside.
    private static func selectionSummary(_ items: [FileItem]) -> String {
        let folders = items.filter(\.isFolder).count
        return ContentTotals.countText(files: items.count - folders, folders: folders)
    }

    /// "JPEG image (.jpg)", "File folder", as Windows writes them.
    static func typeText(_ url: URL, isFolder: Bool, type: UTType?) -> String {
        if isFolder { return "File folder" }
        let description = type?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "File"
        let ext = url.pathExtension
        return ext.isEmpty ? description : "\(description) (.\(ext))"
    }

    /// Adds up sizes (and, for folders, what's inside) as Windows does, updating as it counts.
    private func count(_ urls: [URL]) {
        sizeValue.stringValue = "Calculating…"
        countTask = Task { [weak self] in
            for await totals in ContentCounter.count(urls) {
                guard let self else { return }
                sizeValue.stringValue = ContentTotals.sizeText(totals.size)
                diskValue.stringValue = ContentTotals.sizeText(totals.sizeOnDisk)
                containsValue.stringValue = totals.containsText
            }
        }
    }

    /// Stops counting. Called when the dialog closes.
    func stop() {
        countTask?.cancel()
    }

    // MARK: Opens with

    private func makeOpensWithRow(for url: URL) -> NSView {
        opensWithIcon.imageScaling = .scaleProportionallyUpOrDown
        opensWithIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        opensWithIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let change = NSButton(title: "Change…", target: self, action: #selector(changeDefaultApp))
        change.controlSize = .small
        change.toolTip = "Choose the app that opens all files of this type"
        updateOpensWith()
        let row = NSStackView(views: [opensWithIcon, opensWithName, change])
        row.spacing = 6
        row.setHuggingPriority(.defaultHigh, for: .vertical)
        return row
    }

    private func updateOpensWith() {
        guard let url = urls.first, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            opensWithIcon.image = nil
            opensWithName.stringValue = "No app"
            return
        }
        opensWithIcon.image = NSWorkspace.shared.icon(forFile: app.path)
        let name = FileManager.default.displayName(atPath: app.path) as NSString
        opensWithName.stringValue = name.deletingPathExtension
    }

    /// "Change…": makes another app the default for this type of file, right away (as Windows does).
    @objc private func changeDefaultApp() {
        guard let url = urls.first, let window else { return }
        Task {
            guard let app = await DefaultApps.chooseApp(for: [url], in: window) else { return }
            if let error = await DefaultApps.setDefault(app, for: url) {
                let alert = NSAlert()
                alert.messageText = "Couldn’t change the default app"
                alert.informativeText = error
                _ = await alert.beginSheetModal(for: window)
            }
            updateOpensWith()
        }
    }

    // MARK: Attributes

    private func makeAttributeRow() -> NSView {
        let keys: Set<URLResourceKey> = [.isHiddenKey, .isUserImmutableKey]
        let values = urls.map { try? $0.resourceValues(forKeys: keys) }
        func state(_ flag: (URLResourceValues?) -> Bool) -> NSControl.StateValue {
            let flags = Set(values.map(flag))
            if flags.count > 1 { return .mixed }
            return flags.first == true ? .on : .off
        }
        initialReadOnly = state { $0?.isUserImmutable == true }
        initialHidden = state { $0?.isHidden == true }
        for (box, initial) in [(readOnly, initialReadOnly), (hiddenBox, initialHidden)] {
            box.allowsMixedState = initial == .mixed
            box.state = initial
            box.target = self
            box.action = #selector(attributeChanged(_:))
        }
        readOnly.toolTip = "Locked: can’t be changed, renamed, moved or deleted until unlocked"
        let row = NSStackView(views: [readOnly, hiddenBox])
        row.spacing = 14
        return row
    }

    @objc private func attributeChanged(_ sender: NSButton) {
        // Once changed, a mixed box is a plain on/off box, as on Windows.
        if sender.state == .mixed { sender.state = .on }
        sender.allowsMixedState = false
        onChange?()
    }

    private func applyAttributes() -> String? {
        let setReadOnly = readOnly.state != initialReadOnly && readOnly.state != .mixed
        let setHidden = hiddenBox.state != initialHidden && hiddenBox.state != .mixed
        guard setReadOnly || setHidden else { return nil }
        for url in urls {
            var target = url
            var values = URLResourceValues()
            if setReadOnly { values.isUserImmutable = readOnly.state == .on }
            if setHidden { values.isHidden = hiddenBox.state == .on }
            do {
                try target.setResourceValues(values)
            } catch {
                return "“\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
        initialReadOnly = readOnly.state
        initialHidden = hiddenBox.state
        return nil
    }

    // MARK: Header

    private func makeHeader(icon: NSImage, name: String, editable: Bool) -> NSView {
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        nameField.stringValue = name
        initialName = name
        nameField.isEditable = editable
        nameField.isBordered = editable
        nameField.drawsBackground = editable
        nameField.bezelStyle = .squareBezel
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [iconView, nameField])
        header.spacing = 12
        return header
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    private func layOut(header: NSView, grid: NSView) {
        let separator = PropertiesLayout.separator()
        for view in [header, separator, grid] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Apply

    /// Renames and sets attributes. Unlocking happens before a rename, locking after it.
    func apply() async -> String? {
        let unlocking = initialReadOnly == .on && readOnly.state == .off
        if unlocking, let error = applyAttributes() { return error }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if nameField.isEditable, newName != initialName, let url = urls.first {
            if let problem = FileNaming.validationError(for: newName) { return problem }
            let result = await FileOperationCenter.shared.perform(.rename(url, to: newName))
            if let failure = result.failures.first { return failure.message }
            if let renamed = result.resultingItems.first { urls = [renamed.standardizedFileURL] }
            initialName = newName
        }
        if !unlocking, let error = applyAttributes() { return error }
        return nil
    }

    // MARK: Drives

    /// A drive's General tab.
    init(drive url: URL) {
        urls = [url]
        super.init(frame: .zero)
        let volume = VolumeLister.volume(at: url)
        let letter = DriveCenter.letter(forVolumeAt: url)
        nameField.isEditable = false
        let header = makeHeader(icon: NSWorkspace.shared.icon(forFile: url.path),
                                name: DriveCenter.displayName(volume, letter: letter), editable: false)

        let used = (volume.totalCapacity ?? 0) - (volume.availableCapacity ?? 0)
        var rows: [(String?, NSView)] = [
            ("Type:", PropertiesLayout.value(volume.typeDescription)),
            ("File system:", PropertiesLayout.value(volume.fileSystem)),
        ]
        if let share = volume.remountURL {
            rows.append(("Share:", PropertiesLayout.value(NetworkPath.uncPath(for: share) ?? share.absoluteString)))
        }
        rows += [
            (nil, PropertiesLayout.separator()),
            ("Used space:", Self.legend(Theme.accent, ContentTotals.sizeText(max(0, used)))),
            ("Free space:", Self.legend(CapacityChartView.freeColor,
                                        ContentTotals.sizeText(volume.availableCapacity ?? 0))),
            (nil, PropertiesLayout.separator()),
            ("Capacity:", PropertiesLayout.value(ContentTotals.sizeText(volume.totalCapacity ?? 0))),
        ]
        let chart = CapacityChartView()
        chart.usedFraction = volume.usedFraction ?? 0
        let caption = NSTextField(labelWithString: letter.map { "Drive \($0):" } ?? volume.name)
        caption.alignment = .center
        let chartStack = NSStackView(views: [chart, caption])
        chartStack.orientation = .vertical
        chart.widthAnchor.constraint(equalToConstant: 120).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 120).isActive = true
        rows.append((nil, chartStack))
        let grid = PropertiesLayout.grid(rows)
        grid.cell(for: chartStack)?.xPlacement = .center
        layOut(header: header, grid: grid)
    }

    private static func legend(_ color: NSColor, _ text: String) -> NSView {
        let swatch = LayerView(color: color)
        swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let row = NSStackView(views: [swatch, PropertiesLayout.value(text)])
        row.spacing = 6
        return row
    }
}

/// A drive's used and free space as a ring, as in Windows' drive Properties.
final class CapacityChartView: NSView {
    static let freeColor = NSColor.dynamic(light: NSColor(white: 0.82, alpha: 1), dark: NSColor(white: 0.32, alpha: 1))
    var usedFraction: Double = 0 { didSet { needsDisplay = true } }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }

    override func accessibilityLabel() -> String? { "Used space" }

    override func accessibilityValue() -> Any? { "\(Int((usedFraction * 100).rounded()))%" }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 22
        let rect = bounds.insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        func arc(from start: CGFloat, to end: CGFloat, color: NSColor) {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()
        }
        // Clockwise from the top.
        let usedEnd = 90 - 360 * CGFloat(usedFraction)
        arc(from: 90, to: usedEnd, color: Theme.accent)
        if usedFraction < 1 { arc(from: usedEnd, to: 90 - 360, color: Self.freeColor) }
    }
}
