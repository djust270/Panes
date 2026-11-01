import Foundation
import Testing
@testable import ExplorerCore

/// Runs against `/usr/libexec/sftp-server`, the server side of OpenSSH's SFTP, talking to it
/// over pipes as the app does over ssh: real protocol, no sshd needed.
@Suite struct SFTPTests {
    static let server = URL(fileURLWithPath: "/usr/libexec/sftp-server")
    static let host = RemoteHost(user: nil, hostname: "test-server", port: nil)!

    static func client(startingIn folder: URL? = nil) throws -> SFTPClient {
        try SFTPClient.launch(executable: server, arguments: folder.map { ["-d", $0.path] } ?? [], timeout: 10)
    }

    /// The temp folder seen from the "server" (`/var` is a link to `/private/var`).
    static func remote(_ url: URL) -> RemotePath {
        RemotePath(host: host, path: realPath(url))
    }

    /// `realpath(3)`: unlike `resolvingSymlinksInPath`, keeps `/private`.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func task(_ request: FileOperationRequest, in temp: TemporaryDirectory) -> FileOperationTask {
        var environment = fakeTrash(temp)
        environment.openSFTP = { _ in try client() }
        return FileOperationTask(request: request, environment: environment)
    }

    // MARK: Protocol

    @Test func attributesRoundTrip() throws {
        var writer = SFTPWriter(.attrs, id: 7)
        let attributes = SFTPAttributes(size: 1 << 40, permissions: 0o100644, accessTime: 5, modificationTime: 9)
        writer.attributes(attributes)
        var reader = SFTPReader(writer.data)
        #expect(try reader.uint8() == SFTPPacketType.attrs.rawValue)
        #expect(try reader.uint32() == 7)
        #expect(try reader.attributes() == attributes)
        #expect(attributes.fileType == .file)
        #expect(throws: SFTPError.unexpectedData) { try reader.uint32() }
    }

    @Test func handshakeFailsOnNonSFTPOutput() {
        // A shell printing a banner instead of speaking SFTP.
        #expect(throws: SFTPClient.LaunchFailure.self) {
            try SFTPClient.launch(executable: URL(fileURLWithPath: "/bin/echo"),
                                  arguments: ["Welcome to my server!"], timeout: 5)
        }
    }

    // MARK: Listing

    @Test func listsFoldersFollowingLinks() throws {
        let temp = try TemporaryDirectory()
        try temp.createFile("notes.txt", contents: "hello")
        try temp.createFile(".hidden", contents: "x")
        try temp.createDirectory("Photos")
        try FileManager.default.createSymbolicLink(atPath: temp.path("PhotosLink").path, withDestinationPath: "Photos")
        try FileManager.default.createSymbolicLink(atPath: temp.path("notesLink").path,
                                                   withDestinationPath: "notes.txt")
        try FileManager.default.createSymbolicLink(atPath: temp.path("broken").path, withDestinationPath: "nowhere")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temp.path("notes.txt").path)

        let client = try Self.client(startingIn: temp.url)
        defer { client.close() }
        let folder = Self.remote(temp.url)
        #expect(try client.realpath(".") == folder.path)

        let visible = try RemoteListing.items(in: folder, includeHidden: false, using: client)
        let byName = Dictionary(uniqueKeysWithValues: visible.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["notes.txt", "Photos", "PhotosLink", "notesLink", "broken"])
        #expect(byName["notes.txt"]?.kind == .file)
        #expect(byName["notes.txt"]?.size == 5)
        #expect(byName["notes.txt"]?.dateModified == modified)
        #expect(byName["notes.txt"]?.typeIdentifier == "public.plain-text")
        #expect(byName["Photos"]?.isFolder == true)
        #expect(byName["PhotosLink"]?.isFolder == true)
        #expect(byName["notesLink"]?.size == 5)
        #expect(byName["broken"]?.kind == .file)
        #expect(byName["broken"]?.size == nil)
        #expect(byName["notes.txt"]?.isRemote == true)
        #expect(byName["notes.txt"].flatMap { RemotePath(url: $0.url) } == folder.appending("notes.txt"))

        let all = try RemoteListing.items(in: folder, includeHidden: true, using: client)
        #expect(all.contains { $0.name == ".hidden" && $0.isHidden })
    }

    @Test func reportsMissingAndForbiddenFolders() throws {
        let temp = try TemporaryDirectory()
        let locked = try temp.createDirectory("locked")
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }
        let client = try Self.client()
        defer { client.close() }

        #expect(throws: SFTPError.self) { try client.listDirectory(temp.path("missing").path) }
        do {
            _ = try client.listDirectory(temp.path("missing").path)
        } catch let error as SFTPError {
            #expect(error.statusCode == .noSuchFile)
        }
        do {
            _ = try client.listDirectory(locked.path)
            Issue.record("Listing a folder without permission succeeded")
        } catch let error as SFTPError {
            #expect(error.statusCode == .permissionDenied)
        }
        // The channel still works after errors.
        #expect(try client.stat(temp.url.path).fileType == .directory)
    }

    // MARK: Download

    @Test func downloadsFilesAndFolders() async throws {
        let temp = try TemporaryDirectory()
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try temp.createDirectory("server/Folder/inner")
        try big.write(to: temp.path("server/Folder/inner/big.bin"))
        try temp.createFile(at: "server/Folder/a.txt", contents: "alpha")
        try temp.createFile(at: "server/empty.txt")
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: temp.path("server/Folder/a.txt").path)
        try temp.createDirectory("local")

        let server = Self.remote(temp.path("server"))
        let progress = Recorder<FileOperationProgress>()
        let result = await run(
            Self.task(.remoteDownload([server.appending("Folder"), server.appending("empty.txt")],
                                      into: temp.path("local")), in: temp),
            handlers: FileOperationHandlers(progress: { progress.append($0) })
        )

        #expect(result.failures.isEmpty)
        #expect(!result.wasCancelled)
        #expect(try Data(contentsOf: temp.path("local/Folder/inner/big.bin")) == big)
        #expect(try temp.contents("local/Folder/a.txt") == "alpha")
        #expect(try temp.contents("local/empty.txt") == "")
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.path("local/Folder/a.txt").path)
        #expect(attributes[.modificationDate] as? Date == modified)
        #expect(result.resultingItems.map(\.lastPathComponent) == ["Folder", "empty.txt"])
        #expect(result.inverse == .trash(result.resultingItems))
        let last = try #require(progress.items.last)
        #expect(last.totalItems == 5)
        #expect(last.totalBytes == Int64(big.count) + 5)
        #expect(last.completedBytes == last.totalBytes)
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: temp.path("local").path)
        #expect(!leftovers.contains { $0.contains("panes-part") })
    }

    @Test func downloadConflictsKeepBothOrSkip() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "server/a.txt", contents: "new")
        try temp.createFile(at: "server/b.txt", contents: "new")
        try temp.createFile(at: "local/a.txt", contents: "old")
        try temp.createFile(at: "local/b.txt", contents: "old")
        let server = Self.remote(temp.path("server"))

        let asked = Recorder<FileConflict>()
        _ = await run(
            Self.task(.remoteDownload([server.appending("a.txt"), server.appending("b.txt")],
                                      into: temp.path("local")), in: temp),
            handlers: FileOperationHandlers(conflict: { conflict, reply in
                asked.append(conflict)
                reply(ConflictDecision(conflict.source.url.lastPathComponent == "a.txt" ? .keepBoth : .skip))
            })
        )

        #expect(asked.items.count == 2)
        #expect(asked.items.first?.source.url.scheme == "sftp")
        #expect(try temp.contents("local/a.txt") == "old")
        #expect(try temp.contents("local/a (2).txt") == "new")
        #expect(try temp.contents("local/b.txt") == "old")
    }

    @Test func cancellingADownloadLeavesNoPartialFile() async throws {
        let temp = try TemporaryDirectory()
        // Big enough to still be going when the first (throttled) progress report arrives.
        try Data(count: 64_000_000).write(to: temp.path("big.bin"))
        try temp.createDirectory("local")

        let task = Self.task(.remoteDownload([Self.remote(temp.path("big.bin"))], into: temp.path("local")), in: temp)
        let result = await run(task, handlers: FileOperationHandlers(progress: { progress in
            if progress.completedBytes > 0 { task.cancel() }
        }))

        #expect(result.wasCancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path("local").path).isEmpty)
    }

    // MARK: Upload

    @Test func uploadsFilesAndFolders() async throws {
        let temp = try TemporaryDirectory()
        let big = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try temp.createDirectory("local/Folder/inner")
        try big.write(to: temp.path("local/Folder/inner/big.bin"))
        try temp.createFile(at: "local/note.txt", contents: "hi")
        chmod(temp.path("local/note.txt").path, 0o640)
        let modified = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: temp.path("local/note.txt").path)
        try temp.createDirectory("server")

        let result = await run(Self.task(
            .remoteUpload([temp.path("local/Folder"), temp.path("local/note.txt")],
                          into: Self.remote(temp.path("server"))),
            in: temp
        ))

        #expect(result.failures.isEmpty)
        #expect(try Data(contentsOf: temp.path("server/Folder/inner/big.bin")) == big)
        #expect(try temp.contents("server/note.txt") == "hi")
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.path("server/note.txt").path)
        #expect(attributes[.modificationDate] as? Date == modified)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o640)
        #expect(result.resultingItems.map(\.lastPathComponent) == ["Folder", "note.txt"])
        #expect(result.inverse == nil)
        let names = try FileManager.default.subpathsOfDirectory(atPath: temp.path("server").path)
        #expect(!names.contains { $0.contains("panes-upload") })
    }

    @Test func uploadReplacesAndMergesFolders() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "local/Folder/a.txt", contents: "new")
        try temp.createFile(at: "local/Folder/b.txt", contents: "added")
        try temp.createFile(at: "server/Folder/a.txt", contents: "old")
        try temp.createFile(at: "server/Folder/keep.txt", contents: "kept")

        let result = await run(
            Self.task(.remoteUpload([temp.path("local/Folder")], into: Self.remote(temp.path("server"))), in: temp),
            handlers: FileOperationHandlers(conflict: { $1(ConflictDecision(.replace)) })
        )

        #expect(result.failures.isEmpty)
        #expect(try temp.contents("server/Folder/a.txt") == "new")
        #expect(try temp.contents("server/Folder/b.txt") == "added")
        #expect(try temp.contents("server/Folder/keep.txt") == "kept")
    }

    @Test func cancellingAnUploadRemovesTheTemporaryFile() async throws {
        let temp = try TemporaryDirectory()
        try Data(count: 64_000_000).write(to: temp.path("big.bin"))
        try temp.createDirectory("server")

        let task = Self.task(.remoteUpload([temp.path("big.bin")], into: Self.remote(temp.path("server"))), in: temp)
        let result = await run(task, handlers: FileOperationHandlers(progress: { progress in
            if progress.completedBytes > 0 { task.cancel() }
        }))

        #expect(result.wasCancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path("server").path).isEmpty)
    }
}
