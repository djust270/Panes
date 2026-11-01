import Foundation

/// SFTP version 3 (draft-ietf-secsh-filexfer-02), the version OpenSSH speaks: packet types,
/// status codes, attributes and the big-endian encoding. Pure; `SFTPClient` does the I/O.
enum SFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

/// `SSH_FXF_*` flags for `open`.
struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
    static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// A file's attributes as the server reports them; any field may be missing.
public struct SFTPAttributes: Sendable, Hashable {
    public var size: UInt64?
    /// Mode bits including the file type (`S_IFMT`).
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, permissions: UInt32? = nil,
                accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    public enum FileType: Sendable, Hashable {
        case file
        case directory
        case symlink
        /// Devices, sockets, FIFOs.
        case other
    }

    /// `nil` if the server didn't send permissions.
    public var fileType: FileType? {
        guard let permissions else { return nil }
        switch permissions & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): return .directory
        case UInt32(S_IFLNK): return .symlink
        case UInt32(S_IFREG): return .file
        default: return .other
        }
    }

    public var dateModified: Date? {
        modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static let sizeFlag: UInt32 = 0x01
    static let ownerFlag: UInt32 = 0x02
    static let permissionsFlag: UInt32 = 0x04
    static let timesFlag: UInt32 = 0x08
    static let extendedFlag: UInt32 = 0x8000_0000
}

/// One entry of a directory listing.
public struct SFTPEntry: Sendable, Hashable {
    /// Decoded as UTF-8, or as Latin-1 when it isn't valid UTF-8.
    public let name: String
    public let attributes: SFTPAttributes

    public init(name: String, attributes: SFTPAttributes) {
        self.name = name
        self.attributes = attributes
    }
}

public enum SFTPError: Error, Sendable, Hashable {
    /// The server answered with an error status (`SSH_FX_*`).
    case status(Code, message: String)
    /// The channel closed or the server stopped answering.
    case connectionLost
    /// The server sent something that isn't SFTP, usually text a login script printed.
    case unexpectedData
    /// No reply in time.
    case timedOut

    public enum Code: UInt32, Sendable, Hashable {
        case ok = 0
        case eof = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case unsupported = 8
    }

    public var statusCode: Code? {
        if case .status(let code, _) = self { return code }
        return nil
    }
}

/// Builds packet payloads (everything after the length).
struct SFTPWriter {
    private(set) var data = Data()

    init(_ type: SFTPPacketType, id: UInt32? = nil) {
        data.append(type.rawValue)
        if let id { uint32(id) }
    }

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func uint64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) {
        bytes(Data(value.utf8))
    }

    mutating func attributes(_ attributes: SFTPAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPAttributes.sizeFlag }
        if attributes.permissions != nil { flags |= SFTPAttributes.permissionsFlag }
        if attributes.modificationTime != nil { flags |= SFTPAttributes.timesFlag }
        uint32(flags)
        if let size = attributes.size { uint64(size) }
        if let permissions = attributes.permissions { uint32(permissions) }
        if let mtime = attributes.modificationTime {
            uint32(attributes.accessTime ?? mtime)
            uint32(mtime)
        }
    }

    /// The payload with its length prefix, ready to send.
    var packet: Data {
        var framed = Data(capacity: data.count + 4)
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(data)
        return framed
    }
}

/// Reads a packet payload. Every read throws `SFTPError.unexpectedData` past the end.
struct SFTPReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func uint8() throws -> UInt8 {
        guard offset < data.endIndex else { throw SFTPError.unexpectedData }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw SFTPError.unexpectedData }
        var value: UInt32 = 0
        for index in offset..<offset + 4 {
            value = value << 8 | UInt32(data[index])
        }
        offset += 4
        return value
    }

    mutating func uint64() throws -> UInt64 {
        let high = try uint32()
        let low = try uint32()
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func bytes() throws -> Data {
        let count = Int(try uint32())
        guard data.endIndex - offset >= count else { throw SFTPError.unexpectedData }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    /// UTF-8, as OpenSSH sends; names in other encodings are read as Latin-1 rather than lost.
    mutating func string() throws -> String {
        let data = try bytes()
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        var attributes = SFTPAttributes()
        if flags & SFTPAttributes.sizeFlag != 0 { attributes.size = try uint64() }
        if flags & SFTPAttributes.ownerFlag != 0 { _ = try (uint32(), uint32()) }
        if flags & SFTPAttributes.permissionsFlag != 0 { attributes.permissions = try uint32() }
        if flags & SFTPAttributes.timesFlag != 0 {
            attributes.accessTime = try uint32()
            attributes.modificationTime = try uint32()
        }
        if flags & SFTPAttributes.extendedFlag != 0 {
            for _ in 0..<(try uint32()) {
                _ = try (bytes(), bytes())
            }
        }
        return attributes
    }
}
