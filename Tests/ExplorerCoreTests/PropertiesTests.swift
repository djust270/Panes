import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ContentCounterTests {
    @Test func countsFilesFoldersAndSizes() throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt", contents: "12345")
        try temp.createFile(at: "sub/b.txt", contents: "123")
        try temp.createFile(at: "sub/deeper/c.txt", contents: "1")
        try temp.createDirectory("empty")

        let totals = ContentCounter.totals(of: [temp.url])
        #expect(totals.files == 3)
        #expect(totals.folders == 3)
        #expect(totals.size == 9)
        #expect(totals.sizeOnDisk >= totals.size)
        #expect(totals.containsText == "3 Files, 3 Folders")
    }

    @Test func packagesCountAsOneFileWithTheirContentsSize() throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "Tool.app/Contents/Info.plist", contents: "1234567890")
        try temp.createFile(at: "Tool.app/Contents/MacOS/tool", contents: "12345")
        try temp.createFile(at: "after.txt", contents: "1")

        let totals = ContentCounter.totals(of: [temp.url])
        #expect(totals.files == 2)
        #expect(totals.folders == 0)
        #expect(totals.size == 16)
    }

    @Test func selectedFilesCountThemselves() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile("one.txt", contents: "abc")
        let totals = ContentCounter.totals(of: [file])
        #expect(totals.files == 1)
        #expect(totals.size == 3)
    }

    @Test func streamEndsWithTheFinalTotals() async throws {
        let temp = try TemporaryDirectory()
        for index in 0..<20 { try temp.createFile(at: "d\(index % 3)/f\(index).txt", contents: "xx") }
        var last = ContentTotals()
        for await totals in ContentCounter.count([temp.url], interval: 0) { last = totals }
        #expect(last.files == 20)
        #expect(last.folders == 3)
        #expect(last.size == 40)
    }

    @Test func sizeTextShowsExactBytes() {
        #expect(ContentTotals.sizeText(1) == "1 byte (1 byte)")
        #expect(ContentTotals.sizeText(2_048).hasSuffix("(2,048 bytes)"))
        #expect(ContentTotals.countText(files: 1, folders: 0) == "1 File, 0 Folders")
    }
}

@Suite struct PermissionsTests {
    @Test func mapsPosixBitsToWindowsPermissions() {
        let file = WindowsPermissions.permissions(for: [.read, .write], isDirectory: false, isOwner: true)
        #expect(file == [.fullControl, .modify, .read, .write])
        let groupFile = WindowsPermissions.permissions(for: [.read, .write], isDirectory: false, isOwner: false)
        #expect(groupFile == [.modify, .read, .write])
        let folder = WindowsPermissions.permissions(for: [.read, .execute], isDirectory: true, isOwner: false)
        #expect(folder == [.read, .readAndExecute, .listFolderContents])
        let writableFolder = WindowsPermissions.permissions(for: [.read, .write], isDirectory: true, isOwner: true)
        #expect(!writableFolder.contains(.modify))
        #expect(WindowsPermissions.permissions(for: [], isDirectory: true, isOwner: true).isEmpty)
    }

    @Test func checkboxesCascadeLikeWindows() {
        func set(_ access: PosixAccess, _ permission: WindowsPermission, _ on: Bool,
                 folder: Bool = false) -> PosixAccess {
            WindowsPermissions.access(access, setting: permission, to: on, isDirectory: folder)
        }
        #expect(set([], .modify, true) == [.read, .write])
        #expect(set([], .modify, true, folder: true) == .all)
        #expect(set(.all, .modify, false) == [.read, .execute])
        #expect(set([.read], .readAndExecute, true) == [.read, .execute])
        #expect(set(.all, .read, false) == [.write, .execute])
        #expect(set([.read, .write], .fullControl, true) == [.read, .write])
    }

    @Test func posixRowsAndModeEditing() {
        let rows = WindowsPermissions.posixEntries(mode: 0o750, owner: "dave", group: "staff", isDirectory: true)
        #expect(rows.map(\.name) == ["dave (Owner)", "staff (Group)", "Everyone"])
        #expect(rows[0].allowed.contains(.fullControl))
        #expect(rows[1].allowed == [.read, .readAndExecute, .listFolderContents])
        #expect(rows[2].allowed.isEmpty)

        #expect(WindowsPermissions.mode(0o750, setting: [.read, .execute], for: .everyone) == 0o755)
        #expect(WindowsPermissions.mode(0o4755, setting: .all, for: .group) == 0o4775)
    }

