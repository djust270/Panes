import Foundation
import Testing
@testable import ExplorerCore

/// Delete, rename and new folder on a server, against `/usr/libexec/sftp-server`.
@Suite struct SFTPEditTests {
    private func remote(_ url: URL) -> RemotePath { SFTPTests.remote(url) }

    private func perform(_ request: FileOperationRequest, in temp: TemporaryDirectory,
                         handlers: FileOperationHandlers = FileOperationHandlers()) async -> FileOperationResult {
        await run(SFTPTests.task(request, in: temp), handlers: handlers)
    }

    // MARK: Delete

    @Test func deletesFilesAndFoldersWithTheirContents() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/a.txt", contents: "a")
        try temp.createFile(at: "server/Folder/inner/b.txt", contents: "b")
        try temp.createFile(at: "server/Folder/.hidden", contents: "h")
        try temp.createFile(at: "server/keep.txt")
        let server = remote(temp.path("server"))

        let progress = Recorder<FileOperationProgress>()
        let result = await perform(.remoteDelete([server.appending("a.txt"), server.appending("Folder")]), in: temp,
                                   handlers: FileOperationHandlers(progress: { progress.append($0) }))

        #expect(result.failures.isEmpty)
        #expect(result.inverse == nil)
        #expect(!temp.exists("server/a.txt"))
        #expect(!temp.exists("server/Folder"))
        #expect(temp.exists("server/keep.txt"))
        #expect(progress.items.last?.totalItems == 5)
        #expect(progress.items.last?.completedItems == 5)
    }

    @Test func deletingALinkLeavesItsTarget() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/Target/precious.txt", contents: "keep me")
        try FileManager.default.createSymbolicLink(atPath: temp.path("server/Link").path,
                                                   withDestinationPath: "Target")
        let result = await perform(.remoteDelete([remote(temp.path("server")).appending("Link")]), in: temp)

        #expect(result.failures.isEmpty)
        #expect(!temp.exists("server/Link"))
        #expect(try temp.contents("server/Target/precious.txt") == "keep me")
    }

    @Test func aFolderStaysWhenSomethingInsideIsSkipped() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/Folder/Locked/stuck.txt")
        try temp.createFile(at: "server/Folder/free.txt")
        chmod(temp.path("server/Folder/Locked").path, 0o555)
        defer { chmod(temp.path("server/Folder/Locked").path, 0o755) }

        let asked = Recorder<FileOperationFailure>()
        let result = await perform(.remoteDelete([remote(temp.path("server")).appending("Folder")]), in: temp,
                                   handlers: FileOperationHandlers(failure: { failure, reply in
                                       asked.append(failure)
                                       reply(.skip)
                                   }))

        #expect(asked.items.count == 1, "only the file that couldn't go, not the folders above it")
        #expect(asked.items.first?.url.lastPathComponent == "stuck.txt")
        #expect(result.failures.count == 1)
        #expect(!temp.exists("server/Folder/free.txt"))
        #expect(temp.exists("server/Folder/Locked/stuck.txt"))
    }

    // MARK: Rename

    @Test func renamesAndUndoes() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/old.txt", contents: "x")
        let server = remote(temp.path("server"))

        let result = await perform(.remoteRename(server.appending("old.txt"), to: "new: name.txt"), in: temp)
        #expect(result.failures.isEmpty)
        #expect(temp.exists("server/new: name.txt"))
        #expect(result.resultingItems == [server.appending("new: name.txt").url])
        #expect(result.inverse == .remoteRename(server.appending("new: name.txt"), to: "old.txt"))

        let undone = await perform(try #require(result.inverse), in: temp)
        #expect(undone.failures.isEmpty)
        #expect(try temp.contents("server/old.txt") == "x")
    }

    @Test func renameRefusesTakenAndInvalidNames() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/a.txt", contents: "a")
        try temp.createFile(at: "server/b.txt", contents: "b")
        let server = remote(temp.path("server"))

        let taken = await perform(.remoteRename(server.appending("a.txt"), to: "b.txt"), in: temp)
        #expect(taken.failures.map(\.reason) == [.alreadyExists])
        #expect(try temp.contents("server/b.txt") == "b")

        let invalid = await perform(.remoteRename(server.appending("a.txt"), to: "x/y"), in: temp)
        #expect(invalid.failures.map(\.reason) == [.invalidName])
        #expect(temp.exists("server/a.txt"))
    }

    @Test func renamesOnlyTheCase() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/readme.txt", contents: "r")
        let server = remote(temp.path("server"))

        let result = await perform(.remoteRename(server.appending("readme.txt"), to: "README.txt"), in: temp)

        #expect(result.failures.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.path("server").path)
        #expect(names == ["README.txt"])
    }

    // MARK: New folder

    @Test func createsNumberedNewFolders() async throws {
        let temp = try TemporaryDirectory()
        try temp.createDirectory("server")
        let server = remote(temp.path("server"))

        let first = await perform(.remoteCreateFolder(in: server, name: "New folder"), in: temp)
        let second = await perform(.remoteCreateFolder(in: server, name: "New folder"), in: temp)

        #expect(first.resultingItems == [server.appending("New folder").url])
        #expect(second.resultingItems == [server.appending("New folder (2)").url])
        #expect(FileStatus(path: temp.path("server/New folder (2)").path)?.type == .directory)
        #expect(first.inverse == nil)
    }
}
