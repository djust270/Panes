import Foundation
import Testing
@testable import ExplorerCore

@Suite struct DirectoryLoaderTests {
    @Test func classifiesEntries() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile("notes.txt", contents: "hello")
        try temp.createDirectory("Projects")
        try temp.createDirectory("Tool.app")
        try FileManager.default.createSymbolicLink(
            at: temp.url.appendingPathComponent("link"),
            withDestinationURL: temp.url.appendingPathComponent("notes.txt")
        )

        let items = try await DirectoryLoader().contents(of: temp.url)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(byName.count == 4)
        #expect(byName["notes.txt"]?.kind == .file)
        #expect(byName["notes.txt"]?.size == 5)
        #expect(byName["notes.txt"]?.typeIdentifier == "public.plain-text")
        #expect(byName["notes.txt"]?.dateModified != nil)
        #expect(byName["Projects"]?.kind == .directory)
        #expect(byName["Projects"]?.size == nil)
        #expect(byName["Projects"]?.isFolder == true)
        #expect(byName["Tool.app"]?.kind == .package)
        #expect(byName["Tool.app"]?.isFolder == false)
        #expect(byName["link"]?.kind == .symlink)
    }

    @Test func hiddenFilesFollowOption() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile("visible")
        try temp.createFile(".hidden")

        let defaultItems = try await DirectoryLoader().contents(of: temp.url)
        #expect(defaultItems.map(\.name) == ["visible"])

        let allItems = try await DirectoryLoader(options: .init(includeHidden: true)).contents(of: temp.url)
        #expect(Set(allItems.map(\.name)) == ["visible", ".hidden"])
        #expect(allItems.first { $0.name == ".hidden" }?.isHidden == true)
    }

    @Test func respectsHiddenFlag() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile("flagged")
        #expect(chflags(file.path, UInt32(UF_HIDDEN)) == 0)

        #expect(try await DirectoryLoader().contents(of: temp.url).isEmpty)
    }

    /// The `getattrlistbulk` fast path must agree with the `FileManager` fallback.
    @Test func bulkReaderMatchesFileManager() throws {
        let temp = try TemporaryDirectory()
        try temp.createFile("a.txt", contents: "12345")
        try temp.createFile("b.jpg", contents: "x")
        try temp.createFile("noextension")
        try temp.createFile(".dotfile")
        try temp.createDirectory("Folder")
        try temp.createDirectory("Thing.app")
        try FileManager.default.createSymbolicLink(
            at: temp.url.appendingPathComponent("link"),
            withDestinationURL: temp.url.appendingPathComponent("a.txt")
        )

        let options = DirectoryLoader.Options(includeHidden: true)
        let bulk = try BulkDirectoryReader.read(temp.url, includeHidden: true).sorted { $0.name < $1.name }
        let reference = try DirectoryLoader.loadWithFileManager(temp.url, options: options)
            .sorted { $0.name < $1.name }

        #expect(bulk.map(\.name) == reference.map(\.name))
        for (fast, slow) in zip(bulk, reference) {
            #expect(fast.kind == slow.kind, "\(fast.name)")
            #expect(fast.size == slow.size, "\(fast.name)")
            #expect(fast.isHidden == slow.isHidden, "\(fast.name)")
            #expect(fast.typeIdentifier == slow.typeIdentifier, "\(fast.name)")
            #expect(fast.url.standardizedFileURL.path == slow.url.standardizedFileURL.path, "\(fast.name)")
            let drift = abs((fast.dateModified ?? .distantPast).timeIntervalSince(slow.dateModified ?? .distantFuture))
            #expect(drift < 0.001, "\(fast.name)")
        }
    }

    @Test func missingDirectoryThrows() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            try await DirectoryLoader().contents(of: missing)
        }
    }

    /// Phase 0 exit criterion: 100k entries in under one second.
    /// Opt-in because creating the fixture takes a while: `EXPLORER_PERF_TESTS=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXPLORER_PERF_TESTS"] == "1"))
    func enumerates100kFilesUnderOneSecond() async throws {
        let temp = try TemporaryDirectory()
        let count = 100_000
        for index in 0..<count {
            let path = temp.url.appendingPathComponent("file-\(index).txt").path
            let fd = open(path, O_CREAT | O_WRONLY, 0o644)
            #expect(fd >= 0)
            close(fd)
        }

        let clock = ContinuousClock()
        var items: [FileItem] = []
        let elapsed = try await clock.measure {
            items = try await DirectoryLoader().contents(of: temp.url)
        }

        print("Enumerated \(items.count) items in \(elapsed)")
        #expect(items.count == count)
        #expect(elapsed < .seconds(1))
    }
}