    @Test func accessControlEntriesBecomeWindowsRows() {
        let text = """
        !#acl 1
        group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete
        user:5DB1F5C2-0000-0000-0000-000000000001:alice:501:allow:list,add_file,search,add_subdirectory,\
        delete_child,readattr,file_inherit
        user:5DB1F5C2-0000-0000-0000-000000000002:bob:502:allow:readattr,readextattr

        """
        let rows = WindowsPermissions.accessControlEntries(fromText: text, isDirectory: true)
        #expect(rows.map(\.name) == ["Everyone", "alice", "bob"])
        #expect(rows[0].denied == [.special])
        #expect(rows[0].allowed.isEmpty)
        #expect(rows[1].allowed == [.read, .write, .readAndExecute, .listFolderContents, .modify])
        #expect(rows[2].allowed == [.special])
    }

    @Test func mergesEveryoneIntoOneRow() {
        let posix = WindowsPermissions.posixEntries(mode: 0o755, owner: "me", group: "staff", isDirectory: true)
        let acl = WindowsPermissions.accessControlEntries(
            fromText: "group:X:everyone:12:deny:delete\nuser:Y:bob:502:allow:read\n", isDirectory: true)
        let rows = WindowsPermissions.combined(posix: posix, accessControl: acl)
        #expect(rows.map(\.name) == ["me (Owner)", "staff (Group)", "Everyone", "bob"])
        #expect(rows[2].denied == [.special])
        #expect(rows[2].allowed.contains(.readAndExecute))
    }

    @Test func readsTheHomeFoldersAccessControlList() {
        // macOS puts "everyone deny delete" on the home folder.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rows = WindowsPermissions.accessControlEntries(of: home, isDirectory: true)
        #expect(rows.contains { $0.name == "Everyone" && $0.denied.contains(.special) })
    }
}

@Suite struct FileMetadataTests {
    @Test func groupsAndFormatsValues() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let sections = FileMetadata.sections(from: [
            "kMDItemPixelWidth": NSNumber(value: 4032),
            "kMDItemPixelHeight": NSNumber(value: 3024),
            "kMDItemAcquisitionModel": "iPhone 15",
            "kMDItemFNumber": NSNumber(value: 1.78),
            "kMDItemExposureTimeSeconds": NSNumber(value: 0.008),
            "kMDItemStarRating": NSNumber(value: 3),
            "kMDItemWhereFroms": ["https://example.com/a.jpg", "https://example.com/"],
            "kMDItemContentCreationDate": Date(timeIntervalSince1970: 0),
            "kMDItemAudioBitRate": NSNumber(value: 256_000),
            "kMDItemTitle": "  ",
        ], dateFormatter: formatter)

        #expect(sections.map(\.title) == ["Description", "Origin", "Image", "Camera", "Audio"])
        let rows = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.name, $0.value) })
        #expect(rows["Width"] == "4032 pixels")
        #expect(rows["F-stop"] == "f/1.78")
        #expect(rows["Exposure time"] == "1/125 sec.")
        #expect(rows["Rating"] == "★★★☆☆")
        #expect(rows["Where from"] == "https://example.com/a.jpg; https://example.com/")
        #expect(rows["Content created"] == "1970-01-01")
        #expect(rows["Bit rate"] == "256kbps")
        #expect(rows["Title"] == nil)
    }
}

@Suite struct ArchiveTests {
    @Test func recognisesArchivesAndNamesTheirFolder() {
        let zip = URL(fileURLWithPath: "/tmp/Photos.ZIP")
        let tarball = URL(fileURLWithPath: "/tmp/src-1.2.tar.gz")
        #expect(Archive.isExtractable(zip))
        #expect(Archive.isExtractable(tarball))
        #expect(Archive.isExtractable(URL(fileURLWithPath: "/tmp/a.7z")))
        #expect(!Archive.isExtractable(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!Archive.isExtractable(URL(fileURLWithPath: "/tmp/.tar")))
        #expect(Archive.defaultDestination(for: zip).path == "/tmp/Photos")
        #expect(Archive.stem(of: tarball) == "src-1.2")
        #expect(Archive.extractionCommand(for: zip, into: URL(fileURLWithPath: "/x")).tool == "/usr/bin/ditto")
        #expect(Archive.extractionCommand(for: tarball, into: URL(fileURLWithPath: "/x")).arguments.last == "/x")
    }

    @Test func extractsAZipMadeByDitto() throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "Folder/inner.txt", contents: "hi")
        let archive = temp.path("Folder.zip")
        let compress = Process()
        compress.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        compress.arguments = ["-c", "-k", "--keepParent", temp.path("Folder").path, archive.path]
        try compress.run()
        compress.waitUntilExit()

        let output = try temp.createDirectory("out")
        let command = Archive.extractionCommand(for: archive, into: output)
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: command.tool)
        extract.arguments = command.arguments
        try extract.run()
        extract.waitUntilExit()
        #expect(try temp.contents("out/Folder/inner.txt") == "hi")
    }
}
