import Foundation

/// SSH connections, one per host: a master connection (`ssh -M`, signed in once, prompts via
/// `SSH_ASKPASS`), an SFTP channel through it for browsing, and fresh channels for transfers.
public actor SSHConnectionPool {
    public struct Configuration: Sendable {
        public var command: SSHCommand
        /// Added to ssh's environment when signing in (askpass settings), per host.
        public var signInEnvironment: @Sendable (RemoteHost) -> [String: String]
        /// How long the browsing channel waits for a reply.
        public var browseTimeout: TimeInterval

        public init(
            command: SSHCommand = SSHCommand(),
            signInEnvironment: @escaping @Sendable (RemoteHost) -> [String: String] = { _ in [:] },
            browseTimeout: TimeInterval = 30
        ) {
            self.command = command
            self.signInEnvironment = signInEnvironment
            self.browseTimeout = browseTimeout
        }
    }

    public static let shared = SSHConnectionPool()

    private let settings = ConfigurationBox()
    private var signingIn: [String: Task<Void, Error>] = [:]
    private var opening: [String: Task<SFTPClient, Error>] = [:]
    private var browsers: [String: SFTPClient] = [:]
    private var queues: [String: DispatchQueue] = [:]
    private var hosts: [String: RemoteHost] = [:]

    public init(configuration: Configuration = Configuration()) {
        settings.value = configuration
    }

    public func configure(_ configuration: Configuration) {
        settings.value = configuration
    }

    private var command: SSHCommand { settings.value.command }

    /// Hosts with a browsing channel open.
    public var connectedHosts: [RemoteHost] {
        browsers.keys.compactMap { hosts[$0] }
    }

    public func isConnected(_ host: RemoteHost) -> Bool {
        browsers[host.key]?.isOpen == true
    }

    // MARK: Signing in

    /// Makes sure a master connection to `host` is running, signing in if needed. Concurrent
    /// calls for one host share one sign-in.
    public func connect(_ host: RemoteHost) async throws {
        hosts[host.key] = host
        if let task = signingIn[host.key] {
            return try await task.value
        }
        let command = self.command
        let environment = settings.value.signInEnvironment(host)
        let task = Task.detached(priority: .userInitiated) {
            try Self.startConnection(host, command: command, environment: environment)
        }
        signingIn[host.key] = task
        defer { signingIn[host.key] = nil }
        try await task.value
    }

    private static func startConnection(_ host: RemoteHost, command: SSHCommand, environment: [String: String]) throws {
        try command.prepareSocketDirectory()
        if run(command.checkArguments(for: host)).status == 0 { return }
        // A socket left by a master that died would stop ssh from becoming the master.
        unlink(command.controlPath(for: host))
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { $1 }
        let result = run(command.signInArguments(for: host), environment: merged)
        guard result.status == 0 else {
            throw SSHError.classify(errorOutput: result.errorOutput, exitStatus: result.status)
        }
    }

    /// Runs ssh to completion. With `ControlPersist`, a master forks into the background
    /// and this returns once it has signed in.
    private static func run(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> (status: Int32, errorOutput: String) {
        let process = Process()
        process.executableURL = SSHCommand.executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let buffer = LockedBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        // Whatever is left, without waiting on a background master that kept the pipe.
        let fd = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(Data(chunk[0..<count]))
        }
        return (process.terminationStatus, buffer.string)
    }

    // MARK: Channels

    /// Runs `body` with the host's browsing channel, one call at a time per host, off the
    /// actor. Signs in first if needed; if the connection has dropped, reconnects once.
    public func browse<T: Sendable>(
        _ host: RemoteHost,
        _ body: @escaping @Sendable (SFTPClient) throws -> T
    ) async throws -> T {
        do {
            return try await browseOnce(host, body)
        } catch let error where Self.isConnectionFailure(error) {
            dropBrowser(host)
            return try await browseOnce(host, body)
        }
    }

    private func browseOnce<T: Sendable>(
        _ host: RemoteHost,
        _ body: @escaping @Sendable (SFTPClient) throws -> T
    ) async throws -> T {
        let client = try await browser(for: host)
        let queue = queue(for: host)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(client) })
            }
        }
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        switch error {
        case SFTPError.connectionLost, SFTPError.timedOut: return true
        default: return false
        }
    }

    private func queue(for host: RemoteHost) -> DispatchQueue {
        if let queue = queues[host.key] { return queue }
        let queue = DispatchQueue(label: "SSH browse \(host.displayName)", qos: .userInitiated)
        queues[host.key] = queue
        return queue
    }

    private func browser(for host: RemoteHost) async throws -> SFTPClient {
        if let client = browsers[host.key], client.isOpen { return client }
        if let task = opening[host.key] { return try await task.value }
        let task = Task<SFTPClient, Error> {
            try await connect(host)
            let timeout = settings.value.browseTimeout
            return try await openChannel(host, timeout: timeout)
        }
        opening[host.key] = task
        defer { opening[host.key] = nil }
        let client = try await task.value
        browsers[host.key] = client
        return client
    }

    /// Opens a channel off the actor; if the master turns out to be gone, signs in again
    /// and retries once.
    private func openChannel(_ host: RemoteHost, timeout: TimeInterval) async throws -> SFTPClient {
        let settings = self.settings
        let open = {
            try await Task.detached(priority: .userInitiated) {
                try settings.openChannel(host, timeout: timeout)
            }.value
        }
        do {
            return try await open()
        } catch let failure as SSHError where failure != .sftpUnavailable {
            try await connect(host)
            return try await open()
        }
    }

    /// A new SFTP channel for a transfer, opened on the calling thread. The host must be
    /// connected (`connect`) first; this never prompts.
    public nonisolated func openTransferClient(_ host: RemoteHost) throws -> SFTPClient {
        try settings.openChannel(host, timeout: 60)
    }

    private func dropBrowser(_ host: RemoteHost) {
        browsers.removeValue(forKey: host.key)?.close()
    }

    // MARK: Disconnecting

    /// Closes the browsing channel and asks the master to exit.
    public func disconnect(_ host: RemoteHost) async {
        dropBrowser(host)
        let command = self.command
        await Task.detached {
            _ = Self.run(command.exitArguments(for: host))
        }.value
    }

    /// Disconnects from every host this pool connected to (app quit).
    public func shutdown() async {
        for host in hosts.values {
            await disconnect(host)
        }
    }
}

/// The configuration, readable without the actor (transfer threads open channels).
private final class ConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = SSHConnectionPool.Configuration()

    var value: SSHConnectionPool.Configuration {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// `ssh -s host sftp` through the master. Failures become `SSHError`s.
    func openChannel(_ host: RemoteHost, timeout: TimeInterval) throws -> SFTPClient {
        let command = value.command
        do {
            return try SFTPClient.launch(
                executable: SSHCommand.executable,
                arguments: command.sftpArguments(for: host),
                timeout: timeout
            )
        } catch let failure as SFTPClient.LaunchFailure {
            if failure.error == .unexpectedData {
                throw SSHError.other("The server sent unexpected text. Check that its login scripts "
                    + "(such as ~/.bashrc) don’t print anything.")
            }
            throw SSHError.classify(errorOutput: failure.errorOutput, exitStatus: failure.exitStatus)
        }
    }
}
