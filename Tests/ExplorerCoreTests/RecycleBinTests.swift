import Foundation
import Testing
@testable import ExplorerCore

@Suite struct DSStoreTests {
    @Test func readsPutBackLocations() throws {
        let data = DSStoreFixture.make(records: [
            .init("a 10.31.12.txt", "ptbL", "Users/me/Desktop/"),
            .init("a 10.31.12.txt", "ptbN", "a.txt"),
            .init("Folder", "ptbL", "Users/me/Documents/"),
            .init("Folder", "ptbN", "Folder"),
        ])
        let store = try DSStore(data: data)
        #expect(store.records.count == 4)

        let locations = store.putBackLocations(volumeRoot: URL(fileURLWithPath: "/Volumes/Stick"))
        #expect(locations["a 10.31.12.txt"]?.path == "/Volumes/Stick/Users/me/Desktop/a.txt")
        #expect(locations["Folder"]?.path == "/Volumes/Stick/Users/me/Documents/Folder")
    }

    @Test func rejectsMalformedData() {
        let data = DSStoreFixture.make(records: [.init("a", "ptbL", "x/")])
        #expect(throws: DSStore.FormatError.self) { try DSStore(data: data.prefix(100)) }
        #expect(throws: DSStore.FormatError.self) { try DSStore(data: Data("not a ds_store".utf8)) }
    }
}

@Suite struct TrashLogTests {
    @Test func remembersOriginalsWhileTheTrashedItemExists() throws {
        let temp = try TemporaryDirectory()
        let trashed = try temp.createFile(at: "trash/a.txt")
        let original = temp.path("docs/a.txt")
        let logURL = temp.path("log.json")

        TrashLog(fileURL: logURL).record(original: original, trashed: trashed)
        #expect(TrashLog(fileURL: logURL).originalURL(forTrashed: trashed) == original)

        try FileManager.default.removeItem(at: trashed)
        #expect(TrashLog(fileURL: logURL).originalURL(forTrashed: trashed) == nil)
    }

    @Test func recycleBinListingUsesTheLog() throws {
        let temp = try TemporaryDirectory()
        let trash = try temp.createDirectory("trash")
        let trashed = try temp.createFile(at: "trash/a.txt", contents: "x")
        try temp.createFile(at: "trash/unknown.txt")
        let log = TrashLog(fileURL: temp.path("log.json"))
        log.record(original: temp.path("docs/a.txt"), trashed: trashed)

        let items = try RecycleBin.contents(of: trash, includeHidden: false, log: log)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(byName["a.txt"]?.trashInfo?.originalURL == temp.path("docs/a.txt").standardizedFileURL)
        #expect(byName["a.txt"]?.trashInfo?.dateDeleted != nil)
        #expect(byName["unknown.txt"]?.trashInfo?.originalURL == nil)
    }
}

@Suite struct ThroughputMeterTests {
    @Test func averagesOverTheWindow() {
        var meter = ThroughputMeter(window: 2)
        #expect(meter.bytesPerSecond == nil)
        meter.record(bytes: 0, at: 0)
        meter.record(bytes: 100, at: 0.25)
        #expect(meter.bytesPerSecond == nil) // under half a second observed

        meter.record(bytes: 1_000, at: 1)
        #expect(meter.bytesPerSecond == 1_000)
        meter.record(bytes: 5_000, at: 3)
        meter.record(bytes: 9_000, at: 4)
        #expect(meter.bytesPerSecond == 4_000) // only samples from t ≥ 2 count
        #expect(meter.secondsRemaining(totalBytes: 17_000) == 2)
    }

    @Test func resetForgetsHistory() {
        var meter = ThroughputMeter()
        meter.record(bytes: 0, at: 0)
        meter.record(bytes: 1_000, at: 1)
        meter.reset()
        #expect(meter.bytesPerSecond == nil)
    }

    @Test func timeRemainingText() {
        #expect(FileOperationText.timeRemaining(nil) == "Calculating…")
        #expect(FileOperationText.timeRemaining(0.2) == "About 1 second")
        #expect(FileOperationText.timeRemaining(7) == "About 7 seconds")
        #expect(FileOperationText.timeRemaining(42) == "About 45 seconds")
        #expect(FileOperationText.timeRemaining(125) == "About 2 minutes")
        #expect(FileOperationText.timeRemaining(3_900) == "About 1 hour and 5 minutes")
        #expect(FileOperationText.timeRemaining(7_200) == "About 2 hours")
    }

    @Test func summaryText() {
        let request = FileOperationRequest.copy(
            [URL(fileURLWithPath: "/tmp/src/a.txt")],
            into: URL(fileURLWithPath: "/tmp/dst", isDirectory: true)
        )
        #expect(FileOperationText.summary(of: request, itemCount: 1) == "Copying 1 item from src to dst")
        #expect(FileOperationText.summary(of: .trash([URL(fileURLWithPath: "/tmp/src/a.txt")]), itemCount: 3)
            == "Deleting 3 items from src")
    }
}

/// Builds a minimal `.DS_Store` holding `ustr` records in a single leaf node.
enum DSStoreFixture {
    struct Record {
        let name: String
        let code: String
        let value: String

        init(_ name: String, _ code: String, _ value: String) {
            self.name = name
            self.code = code
            self.value = value
        }
    }

    static func make(records: [Record]) -> Data {
        let blockSize = 0x1000
        var blocks = [Data](repeating: Data(), count: 3)

        // Block 0: allocator info — block addresses, then the "DSDB" directory entry.
        var root = Data()
        root.append(uint32: 3)
        root.append(uint32: 0)
        for index in 1...3 {
            root.append(uint32: UInt32(index * blockSize) | 12) // offset | log2(size)
        }
        root.append(Data(count: (256 - 3) * 4))
        root.append(uint32: 1)
        root.append(UInt8(4))
        root.append(Data("DSDB".utf8))
        root.append(uint32: 1)
        blocks[0] = root

        // Block 1: DSDB header — root node, levels, records, nodes, page size.
        var treeHeader = Data()
        for value in [2, 0, records.count, 1, blockSize] {
            treeHeader.append(uint32: UInt32(value))
        }
        blocks[1] = treeHeader

        // Block 2: leaf node.
        var leaf = Data()
        leaf.append(uint32: 0)
        leaf.append(uint32: UInt32(records.count))
        for record in records {
            leaf.append(utf16: record.name)
            leaf.append(Data(record.code.utf8))
            leaf.append(Data("ustr".utf8))
            leaf.append(utf16: record.value)
        }
        blocks[2] = leaf

        var file = Data()
        file.append(uint32: 1)
        file.append(Data("Bud1".utf8))
        file.append(uint32: UInt32(blockSize))
        file.append(uint32: UInt32(blockSize))
        file.append(uint32: UInt32(blockSize))
        for (index, block) in blocks.enumerated() {
            let start = 4 + (index + 1) * blockSize
            file.append(Data(count: start - file.count))
            file.append(block)
        }
        file.append(Data(count: 4 + 4 * blockSize - file.count))
        return file
    }
}

private extension Data {
    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    /// Length in UTF-16 units, then UTF-16BE.
    mutating func append(utf16 string: String) {
        let units = Array(string.utf16)
        append(uint32: UInt32(units.count))
        for unit in units {
            append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)])
        }
    }
}
