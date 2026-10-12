import Foundation
import Testing
@testable import ExplorerCore

/// Copy/move against a real second volume: an exFAT disk image mounted for the suite.
/// Opt-in because it needs `hdiutil` and takes a few seconds: `EXPLORER_VOLUME_TESTS=1 scripts/test.sh`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXPLORER_VOLUME_TESTS"] == "1"), .serialized)
struct VolumeOperationTests {
    @Test func copiesAcrossVolumesKeepingExtendedAttributes() async throws {
        let volume = try ExFATVolume()
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "src/Folder/a.txt", contents: "alpha")
        #expect(setxattr(file.path, "com.example.test", "value", 5, 0, 0) == 0)

        let out = await perform(.copy([temp.path("src/Folder")], into: volume.url), in: temp)
        #expect(out.failures.isEmpty)
        #expect(try String(contentsOf: volume.url.appendingPathComponent("Folder/a.txt"), encoding: .utf8) == "alpha")

        // Back onto APFS: the attribute survived its stay in an AppleDouble file.
        try temp.createDirectory("back")
        _ = await perform(.copy([volume.url.appendingPathComponent("Folder")], into: temp.path("back")), in: temp)
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(temp.path("back/Folder/a.txt").path, "com.example.test", &buffer, buffer.count, 0, 0)
        #expect(length == 5)
    }

    @Test func movesAcrossVolumesAndUndoes() async throws {
        let volume = try ExFATVolume()
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/Folder/inner/b.txt", contents: "beta")

        let result = await perform(.move([temp.path("src/Folder")], into: volume.url), in: temp)
        #expect(!temp.exists("src/Folder"))
        #expect(FileManager.default.fileExists(atPath: volume.url.appendingPathComponent("Folder/inner/b.txt").path))

        _ = await perform(try #require(result.inverse), in: temp)
        #expect(try temp.contents("src/Folder/inner/b.txt") == "beta")
        #expect(!FileManager.default.fileExists(atPath: volume.url.appendingPathComponent("Folder").path))
    }

    @Test func cancellingMidFileRemovesThePartialCopy() async throws {
        let volume = try ExFATVolume()
        let temp = try TemporaryDirectory()
        let big = temp.path("big.bin")
        try Data(repeating: 7, count: 256 << 20).write(to: big)

        let task = makeTask(.copy([big], into: volume.url), in: temp)
        let sawPartial = Recorder<Bool>()
        let result = await run(task, handlers: FileOperationHandlers(progress: { progress in
            if progress.completedBytes > 0, progress.completedBytes < progress.totalBytes {
                sawPartial.append(true)
                task.cancel()
            }
        }))

        #expect(!sawPartial.items.isEmpty, "copy finished before any partial progress was reported")
        #expect(result.wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: volume.url.appendingPathComponent("big.bin").path))
        #expect(temp.exists("big.bin"))
    }

    @Test func caseInsensitiveNamesConflict() async throws {
        let volume = try ExFATVolume()
        let temp = try TemporaryDirectory()
        try Data("old".utf8).write(to: volume.url.appendingPathComponent("readme.txt"))
        try temp.createFile(at: "README.txt", contents: "new")

        let conflicts = Recorder<FileConflict>()
        _ = await perform(
            .copy([temp.path("README.txt")], into: volume.url),
            in: temp,
            handlers: FileOperationHandlers(conflict: { conflict, reply in
                conflicts.append(conflict)
                reply(ConflictDecision(.keepBoth))
            })
        )

        #expect(conflicts.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: volume.url.appendingPathComponent("README (2).txt").path))
    }
}

/// A freshly formatted exFAT disk image, mounted privately and detached on deinit.
private final class ExFATVolume {
    let url: URL
    private let image: TemporaryDirectory

    init() throws {
        image = try TemporaryDirectory()
        let dmg = image.path("volume.dmg").path
        let name = "EXPT\(Int.random(in: 1000...9999))" // exFAT labels max out at 11 characters
        try Self.hdiutil(["create", "-size", "400m", "-fs", "ExFAT", "-volname", name, dmg])
        let mountPoint = image.path("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.hdiutil(["attach", "-nobrowse", "-mountpoint", mountPoint.path, dmg])
        url = mountPoint.standardizedFileURL
    }

    deinit {
        try? Self.hdiutil(["detach", "-force", url.path])
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments + ["-quiet"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments[0]) failed"])
        }
    }
}
