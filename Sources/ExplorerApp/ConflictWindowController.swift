import AppKit
import ExplorerCore

/// Windows' "Replace or Skip Files" dialog: replace, skip, or compare both files and choose
/// which to keep (both = keep both under a numbered name).
@MainActor
final class ConflictWindowController: NSWindowController, NSWindowDelegate {
    private let conflict: FileConflict
    private let summary: String
    private var completion: ((ConflictDecision) -> Void)?
    /// Keeps the dialog alive while it is on screen.
    private static var presented: Set<ConflictWindowController> = []

    private let applyToRemaining = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let compareSection = NSStackView()
    private let keepSource = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let keepDestination = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(conflict: FileConflict, summary: String) {
        self.conflict = conflict
        self.summary = summary
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Replace or Skip Files"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present(completion: @escaping (ConflictDecision) -> Void) {
        self.completion = completion
        Self.presented.insert(self)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    private var noun: String { conflict.source.isDirectory ? "folder" : "file" }

    private func buildContent(in panel: NSPanel) {
        let summaryLabel = NSTextField(wrappingLabelWithString: summary)
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor

        let kind = conflict.destination.isDirectory ? "folder" : "file"
        let name = conflict.destination.url.lastPathComponent
        let headline = NSTextField(wrappingLabelWithString: "The destination already has a \(kind) named “\(name)”")
        headline.font = .systemFont(ofSize: 15)

        let options = makeOptionButtons()

        buildCompareSection()
        compareSection.isHidden = true

        let remaining = conflict.remainingCount
        applyToRemaining.title = remaining == 1
            ? "Do this for the next conflict"
            : "Do this for the next \(remaining) conflicts"
        applyToRemaining.isHidden = remaining == 0

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(chooseCancel))
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [applyToRemaining, NSView(), cancel])

        let stack = NSStackView(views: [summaryLabel, headline] + options + [compareSection, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: headline)
        stack.setCustomSpacing(18, after: compareSection)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 480),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            compareSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headline.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = content
    }

    /// Replace (only when a file replaces a file), Skip, and Compare.
    private func makeOptionButtons() -> [NSButton] {
        let replace = optionButton(
            symbol: "checkmark",
            title: "Replace the \(noun) in the destination",
            action: #selector(chooseReplace)
        )
        replace.isHidden = !conflict.canReplace
        let skip = optionButton(
            symbol: "arrowshape.turn.up.right",
            title: "Skip this \(noun)",
            action: #selector(chooseSkip)
        )
        let compare = optionButton(
            symbol: "doc.on.doc",
            title: "Compare info for both \(noun)s",
            action: #selector(showCompare)
        )
        return [replace, skip, compare]
    }

    private func optionButton(symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.isBordered = false
        button.font = .systemFont(ofSize: 14)
        button.contentTintColor = .controlAccentColor
        return button
    }

    private func buildCompareSection() {
        let intro = NSTextField(wrappingLabelWithString:
            "Which \(noun)s do you want to keep? If you select both versions, the \(noun) being copied "
                + "will have a number added to its name.")

        let sourceFolder = conflict.source.url.deletingLastPathComponent().lastPathComponent
        let destinationFolder = conflict.destination.url.deletingLastPathComponent().lastPathComponent
        keepSource.title = "From “\(sourceFolder)”"
        keepDestination.title = "Already in “\(destinationFolder)”"
        for checkbox in [keepSource, keepDestination] {
            checkbox.target = self
            checkbox.action = #selector(compareSelectionChanged)
        }

        let columns = NSStackView(views: [
            column(checkbox: keepSource, item: conflict.source),
            column(checkbox: keepDestination, item: conflict.destination),
        ])
        columns.distribution = .fillEqually
        columns.alignment = .top

        continueButton.target = self
        continueButton.action = #selector(chooseCompared)
        continueButton.keyEquivalent = "\r"
        continueButton.isEnabled = false

        compareSection.setViews([intro, columns, continueButton], in: .leading)
        compareSection.orientation = .vertical
        compareSection.alignment = .leading
        compareSection.spacing = 10
        intro.widthAnchor.constraint(equalTo: compareSection.widthAnchor).isActive = true
        columns.widthAnchor.constraint(equalTo: compareSection.widthAnchor).isActive = true
    }

    private func column(checkbox: NSButton, item: FileConflict.Item) -> NSView {
        let icon = NSImageView(image: FileIcons.icon(for: item.url, isDirectory: item.isDirectory))
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        var lines = [item.url.lastPathComponent]
        if let date = item.dateModified { lines.append(dateFormatter.string(from: date)) }
        if let size = item.size { lines.append(FileSizeFormat.string(for: size)) }
        let details = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [checkbox, icon, details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    @objc private func chooseReplace() { finish(.replace) }
    @objc private func chooseSkip() { finish(.skip) }
    @objc private func chooseCancel() { finish(.cancel) }

    @objc private func showCompare() {
        compareSection.isHidden = false
        applyToRemaining.state = .off
        applyToRemaining.isHidden = true
        window?.contentView?.layoutSubtreeIfNeeded()
        if let window, let size = window.contentView?.fittingSize {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @objc private func compareSelectionChanged() {
        continueButton.isEnabled = keepSource.state == .on || keepDestination.state == .on
    }

    @objc private func chooseCompared() {
        switch (keepSource.state == .on, keepDestination.state == .on) {
        case (true, true): finish(.keepBoth)
        case (true, false): finish(conflict.canReplace ? .replace : .keepBoth)
        case (false, true): finish(.skip)
        case (false, false): break
        }
    }

    private func finish(_ resolution: ConflictResolution) {
        guard let completion else { return }
        self.completion = nil
        let decision = ConflictDecision(resolution, appliesToRemaining: applyToRemaining.state == .on)
        window?.orderOut(nil)
        Self.presented.remove(self)
        completion(decision)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }
}
