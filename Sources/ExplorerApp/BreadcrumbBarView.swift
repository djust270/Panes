import AppKit
import ExplorerCore

/// Address bar: breadcrumb segments (title + chevron-dropdown-to-children) built from
/// `ExplorerLocation.ancestry`, or — when the user clicks empty background — an editable
/// path text field that also accepts network paths (`\\server\share`, `smb://…`).
final class BreadcrumbBarView: NSView, StyleObserving {
    var onNavigate: ((ExplorerLocation) -> Void)?
    var onNetworkPath: ((NetworkPath) -> Void)?
    /// An SSH address (`user@host:/path`, `sftp://…`) was typed.
    var onRemotePath: ((RemotePath) -> Void)?
    /// Editing the path ended (Return or Escape); focus should go back to the files.
    var onEndEditing: (() -> Void)?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let pathField = NSTextField()
    private var location: ExplorerLocation?
    private var isEditing = false
    private var height: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUp() {
        height = heightAnchor.constraint(equalToConstant: Self.barHeight)
        height?.isActive = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.focusRingType = .none
        pathField.font = Theme.font(ofSize: 13)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.isHidden = true
        pathField.delegate = self
        pathField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(pathField)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            pathField.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pathField.trailingAnchor.constraint(equalTo: trailingAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    private static var barHeight: CGFloat { Theme.isClassic ? 18 : 26 }

    func styleDidChange() {
        height?.constant = Self.barHeight
        pathField.font = Theme.font(ofSize: 13)
        if !isEditing { rebuildSegments() }
    }

    func setLocation(_ location: ExplorerLocation) {
        self.location = location
        guard !isEditing else { return }
        rebuildSegments()
    }

    /// Only genuinely empty background reaches this: segment/chevron buttons consume clicks
    /// over themselves before this override ever runs.
    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    /// Reachable with Tab and F6, as on Windows; taking focus switches to the editable path.
    override var acceptsFirstResponder: Bool { location != nil && !isEditing }

    override func becomeFirstResponder() -> Bool {
        // Only for Tab / Shift+Tab: AppKit also moves focus here on its own, e.g. when the
        // focused file view is hidden by a layout change.
        let event = NSApp.currentEvent
        guard event?.type == .keyDown, ["\t", "\u{19}"].contains(event?.charactersIgnoringModifiers) else {
            return true
        }
        // Not from inside becomeFirstResponder: beginEditing moves focus on to the text field.
        DispatchQueue.main.async { [weak self] in
            guard let self, window?.firstResponder === self else { return }
            beginEditing()
        }
        return true
    }

    func beginEditing() {
        guard let location, !isEditing else { return }
        isEditing = true
        pathField.stringValue = location.editableAddress
        scrollView.isHidden = true
        pathField.isHidden = false
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private func endEditing(navigate: Bool) {
        guard navigate else {
            finishEditingUI()
            return
        }
        let input = pathField.stringValue
        if let networkPath = NetworkPath(input) {
            finishEditingUI()
            onNetworkPath?(networkPath)
            return
        }
        let path = (FileNaming.unquotedPath(input) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // Local folders win: only then try reading it as an SSH address.
            if let remote = RemotePath.parse(input) {
                finishEditingUI()
                onRemotePath?(remote)
            } else {
                NSSound.beep()
            }
            return
        }
        finishEditingUI()
        onNavigate?(.folder(path: path))
    }

    /// Back to the breadcrumbs; `notify` hands focus back to the files.
    private func finishEditingUI(notify: Bool = true) {
        isEditing = false
        pathField.isHidden = true
        scrollView.isHidden = false
        rebuildSegments()
        if notify { onEndEditing?() }
    }

    private func rebuildSegments() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let location else { return }
        for ancestor in location.ancestry {
            stackView.addArrangedSubview(segmentView(for: ancestor))
        }
        layoutSubtreeIfNeeded()
        scrollToTrailingEdge()
    }

    private func scrollToTrailingEdge() {
        guard let documentView = scrollView.documentView else { return }
        documentView.scroll(NSPoint(x: documentView.bounds.width, y: 0))
    }

    private func segmentView(for ancestor: ExplorerLocation) -> NSView {
        let title = LocationButton(title: ancestor.displayName, target: self, action: #selector(segmentClicked(_:)))
        title.location = ancestor
        title.isBordered = false
        title.setButtonType(.momentaryPushIn)
        title.lineBreakMode = .byTruncatingTail
        title.attributedTitle = NSAttributedString(string: ancestor.displayName, attributes: [
            .font: Theme.font(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])

        let chevron = LocationButton(title: "", target: self, action: #selector(chevronClicked(_:)))
        chevron.location = ancestor
        chevron.isBordered = false
        chevron.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: "Folders in \(ancestor.displayName)")
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = .secondaryLabelColor
        chevron.setButtonType(.momentaryPushIn)

        let container = NSStackView(views: [title, chevron])
        container.orientation = .horizontal
        container.spacing = 0
        return container
    }

    @objc private func segmentClicked(_ sender: LocationButton) {
        onNavigate?(sender.location)
    }

    @objc private func chevronClicked(_ sender: LocationButton) {
        let children = LocationChildren.of(sender.location)
        guard !children.isEmpty else { return }
        let menu = NSMenu()
        for child in children {
            let item = NSMenuItem(title: child.displayName, action: #selector(menuChildSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = child
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func menuChildSelected(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? ExplorerLocation else { return }
        onNavigate?(location)
    }
}

extension BreadcrumbBarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(navigate: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(navigate: false)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // On from the address bar, not from the text field inside it; the field's editing
            // ends as focus leaves (`controlTextDidEndEditing`).
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                window?.selectKeyView(following: self)
            } else {
                window?.selectKeyView(preceding: self)
            }
            return true
        default:
            return false
        }
    }

    /// Focus moved elsewhere (a click, F6): back to the breadcrumbs, as on Windows.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing else { return }
        finishEditingUI(notify: false)
    }
}

/// An `NSButton` that remembers which location it represents, so one `@objc` action can
/// serve every breadcrumb segment.
private final class LocationButton: NSButton {
    var location: ExplorerLocation!
}
