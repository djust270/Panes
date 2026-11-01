import Darwin
import Foundation

/// File contents in and out, with many reads or writes in flight at once: one round trip
/// per chunk would make transfers crawl over any real network.
extension SFTPClient {
    /// Copies the remote file at `path` into `localFD` (from offset 0), pipelining reads.
    /// `progress` gets the bytes received so far; it may throw (e.g. cancellation) to stop.
    /// Returns the number of bytes copied.
    @discardableResult
    public func download(
        _ path: String,
        expectedSize: UInt64?,
        to localFD: Int32,
        progress: (Int64) throws -> Void
    ) throws -> Int64 {
        let handle = try handle(from: try request(.open) {
            $0.string(path)
            $0.uint32(SFTPOpenFlags.read.rawValue)
            $0.attributes(SFTPAttributes())
        })
        defer { try? closeHandle(handle) }

        var schedule = DownloadSchedule(expectedSize: expectedSize ?? 0, chunkSize: UInt32(Self.chunkSize))
        var inFlight: [UInt32: DownloadSchedule.Chunk] = [:]
        var received: Int64 = 0
        defer { discarded.formUnion(inFlight.keys) }

        while true {
            while inFlight.count < Self.maximumRequestsInFlight, let chunk = schedule.next(idle: inFlight.isEmpty) {
                let id = try request(.read) { $0.bytes(handle); $0.uint64(chunk.offset); $0.uint32(chunk.length) }
                inFlight[id] = chunk
            }
            guard let packet = try receiveAny(of: Set(inFlight.keys)),
                  let chunk = inFlight.removeValue(forKey: packet.id) else { break }
            var payload = packet.reader
            switch packet.type {
            case .data:
                let data = try payload.bytes()
                schedule.received(data.count, for: chunk)
                guard !data.isEmpty else { continue }
                try writeAll(data, to: localFD, at: chunk.offset)
                received += Int64(data.count)
                try progress(received)
            case .status:
                let error = try Self.statusError(&payload)
                guard error.statusCode == .eof else { throw error }
                schedule.reachedEnd(at: chunk.offset)
            default:
                throw SFTPError.unexpectedData
            }
        }
        return received
    }

    /// Creates `path` (failing if it exists) and copies `localFD` into it, pipelining writes.
    /// `progress` gets the bytes the server has acknowledged so far; it may throw to stop,
    /// leaving a partial file for the caller to remove.
    public func upload(
        from localFD: Int32,
        to path: String,
        permissions: UInt32,
        progress: (Int64) throws -> Void
    ) throws {
        let handle = try handle(from: try request(.open) {
            $0.string(path)
            $0.uint32(SFTPOpenFlags([.write, .create, .exclusive]).rawValue)
            $0.attributes(SFTPAttributes(permissions: permissions))
        })
        defer { try? closeHandle(handle) }

        var offset: UInt64 = 0
        var finishedReading = false
        var inFlight: [UInt32: Int] = [:]
        var acknowledged: Int64 = 0
        defer { discarded.formUnion(inFlight.keys) }
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)

        while true {
            while !finishedReading, inFlight.count < Self.maximumRequestsInFlight {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(localFD, $0.baseAddress, Self.chunkSize) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard count > 0 else {
                    finishedReading = true
                    break
                }
                let data = Data(buffer[0..<count])
                let id = try request(.write) { $0.bytes(handle); $0.uint64(offset); $0.bytes(data) }
                inFlight[id] = count
                offset += UInt64(count)
            }
            guard let packet = try receiveAny(of: Set(inFlight.keys)) else { break }
            let length = inFlight.removeValue(forKey: packet.id) ?? 0
            var payload = packet.reader
            guard packet.type == .status else { throw SFTPError.unexpectedData }
            let error = try Self.statusError(&payload)
            guard error.statusCode == .ok else { throw error }
            acknowledged += Int64(length)
            try progress(acknowledged)
        }
    }
}

/// Which parts of a file to read next. Reads cover the expected size; past it, one read at a
/// time until the server says where the file ends (it may have grown). Short reads leave
/// gaps that are read again.
struct DownloadSchedule {
    struct Chunk {
        let offset: UInt64
        let length: UInt32
    }

    private var limit: UInt64
    private let chunkSize: UInt32
    private var nextOffset: UInt64 = 0
    private var endOfFile: UInt64?
    private var gaps: [Chunk] = []

    init(expectedSize: UInt64, chunkSize: UInt32) {
        limit = expectedSize
        self.chunkSize = chunkSize
    }

    /// The next chunk to request; `idle` when no request is in flight.
    mutating func next(idle: Bool) -> Chunk? {
        if let gap = gaps.popLast() { return gap }
        if let endOfFile, nextOffset >= endOfFile { return nil }
        if nextOffset >= limit {
            guard idle else { return nil }
            limit = nextOffset + UInt64(chunkSize)
        }
        let length = UInt32(min(UInt64(chunkSize), limit - nextOffset))
        defer { nextOffset += UInt64(length) }
        return Chunk(offset: nextOffset, length: length)
    }

    /// `count` bytes arrived for `chunk`: nothing means the end of the file.
    mutating func received(_ count: Int, for chunk: Chunk) {
        if count == 0 {
            reachedEnd(at: chunk.offset)
        } else if count < Int(chunk.length) {
            gaps.append(Chunk(offset: chunk.offset + UInt64(count), length: chunk.length - UInt32(count)))
        }
    }

    mutating func reachedEnd(at offset: UInt64) {
        endOfFile = min(endOfFile ?? .max, offset)
    }
}
