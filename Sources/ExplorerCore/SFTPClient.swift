import Darwin
import Foundation

/// A blocking SFTP v3 client over a child process's pipes: `ssh … -s host sftp` in the app,
/// `/usr/libexec/sftp-server` in tests.
///
/// Calls block the calling thread, so file operations can use it from their worker thread
/// like any other file API. Not thread-safe: use one client from one thread at a time.
/// `close()` may be called from any thread to abandon a call that's waiting.
public final class SFTPClient: @unchecked Sendable {
    /// Why a channel couldn't be opened: the protocol error, and what the process printed.
    public struct LaunchFailure: Error, Sendable {
        public let error: SFTPError
        public let errorOutput: String
        public let exitStatus: Int32?
    }

    /// OpenSSH's limit is 256 KiB of payload; anything longer is not SFTP.
    static let maximumPacketLength = 256 * 1024 + 1024
    static let chunkSize = 32 * 1024
    static let maximumRequestsInFlight = 64

    private let process: Process?
    private let readFD: Int32
    private let writeFD: Int32
    private let errorBuffer = LockedBuffer()
    private let closeLock = NSLock()
    private var isClosed = false

    private var nextID: UInt32 = 0
    /// Replies that arrived while waiting for another one.
    private var stashed: [UInt32: Packet] = [:]
    /// Requests whose replies are no longer wanted (an abandoned transfer).
    var discarded: Set<UInt32> = []
    /// Extensions the server announced, e.g. `posix-rename@openssh.com`.
    public private(set) var extensions: Set<String> = []
    /// How long to wait for any reply before giving up on the channel.
    public var timeout: TimeInterval

