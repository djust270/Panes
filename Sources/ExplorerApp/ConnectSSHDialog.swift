import AppKit
import ExplorerCore

/// "Connect to SSH Server": the server (or a `~/.ssh/config` host), user name, port, the
/// folder to open, and whether to remember it under Network.
@MainActor
final class ConnectSSHDialog: NSObject {
    struct Choice {
        let location: RemotePath
        let remember: Bool
    }

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: true)
    private let hostBox = NSComboBox()
    private let userField = NSTextField()
    private let portField = NSTextField()
    private let folderField = NSTextField()
    private let remember = NSButton(checkboxWithTitle: "Remember this server under Network", target: nil, action: nil)
    private let problem = NSTextField(labelWithString: "")
    private var problemRow: NSGridRow?

    private init(initial: RemotePath?, suggestions: [String]) {
        super.init()
        buildContent(suggestions: suggestions)
        if let initial {
            hostBox.stringValue = initial.host.hostname
            userField.stringValue = initial.host.user ?? ""
            portField.stringValue = initial.host.port.map(String.init) ?? ""
            folderField.stringValue = initial.isResolved ? initial.path : ""
        }
    }

    /// Asks which server to connect to, as a sheet on `window`; `nil` if cancelled.
    static func ask(initial: RemotePath? = nil, on window: NSWindow) async -> Choice? {
        let dialog = ConnectSSHDialog(initial: initial, suggestions: RemoteCenter.configHosts().map(\.alias))
        let response = await withCheckedContinuation { continuation in
            window.beginSheet(dialog.panel) { continuation.resume(returning: $0) }
        }
        guard response == .OK, let location = dialog.location else { return nil }
        return Choice(location: location, remember: dialog.remember.state == .on)
    }

    /// What's been entered, or `nil` if it isn't a server address.
    private var location: RemotePath? {
        var hostname = hostBox.stringValue.trimmingCharacters(in: .whitespaces)
        var user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        // "dave@server" typed into the server box.
        if user.isEmpty, let at = hostname.firstIndex(of: "@") {
            user = String(hostname[..<at])
            hostname = String(hostname[hostname.index(after: at)...])
        }
        let portText = portField.stringValue.trimmingCharacters(in: .whitespaces)
        let port = portText.isEmpty ? nil : Int(portText)
        guard portText.isEmpty || port != nil,
              let host = RemoteHost(user: user, hostname: hostname, port: port) else { return nil }
        var folder = folderField.stringValue.trimmingCharacters(in: .whitespaces)
        if folder == "~" {
            folder = ""
        } else if folder.hasPrefix("~/") {
            folder = String(folder.dropFirst(2))
        }
        return RemotePath(host: host, path: folder)
    }

    private func buildContent(suggestions: [String]) {
        let title = NSTextField(labelWithString: "Which SSH server do you want to connect to?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Enter the server’s name or address. Your SSH keys and ~/.ssh/config are used; you’ll be asked "
            + "for a password only if needed.")

        hostBox.addItems(withObjectValues: suggestions)
        hostBox.completes = true
        hostBox.placeholderString = "server.example.com"
        userField.placeholderString = "Same as on this Mac"
        portField.placeholderString = "22"
        folderField.placeholderString = "Home folder"
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .systemRed
        remember.state = .on

        let grid = makeGrid()
        let connect = NSButton(title: "Connect", target: self, action: #selector(finish))
        connect.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView()
        buttons.setViews([cancel, connect], in: .trailing)

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
            hostBox.widthAnchor.constraint(equalToConstant: 340),
            userField.widthAnchor.constraint(equalToConstant: 200),
            portField.widthAnchor.constraint(equalToConstant: 80),
            folderField.widthAnchor.constraint(equalToConstant: 340),
        ])
        panel.contentView = content
        panel.initialFirstResponder = hostBox
    }

    private func makeGrid() -> NSGridView {
        let grid = NSGridView(views: [
            [PropertiesLayout.label("Server:"), hostBox],
            [PropertiesLayout.label("User name:"), userField],
            [PropertiesLayout.label("Port:"), portField],
            [PropertiesLayout.label("Folder:"), folderField],
            [NSGridCell.emptyContentView, problem],
            [NSGridCell.emptyContentView, remember],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for row in 0..<4 { grid.row(at: row).rowAlignment = .firstBaseline }
        problemRow = grid.row(at: 4)
        problemRow?.isHidden = true
        return grid
    }

    @objc private func finish() {
        guard location != nil else {
            problem.stringValue = "Enter a server name, and a port from 1 to 65535 if not the usual one."
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
