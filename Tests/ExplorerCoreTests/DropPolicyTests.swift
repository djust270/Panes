import Foundation
import Testing
@testable import ExplorerCore

@Suite struct DropPolicyTests {
    @Test func sameVolumeMovesUnlessCopyIsForced() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "src/a.txt")
        let destination = try temp.createDirectory("dst")

        #expect(DropPolicy.operation(for: [file], into: destination, intent: .automatic) == .move)
        #expect(DropPolicy.operation(for: [file], into: destination, intent: .forceCopy) == .copy)
        #expect(DropPolicy.operation(for: [file], into: destination, intent: .forceMove) == .move)
    }

    @Test func otherVolumeCopies() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "a.txt")
        // /dev is its own (devfs) volume on every Mac.
        #expect(DropPolicy.operation(for: [file], into: URL(fileURLWithPath: "/dev"), intent: .automatic) == .copy)
    }

    @Test func rejectsFolderIntoItselfAndPointlessMoves() throws {
        let temp = try TemporaryDirectory()
        let folder = try temp.createDirectory("Folder")
        let sub = try temp.createDirectory("Folder/sub")
        let file = try temp.createFile(at: "Folder/a.txt")

        #expect(DropPolicy.operation(for: [folder], into: folder, intent: .forceCopy) == nil)
        #expect(DropPolicy.operation(for: [folder], into: sub, intent: .automatic) == nil)
        #expect(DropPolicy.operation(for: [file], into: folder, intent: .automatic) == nil)
        // Ctrl-dragging into the same folder duplicates, as on Windows.
        #expect(DropPolicy.operation(for: [file], into: folder, intent: .forceCopy) == .copy)
    }
}
