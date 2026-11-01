import Darwin
import Foundation

/// What ssh asks through `SSH_ASKPASS`: the prompt text, and `SSH_ASKPASS_PROMPT`'s hint.
public enum AskpassPrompt: Sendable, Hashable {
    /// "The authenticity of host … can't be established … (yes/no/[fingerprint])?"
    case hostKey(message: String)
    /// "dave@server's password:"
    case password(prompt: String)
    /// "Enter passphrase for key '/Users/dave/.ssh/id_ed25519':"
    case passphrase(keyPath: String)
    /// ssh-agent asking to confirm a key's use (hint "confirm"): yes or no, no text.
    case confirm(message: String)
    /// Touch a security key (hint "none"): nothing to answer.
    case notice(message: String)
    /// Anything else needing typed, hidden input (one-time codes, PINs).
    case secret(prompt: String)

    public static func classify(text: String, hint: String?) -> AskpassPrompt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch hint {
        case "confirm": return .confirm(message: trimmed)
        case "none": return .notice(message: trimmed)
        default: break
        }
        if trimmed.contains("(yes/no") { return .hostKey(message: trimmed) }
        if trimmed.hasPrefix("Enter passphrase for key") {
            let parts = trimmed.split(separator: "'", omittingEmptySubsequences: false)
            return .passphrase(keyPath: parts.count >= 3 ? String(parts[1]) : "")
        }
        if trimmed.lowercased().hasSuffix("password:") { return .password(prompt: trimmed) }
        return .secret(prompt: trimmed)
    }
}

/// One prompt from the helper process to the app, as one line of JSON.
public struct AskpassRequest: Sendable, Codable, Hashable {
    public let token: String
    /// `RemoteHost.key` of the connection signing in.
    public let connection: String
    public let prompt: String
    public let hint: String?

    public init(token: String, connection: String, prompt: String, hint: String?) {
        self.token = token
        self.connection = connection
        self.prompt = prompt
        self.hint = hint
    }

    public var kind: AskpassPrompt { AskpassPrompt.classify(text: prompt, hint: hint) }
}

/// The app's answer: `nil` cancels (the helper exits 1, which ssh takes as "no").
public struct AskpassReply: Sendable, Codable, Hashable {
    public let answer: String?

    public init(answer: String?) {
        self.answer = answer
    }
}

/// Environment variables connecting the helper to the app.
public enum AskpassEnvironment {
    public static let socket = "PANES_ASKPASS_SOCKET"
    public static let token = "PANES_ASKPASS_TOKEN"
    public static let connection = "PANES_ASKPASS_CONNECTION"
}

/// Listens on a Unix socket for prompts from askpass helpers, answering only requests that
/// carry this launch's random token.
public final class AskpassServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AskpassRequest, @escaping @Sendable (AskpassReply) -> Void) -> Void

    public let socketPath: String
    public let token: String
    private let handler: Handler
    private let listener: Int32

    /// Starts listening at `socketPath` (replacing a leftover socket).
    public init(socketPath: String, handler: @escaping Handler) throws {
        self.socketPath = socketPath
        self.handler = handler
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        token = bytes.map { String(format: "%02x", $0) }.joined()

        unlink(socketPath)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = try Self.address(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0 else {
            let code = errno
            Darwin.close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "Askpass"
        thread.start()
    }

    /// Stops listening and removes the socket.
    public func stop() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(connection, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        guard let line = Self.readLine(connection),
              let request = try? JSONDecoder().decode(AskpassRequest.self, from: line),
              request.token == token else {
            Darwin.close(connection)
            return
        }
        handler(request) { reply in
            if var data = try? JSONEncoder().encode(reply) {
                data.append(0x0a)
                Self.writeAll(data, to: connection)
            }
            Darwin.close(connection)
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// Reads up to a newline (at most 64 KB).
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 65_536 {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return data.isEmpty ? nil : data }
            if byte == 0x0a { return data }
            data.append(byte)
        }
        return nil
    }

    static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = write(fd, buffer.baseAddress! + written, buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                written += count
            }
        }
    }
}

/// The helper side: sends one prompt to the app and waits for the answer.
public enum AskpassClient {
    /// The answer, or `nil` if the user cancelled or the app couldn't be reached.
    public static func ask(_ request: AskpassRequest, socketPath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        guard var address = try? AskpassServer.address(socketPath) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, var data = try? JSONEncoder().encode(request) else { return nil }
        data.append(0x0a)
        AskpassServer.writeAll(data, to: fd)
        guard let line = AskpassServer.readLine(fd),
              let reply = try? JSONDecoder().decode(AskpassReply.self, from: line) else { return nil }
        return reply.answer
    }
}
