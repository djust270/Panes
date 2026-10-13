import AppKit
import ExplorerCore

/// Windows' "Map Network Drive": a drive letter, the folder (`\\server\share` or a URL), and
/// "Reconnect when Explorer starts" / "Connect using different credentials".
@MainActor
final class MapDriveDialog: NSObject, NSComboBoxDelegate {
    struct Choice {
        let path: NetworkPath
        let letter: String?
        let reconnects: Bool
        let differentCredentials: Bool
    }

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                                styleMask: [.titled], backing: .buffered, defer: true)
    private let letterPopUp = NSPopUpButton()
    private let folderBox = NSComboBox()
    private let problem = NSTextField(labelWithString: "")
    private var problemRow: NSGridRow?
    private let reconnect = NSButton(checkboxWithTitle: "Reconnect when Explorer starts", target: nil, action: nil)
    private let credentials = NSButton(checkboxWithTitle: "Connect using different credentials",
                                       target: nil, action: nil)

    private init(folder: String, letters: [String], suggestions: [String]) {
        super.init()
        buildContent(folder: folder, letters: letters, suggestions: suggestions)
    }

    /// Asks which share to map, as a sheet on `window`; `nil` if cancelled.
    static func ask(folder: String = "", on window: NSWindow) async -> Choice? {
        let letters = DriveCenter.store.freeLetters(mounted: VolumeLister.mountedVolumes())
        let suggestions = NetworkBrowser.shared.computers().compactMap { computer -> String? in
            computer.url.host.map { #"\\"# + $0 + #"\"# }
        }
        let dialog = MapDriveDialog(folder: folder, letters: letters, suggestions: suggestions)
        let response = await withCheckedContinuation { continuation in
            window.beginSheet(dialog.panel) { continuation.resume(returning: $0) }
        }
        guard response == .OK, let path = NetworkPath(dialog.folderBox.stringValue) else { return nil }
        let letter = dialog.letterPopUp.selectedItem?.representedObject as? String
        return Choice(path: path, letter: letter, reconnects: dialog.reconnect.state == .on,
                      differentCredentials: dialog.credentials.state == .on)
    }

    private func buildContent(folder: String, letters: [String], suggestions: [String]) {
        let title = NSTextField(labelWithString: "What network folder would you like to map?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Specify the drive letter for the connection and the folder that you want to connect to:")

        for letter in letters {
            letterPopUp.addItem(withTitle: "\(letter):")
            letterPopUp.lastItem?.representedObject = letter
        }
        letterPopUp.addItem(withTitle: "(No letter)")
        folderBox.stringValue = folder
        folderBox.addItems(withObjectValues: suggestions)
        folderBox.completes = true
        folderBox.placeholderString = #"\\server\share"#
        let example = NSTextField(labelWithString: #"Example: \\server\share or smb://server/share"#)
        example.font = .systemFont(ofSize: 11)
        example.textColor = .secondaryLabelColor
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .systemRed

        let grid = makeGrid(example: example)
        let finish = NSButton(title: "Finish", target: self, action: #selector(finish))
        finish.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView()
        buttons.setViews([cancel, finish], in: .trailing)

        let stack = NSStackView(views: [title, subtitle, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            folderBox.widthAnchor.constraint(equalToConstant: 360),
        ])
        panel.contentView = content
        panel.initialFirstResponder = folderBox
    }

    private func makeGrid(example: NSTextField) -> NSGridView {
        let grid = NSGridView(views: [
            [PropertiesLayout.label("Drive:"), letterPopUp],
            [PropertiesLayout.label("Folder:"), folderBox],
            [NSGridCell.emptyContentView, example],
            [NSGridCell.emptyContentView, problem],
            [NSGridCell.emptyContentView, reconnect],
            [NSGridCell.emptyContentView, credentials],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 0).rowAlignment = .firstBaseline
        grid.row(at: 1).rowAlignment = .firstBaseline
        reconnect.state = .on
        grid.row(at: 3).isHidden = true
        problemRow = grid.row(at: 3)
        return grid
    }

    @objc private func finish() {
        guard NetworkPath(folderBox.stringValue) != nil else {
            problem.stringValue = #"Enter a network folder, such as \\server\share."#
            problemRow?.isHidden = false
            NSSound.beep()
            return
        }
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
    }

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }
}
