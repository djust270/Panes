import AppKit
import ExplorerCore

/// Windows' "Extract Compressed (Zipped) Folders" wizard: choose a destination (by default a
/// folder named after the archive, beside it) and whether to show the files afterwards.
@MainActor
final class ExtractWizard: NSObject {
    struct Choice {
        let destination: URL
        let showsFiles: Bool
    }

    private let archive: URL
    private let panel: NSPanel
    private let pathField = NSTextField()
    private let showFiles = NSButton(checkboxWithTitle: "Show extracted files when complete", target: nil, action: nil)

    private init(archive: URL) {
        self.archive = archive
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                        styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        buildContent()
    }

    /// Asks where to extract `archive`, as a sheet on `window`; `nil` if cancelled.
    static func ask(for archive: URL, on window: NSWindow) async -> Choice? {
        let wizard = ExtractWizard(archive: archive)
        let response = await withCheckedContinuation { continuation in
            window.beginSheet(wizard.panel) { continuation.resume(returning: $0) }
        }
        guard response == .OK else { return nil }
        let path = NSString(string: FileNaming.unquotedPath(wizard.pathField.stringValue)).expandingTildeInPath
        return Choice(destination: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
                      showsFiles: wizard.showFiles.state == .on)
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: "Select a Destination and Extract Files")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Files will be extracted to this folder:")
        pathField.stringValue = Archive.defaultDestination(for: archive).path
        pathField.lineBreakMode = .byTruncatingHead
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        let pathRow = NSStackView(views: [pathField, browse])
        showFiles.state = .on

        let extract = NSButton(title: "Extract", target: self, action: #selector(extract))
        extract.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView()
        buttons.setViews([cancel, extract], in: .trailing)

        let stack = NSStackView(views: [title, subtitle, pathRow, showFiles, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(20, after: showFiles)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: pathRow.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        panel.contentView = content
        panel.initialFirstResponder = pathField
    }

    @objc private func browse() {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.prompt = "Select Folder"
        open.directoryURL = archive.deletingLastPathComponent()
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            MainActor.assumeIsolated { self?.pathField.stringValue = url.path }
        }
    }

    @objc private func extract() {
        guard !pathField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return NSSound.beep() }
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
    }

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }
}

/// A sheet with a message, an indeterminate progress bar and Cancel, for work without a
/// measurable progress (extracting an archive).
@MainActor
final class ActivitySheet: NSObject {
    var onCancel: (() -> Void)?
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
                                styleMask: [.titled], backing: .buffered, defer: true)

    init(message: String) {
        super.init()
        let label = NSTextField(labelWithString: message)
        label.lineBreakMode = .byTruncatingMiddle
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView()
        buttons.setViews([cancel], in: .trailing)
        let stack = NSStackView(views: [label, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: progress.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        panel.contentView = content
    }

    func present(on window: NSWindow?) {
        window?.beginSheet(panel)
    }

    func dismiss() {
        panel.sheetParent?.endSheet(panel)
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