    /// Starts `executable` and speaks SFTP over its standard input and output.
    public static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) throws -> SFTPClient {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let client = SFTPClient(
            process: process,
            readFD: output.fileHandleForReading.fileDescriptor,
            writeFD: input.fileHandleForWriting.fileDescriptor,
            timeout: timeout
        )
        // Keep the handles (and so the descriptors) alive as long as the client.
        client.handles = [input.fileHandleForWriting, output.fileHandleForReading]
        let buffer = client.errorBuffer
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(data)
            }
        }
        do {
            try client.handshake()
        } catch let error as SFTPError {
            client.close()
            process.waitUntilExit(timeout: 3)
            throw LaunchFailure(
                error: error,
                errorOutput: buffer.string,
                exitStatus: process.isRunning ? nil : process.terminationStatus
            )
        }
        return client
    }

    private var handles: [FileHandle] = []

    private init(process: Process?, readFD: Int32, writeFD: Int32, timeout: TimeInterval) {
        self.process = process
        self.readFD = readFD
        self.writeFD = writeFD
        self.timeout = timeout
        // A server that exits mid-write must fail the write, not kill the app.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    }

    deinit {
        close()
    }

    /// What the process has written to standard error so far.
    public var errorOutput: String { errorBuffer.string }

    /// Ends the session and the process. Safe to call more than once, from any thread.
    public func close() {
        closeLock.lock()
        let wasClosed = isClosed
        isClosed = true
        closeLock.unlock()
        guard !wasClosed else { return }
        // Closing our end of its input lets the server exit by itself; terminate in case it doesn't.
        try? handles.first?.close()
        if let process, process.isRunning { process.terminate() }
    }

    public var isOpen: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return !isClosed
    }

    private func handshake() throws {
        var hello = SFTPWriter(.initialize)
        hello.uint32(3)
        try send(hello)
        var payload = try receiveVersion()
        _ = try payload.uint32()
        while !payload.isAtEnd {
            let name = try payload.string()
            _ = try payload.bytes()
            extensions.insert(name)
        }
    }

    // MARK: Requests

    /// Resolves `path` (relative paths against the login folder; `"."` is the home folder).
    public func realpath(_ path: String) throws -> String {
        let id = try request(.realpath) { $0.string(path.isEmpty ? "." : path) }
        let names = try names(from: id)
        guard let first = names.first else { throw SFTPError.unexpectedData }
        return first.name
    }

    /// Attributes, following symbolic links.
    public func stat(_ path: String) throws -> SFTPAttributes {
        try attributes(from: try request(.stat) { $0.string(path) })
    }

    /// Attributes of the item itself, not what a link points to.
    public func lstat(_ path: String) throws -> SFTPAttributes {
        try attributes(from: try request(.lstat) { $0.string(path) })
    }

    /// `stat` of many paths at once, pipelined; `nil` for paths that fail (broken links).
    public func statMany(_ paths: [String]) throws -> [SFTPAttributes?] {
        var results: [SFTPAttributes?] = []
        results.reserveCapacity(paths.count)
        var index = 0
        while index < paths.count {
            let batch = paths[index..<min(paths.count, index + Self.maximumRequestsInFlight)]
            let ids = try batch.map { path in try request(.stat) { $0.string(path) } }
            for id in ids {
                results.append(try? attributes(from: id))
            }
            index += batch.count
        }
        return results
    }

    /// The entries of a folder, without `.` and `..`, in the server's order.
    public func listDirectory(_ path: String) throws -> [SFTPEntry] {
        let handle = try handle(from: try request(.opendir) { $0.string(path) })
        defer { try? closeHandle(handle) }
        var entries: [SFTPEntry] = []
        while true {
            let id = try request(.readdir) { $0.bytes(handle) }
            do {
                for entry in try names(from: id) where entry.name != "." && entry.name != ".." {
                    entries.append(entry)
                }
            } catch SFTPError.status(.eof, _) {
                return entries
            }
        }
    }

    public func mkdir(_ path: String, permissions: UInt32 = 0o755) throws {
        try expectOK(try request(.mkdir) { $0.string(path); $0.attributes(SFTPAttributes(permissions: permissions)) })
    }

    public func remove(_ path: String) throws {
        try expectOK(try request(.remove) { $0.string(path) })
    }

    /// Removes an empty folder.
    public func rmdir(_ path: String) throws {
        try expectOK(try request(.rmdir) { $0.string(path) })
    }

    /// Renames, replacing an existing file if `replacing` and the server can do that
    /// atomically (`posix-rename@openssh.com`); otherwise fails if the target exists.
    public func rename(_ source: String, to destination: String, replacing: Bool = false) throws {
        if replacing, extensions.contains("posix-rename@openssh.com") {
            try expectOK(try request(.extended) {
                $0.string("posix-rename@openssh.com")
                $0.string(source)
                $0.string(destination)
            })
            return
        }
        if replacing { try? remove(destination) }
        try expectOK(try request(.rename) { $0.string(source); $0.string(destination) })
    }

    public func setAttributes(_ path: String, _ attributes: SFTPAttributes) throws {
        try expectOK(try request(.setstat) { $0.string(path); $0.attributes(attributes) })
    }

    // MARK: Packets

    func request(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) throws -> UInt32 {
        nextID &+= 1
        var writer = SFTPWriter(type, id: nextID)
        build(&writer)
        try send(writer)
        return nextID
    }

    func closeHandle(_ handle: Data) throws {
        try expectOK(try request(.close) { $0.bytes(handle) })
    }

    private func reply(to id: UInt32) throws -> (SFTPPacketType, SFTPReader) {
        if let packet = stashed.removeValue(forKey: id) { return (packet.type, packet.reader) }
        while true {
            let packet = try receive()
            if packet.id == id { return (packet.type, packet.reader) }
            stash(packet)
        }
    }

    /// The next reply to any of `ids`; `nil` if `ids` is empty.
    func receiveAny(of ids: Set<UInt32>) throws -> Packet? {
        guard !ids.isEmpty else { return nil }
        if let id = ids.first(where: { stashed[$0] != nil }) { return stashed.removeValue(forKey: id) }
        while true {
            let packet = try receive()
            if ids.contains(packet.id) { return packet }
            stash(packet)
        }
    }

    /// Keeps a reply for whoever waits for it, unless nobody will.
    private func stash(_ packet: Packet) {
        if discarded.remove(packet.id) == nil { stashed[packet.id] = packet }
    }

    private func expectOK(_ id: UInt32) throws {
        var (type, reader) = try reply(to: id)
        guard type == .status else { throw SFTPError.unexpectedData }
        let error = try Self.statusError(&reader)
        if error.statusCode != .ok { throw error }
    }

    func handle(from id: UInt32) throws -> Data {
        var (type, reader) = try reply(to: id)
        switch type {
        case .handle: return try reader.bytes()
        case .status: throw try Self.statusError(&reader)
        default: throw SFTPError.unexpectedData
        }
    }

    private func attributes(from id: UInt32) throws -> SFTPAttributes {
        var (type, reader) = try reply(to: id)
        switch type {
        case .attrs: return try reader.attributes()
        case .status: throw try Self.statusError(&reader)
        default: throw SFTPError.unexpectedData
        }
    }

    private func names(from id: UInt32) throws -> [SFTPEntry] {
        var (type, reader) = try reply(to: id)
        switch type {
        case .name:
            let count = try reader.uint32()
            var entries: [SFTPEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let name = try reader.string()
                _ = try reader.bytes() // ls -l style long name
                entries.append(SFTPEntry(name: name, attributes: try reader.attributes()))
            }
            return entries
        case .status: throw try Self.statusError(&reader)
        default: throw SFTPError.unexpectedData
        }
    }

    /// Reads a STATUS payload (after the id) as an error; `.status(.ok, …)` for success.
    static func statusError(_ reader: inout SFTPReader) throws -> SFTPError {
        let raw = try reader.uint32()
        let message = (try? reader.string()) ?? ""
        return .status(SFTPError.Code(rawValue: raw) ?? .failure, message: message)
    }

    private func send(_ writer: SFTPWriter) throws {
        guard isOpen else { throw SFTPError.connectionLost }
        let packet = writer.packet
        try packet.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(writeFD, buffer.baseAddress! + sent, buffer.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    close()
                    throw SFTPError.connectionLost
                }
                sent += count
            }
        }
    }

    /// A reply: its type, the request it answers, and the rest of the payload.
    struct Packet {
        let type: SFTPPacketType
        let id: UInt32
        let reader: SFTPReader
    }

    private func receive() throws -> Packet {
        var reader = try receivePayload()
        guard let type = SFTPPacketType(rawValue: try reader.uint8()), type != .version else {
            throw SFTPError.unexpectedData
        }
        return Packet(type: type, id: try reader.uint32(), reader: reader)
    }

    /// The server's VERSION packet, after the type: it has no request id.
    private func receiveVersion() throws -> SFTPReader {
        var reader = try receivePayload()
        guard try reader.uint8() == SFTPPacketType.version.rawValue else { throw SFTPError.unexpectedData }
        return reader
    }

    private func receivePayload() throws -> SFTPReader {
        var header = SFTPReader(try readExactly(4))
        let length = Int(try header.uint32())
        guard length >= 1, length <= Self.maximumPacketLength else {
            close()
            throw SFTPError.unexpectedData
        }
        return SFTPReader(try readExactly(length))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        while received < count {
            guard isOpen else { throw SFTPError.connectionLost }
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(timeout * 1000))
            if ready == 0 {
                close()
                throw SFTPError.timedOut
            }
            if ready < 0 {
                if errno == EINTR { continue }
                close()
                throw SFTPError.connectionLost
            }
            let got = data.withUnsafeMutableBytes { buffer in
                Darwin.read(readFD, buffer.baseAddress! + received, count - received)
            }
            if got < 0, errno == EINTR || errno == EAGAIN { continue }
            guard got > 0 else {
                close()
                throw SFTPError.connectionLost
            }
            received += got
        }
        return data
    }

    func writeAll(_ data: Data, to fd: Int32, at offset: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = pwrite(fd, buffer.baseAddress! + written, buffer.count - written,
                                   off_t(offset) + off_t(written))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
    }
}

/// Bytes appended from one thread and read from another.
final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.withLock { data.append(more) }
    }

    var string: String {
        lock.withLock { String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? "" }
    }
}

extension Process {
    /// Waits for the process to exit, for at most `timeout` seconds.
    func waitUntilExit(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            usleep(10_000)
        }
    }
}
