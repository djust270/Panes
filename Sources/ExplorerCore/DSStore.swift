import Foundation

/// A minimal reader for Finder's `.DS_Store` files, used to recover the "Put Back" location
/// (`ptbL` folder + `ptbN` name records) of items Finder moved to the Trash.
///
/// Format: a "buddy allocator" container whose `DSDB` entry is a B-tree of records, each
/// keyed by file name and a four-character code. All integers are big-endian.
struct DSStore {
    enum Value: Equatable {
        case long(UInt32)
        case bool(Bool)
        case type(String)
        case blob(Data)
        case ustr(String)
        case date(UInt64)
    }

    struct Record: Equatable {
        let fileName: String
        let code: String
        let value: Value
    }

    struct FormatError: Error {}

    let records: [Record]

    init(data: Data) throws {
        records = try DSStoreParser(data: data).records()
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// Original location of trashed items, keyed by their name in the Trash. `volumeRoot` is
    /// the root of the Trash's volume; `ptbL` paths are relative to it.
    func putBackLocations(volumeRoot: URL) -> [String: URL] {
        var folders: [String: String] = [:]
        var names: [String: String] = [:]
        for record in records {
            guard case .ustr(let string) = record.value else { continue }
            switch record.code {
            case "ptbL": folders[record.fileName] = string
            case "ptbN": names[record.fileName] = string
            default: break
            }
        }
        var locations: [String: URL] = [:]
        for (trashedName, folder) in folders {
            let originalName = names[trashedName] ?? trashedName
            locations[trashedName] = volumeRoot
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(originalName)
                .standardizedFileURL
        }
        return locations
    }
}

private struct DSStoreParser {
    let data: Data

    func records() throws -> [DSStore.Record] {
        // 4-byte alignment prefix, then the allocator header. Offsets are relative to byte 4.
        var header = Cursor(data: data, offset: 0)
        guard try header.uint32() == 1, try header.fourCC() == "Bud1" else { throw DSStore.FormatError() }
        let rootOffset = Int(try header.uint32())

        var root = Cursor(data: data, offset: rootOffset + 4)
        let blockCount = Int(try root.uint32())
        _ = try root.uint32()
        var blocks: [UInt32] = []
        for _ in 0..<blockCount {
            blocks.append(try root.uint32())
        }
        // The address table is padded to a multiple of 256 entries.
        let padded = (blockCount + 255) / 256 * 256
        try root.skip((padded - blockCount) * 4)

        var directory: [String: UInt32] = [:]
        let directoryCount = Int(try root.uint32())
        for _ in 0..<directoryCount {
            let nameLength = Int(try root.uint8())
            let name = try root.ascii(nameLength)
            directory[name] = try root.uint32()
        }

        // The DSDB header block: root node, levels, record count, node count, page size.
        guard let headerID = directory["DSDB"] else { throw DSStore.FormatError() }
        var treeHeader = try cursor(forBlock: headerID, in: blocks)
        let rootNode = try treeHeader.uint32()

        var records: [DSStore.Record] = []
        var visited = Set<UInt32>()
        try readNode(rootNode, blocks: blocks, into: &records, visited: &visited)
        return records
    }

    private func cursor(forBlock id: UInt32, in blocks: [UInt32]) throws -> Cursor {
        guard Int(id) < blocks.count else { throw DSStore.FormatError() }
        let address = blocks[Int(id)]
        return Cursor(data: data, offset: Int(address & ~0x1F) + 4)
    }

    private func readNode(
        _ id: UInt32,
        blocks: [UInt32],
        into records: inout [DSStore.Record],
        visited: inout Set<UInt32>
    ) throws {
        guard visited.insert(id).inserted, visited.count < 100_000 else { throw DSStore.FormatError() }
        var node = try cursor(forBlock: id, in: blocks)
        let rightmostChild = try node.uint32()
        let count = Int(try node.uint32())
        for _ in 0..<count {
            if rightmostChild != 0 {
                let child = try node.uint32()
                try readNode(child, blocks: blocks, into: &records, visited: &visited)
            }
            records.append(try node.record())
        }
        if rightmostChild != 0 {
            try readNode(rightmostChild, blocks: blocks, into: &records, visited: &visited)
        }
    }
}

private struct Cursor {
    let data: Data
    var offset: Int

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset >= 0, offset + count <= data.count else { throw DSStore.FormatError() }
        let start = data.startIndex + offset
        offset += count
        return data[start..<start + count]
    }

    mutating func skip(_ count: Int) throws {
        _ = try bytes(count)
    }

    mutating func uint8() throws -> UInt8 {
        try bytes(1).first ?? 0
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try bytes(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func ascii(_ count: Int) throws -> String {
        guard let string = String(bytes: try bytes(count), encoding: .ascii) else { throw DSStore.FormatError() }
        return string
    }

    mutating func fourCC() throws -> String {
        try ascii(4)
    }

    /// UTF-16BE string of `count` code units.
    mutating func utf16(_ count: Int) throws -> String {
        let raw = try bytes(count * 2)
        var units: [UInt16] = []
        units.reserveCapacity(count)
        var index = raw.startIndex
        while index < raw.endIndex {
            units.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func record() throws -> DSStore.Record {
        let fileName = try utf16(Int(try uint32()))
        let code = try fourCC()
        let type = try fourCC()
        let value: DSStore.Value
        switch type {
        case "bool": value = .bool(try uint8() != 0)
        case "long", "shor": value = .long(try uint32())
        case "type": value = .type(try fourCC())
        case "blob", "book": value = .blob(try bytes(Int(try uint32())))
        case "ustr": value = .ustr(try utf16(Int(try uint32())))
        case "comp", "dutc": value = .date(try uint64())
        default: throw DSStore.FormatError()
        }
        return DSStore.Record(fileName: fileName, code: code, value: value)
    }
}
