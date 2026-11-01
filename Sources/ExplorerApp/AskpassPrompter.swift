import AppKit
import ExplorerCore

/// Shows ssh's sign-in questions (passwords, key passphrases, unknown host keys) as dialogs.
///
/// ssh runs this app's own executable as its `SSH_ASKPASS` helper; the helper hands each
/// question to the running app over a Unix socket (`AskpassServer`) and prints the answer
/// for ssh. Questions are shown one at a time, as a sheet on the window that asked to connect.
@MainActor
final class AskpassPrompter {
    private let server: AskpassServer
    private let prompts = PromptQueue()
    private let windowForConnection: (String) -> NSWindow?
    /// Password prompts so far per connection, to say "incorrect" on the second.
    private var attempts: [String: Int] = [:]
    /// Connections whose sign-in the user cancelled, so the error reads as cancelled.
    private var cancelled: Set<String> = []

    init(socketPath: String, windowForConnection: @escaping (String) -> NSWindow?) throws {
        self.windowForConnection = windowForConnection
        weak var weakSelf: AskpassPrompter?
        server = try AskpassServer(socketPath: socketPath) { request, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let prompter = weakSelf else { return reply(AskpassReply(answer: nil)) }
                    prompter.enqueue(request, reply: reply)
                }
            }
        }
        weakSelf = self
    }

    /// What ssh needs in its environment to ask through this app.
    var environment: [String: String] {
        [
            "SSH_ASKPASS": Bundle.main.executablePath ?? CommandLine.arguments[0],
            "SSH_ASKPASS_REQUIRE": "force",
            AskpassEnvironment.socket: server.socketPath,
            AskpassEnvironment.token: server.token,
        ]
    }

    func stop() {
        server.stop()
    }

    func resetAttempts(for connection: String) {
        attempts[connection] = nil
        cancelled.remove(connection)
    }

    /// Whether the user cancelled signing in to `connection`; clears it.
    func takeCancellation(for connection: String) -> Bool {
        cancelled.remove(connection) != nil
    }

    private func enqueue(_ request: AskpassRequest, reply: @escaping @Sendable (AskpassReply) -> Void) {
        prompts.enqueue { [weak self] done in
            guard let self else {
                reply(AskpassReply(answer: nil))
                return done()
            }
            ask(request) { answer in
                if answer == nil { self.cancelled.insert(request.connection) }
                reply(AskpassReply(answer: answer))
                done()
            }
        }
    }

    private func ask(_ request: AskpassRequest, completion: @escaping (String?) -> Void) {
        if case .notice = request.kind { return completion("") }
        let alert = NSAlert()
        let field = configure(alert, for: request)
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            switch request.kind {
            case .hostKey: completion("yes")
            case .confirm: completion("")
            default: completion(field?.stringValue ?? "")
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = windowForConnection(request.connection), window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
            if let field { alert.window.makeFirstResponder(field) }
        } else {
            handle(alert.runModal())
        }
    }

    /// Words and buttons for the question; the text field, if it asks for one.
    private func configure(_ alert: NSAlert, for request: AskpassRequest) -> NSSecureTextField? {
        let server = Self.serverName(request.connection)
        switch request.kind {
        case .hostKey(let message):
            alert.alertStyle = .warning
            alert.messageText = "Do you want to connect to “\(server)”?"
            alert.informativeText = "This server hasn’t been used from this Mac before, so its identity can’t be "
                + "checked. If you expected to connect to it for the first time, continue.\n\n"
                + Self.fingerprintLines(message)
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            return nil
        case .confirm(let message), .notice(let message):
            alert.messageText = message
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            return nil
        case .password(let prompt):
            let count = (attempts[request.connection] ?? 0) + 1
            attempts[request.connection] = count
            alert.messageText = "Sign in to “\(server)”"
            alert.informativeText = count > 1
                ? "The password was incorrect. Try again.\n\n\(prompt)"
                : "Enter the password. (\(prompt.trimmingCharacters(in: CharacterSet(charactersIn: ": "))))"
        case .passphrase(let keyPath):
            alert.messageText = "Unlock the key “\((keyPath as NSString).lastPathComponent)”"
            alert.informativeText = "Enter the passphrase for \(keyPath.isEmpty ? "your SSH key" : keyPath), "
                + "to sign in to “\(server)”."
        case .secret(let prompt):
            alert.messageText = "Sign in to “\(server)”"
            alert.informativeText = prompt
        }
        return addSecureField(to: alert)
    }

    private func addSecureField(to alert: NSAlert) -> NSSecureTextField {
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return field
    }

    /// The host name in a `RemoteHost.key` ("user@host:port").
    private static func serverName(_ key: String) -> String {
        guard let at = key.firstIndex(of: "@"), let colon = key.lastIndex(of: ":"), at < colon else { return key }
        return String(key[key.index(after: at)..<colon])
    }

    /// The key type and fingerprint lines of ssh's host-key question.
    private static func fingerprintLines(_ message: String) -> String {
        message.split(whereSeparator: \.isNewline)
            .filter { $0.contains("fingerprint is") }
            .joined(separator: "\n")
    }
}

/// The helper side, run when ssh starts this executable as `SSH_ASKPASS`: asks the running
/// app and prints the answer. Returns the exit status (1 = cancelled).
enum AskpassHelper {
    static func run(socket: String) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let request = AskpassRequest(
            token: environment[AskpassEnvironment.token] ?? "",
            connection: environment[AskpassEnvironment.connection] ?? "",
            prompt: CommandLine.arguments.dropFirst().first ?? "",
            hint: environment["SSH_ASKPASS_PROMPT"]
        )
        // Security-key touches need no answer; ssh stops the helper when it's done.
        if case .notice = request.kind { return 0 }
        guard let answer = AskpassClient.ask(request, socketPath: socket) else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }
}
