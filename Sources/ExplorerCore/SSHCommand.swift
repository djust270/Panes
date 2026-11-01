import Foundation

/// Arguments for the system's `ssh`. The host always follows `--` and the user name goes in
/// `-l`, so nothing typed into the address bar can be read as an ssh option.
public struct SSHCommand: Sendable, Hashable {
    public static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Folder for control sockets and the askpass socket.
    public let socketDirectory: URL
    /// `-F` file to use instead of `~/.ssh/config` (testing).
    public let configFile: String?

    public init(socketDirectory: URL = SSHCommand.defaultSocketDirectory(), configFile: String? = nil) {
        self.socketDirectory = socketDirectory
        self.configFile = configFile
    }

    /// Socket paths are limited to 104 bytes, and ssh appends ~17 characters while binding:
    /// `$TMPDIR` (private to the user, fixed length) when it's short enough, else `/tmp`.
    public static func defaultSocketDirectory(temporary: String = NSTemporaryDirectory()) -> URL {
        let preferred = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("panes-ssh", isDirectory: true)
        if preferred.path.utf8.count + 13 <= maximumSocketPath - bindSuffix { return preferred }
        return URL(fileURLWithPath: "/tmp/panes-ssh-\(getuid())", isDirectory: true)
    }

    static let maximumSocketPath = 104
    static let bindSuffix = 17

    /// The master connection's socket for `host`: a hash, so any host name fits.
    public func controlPath(for host: RemoteHost) -> String {
        socketDirectory.appendingPathComponent(Self.hash(host.key)).path
    }

    /// Creates the socket folder, readable only by the user.
    public func prepareSocketDirectory() throws {
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)
    }

    private var common: [String] {
        configFile.map { ["-F", $0] } ?? []
    }

    private static func target(_ host: RemoteHost) -> [String] {
        var arguments: [String] = []
        if let port = host.port { arguments += ["-p", String(port)] }
        if let user = host.user { arguments += ["-l", user] }
        return arguments + ["--", host.hostname]
    }

    /// Signs in and leaves a master connection running in the background (the command
    /// itself exits 0 once signed in). Prompts go through `SSH_ASKPASS`.
    public func signInArguments(for host: RemoteHost) -> [String] {
        common + [
            "-M", "-N", "-a", "-x",
            "-o", "ControlPath=\(controlPath(for: host))",
            "-o", "ControlPersist=300",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "ClearAllForwardings=yes",
        ] + Self.target(host)
    }

    /// Exits 0 if the master for `host` is running.
    public func checkArguments(for host: RemoteHost) -> [String] {
        common + ["-S", controlPath(for: host), "-O", "check"] + Self.target(host)
    }

    /// Asks the master for `host` to exit.
    public func exitArguments(for host: RemoteHost) -> [String] {
        common + ["-S", controlPath(for: host), "-O", "exit"] + Self.target(host)
    }

    /// An SFTP channel through the master. Never prompts: if the master is gone it fails.
    public func sftpArguments(for host: RemoteHost) -> [String] {
        common + [
            "-S", controlPath(for: host),
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-T", "-a", "-x", "-s",
        ] + Self.target(host) + ["sftp"]
    }

    /// FNV-1a, 48 bits as 12 hex digits: stable across launches, unlike `hashValue`.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%012llx", value & 0xffff_ffff_ffff)
    }
}

/// Why connecting to an SSH server failed, read from what `ssh` printed.
public enum SSHError: Error, Sendable, Hashable {
    case authenticationFailed
    case hostKeyRejected
    case hostKeyChanged
    case unknownHost
    case refused
    case unreachable
    case sftpUnavailable
    /// The user cancelled a sign-in prompt.
    case cancelled
    case other(String)

    public static func classify(errorOutput: String, exitStatus: Int32?) -> SSHError {
        let text = errorOutput
        let checks: [(String, SSHError)] = [
            ("REMOTE HOST IDENTIFICATION HAS CHANGED", .hostKeyChanged),
            ("Host key verification failed", .hostKeyRejected),
            ("Permission denied", .authenticationFailed),
            ("Too many authentication failures", .authenticationFailed),
            ("Could not resolve hostname", .unknownHost),
            ("Connection refused", .refused),
            ("timed out", .unreachable),
            ("No route to host", .unreachable),
            ("Network is unreachable", .unreachable),
            ("Host is down", .unreachable),
            ("subsystem request failed", .sftpUnavailable),
        ]
        for (needle, error) in checks where text.range(of: needle, options: .caseInsensitive) != nil {
            return error
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = lines.last(where: { !$0.isEmpty && !$0.hasPrefix("Warning:") }) {
            return .other(last)
        }
        return .other(exitStatus.map { "ssh exited with status \($0)." } ?? "The connection closed.")
    }

    /// Windows-style wording for an error dialog, about `host`.
    public func message(for host: RemoteHost) -> String {
        switch self {
        case .authenticationFailed:
            return "The server didn’t accept the sign-in. Check the user name, password or key."
        case .hostKeyRejected:
            return "The server’s identity wasn’t confirmed, so the connection was closed."
        case .hostKeyChanged:
            return "The server’s identity has changed since you last connected. Someone could be "
                + "intercepting the connection. If the server was reinstalled, remove its old key "
                + "with “ssh-keygen -R \(host.hostname)” in Terminal, then try again."
        case .unknownHost:
            return "The server “\(host.hostname)” couldn’t be found. Check the name."
        case .refused:
            return "The server refused the connection. Check that SSH (Remote Login) is turned on there."
        case .unreachable:
            return "The server can’t be reached. Check the address and your network connection."
        case .sftpUnavailable:
            return "The server doesn’t offer file transfer (SFTP)."
        case .cancelled:
            return "Sign-in was cancelled."
        case .other(let line):
            return line
        }
    }
}
