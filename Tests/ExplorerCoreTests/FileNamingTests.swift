import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FileNamingTests {
    @Test func numberedKeepsTheExtension() {
        #expect(FileNaming.numbered("report.txt", 2) == "report (2).txt")
        #expect(FileNaming.numbered("archive.tar.gz", 3) == "archive.tar (3).gz")
        #expect(FileNaming.numbered("README", 2) == "README (2)")
        #expect(FileNaming.numbered(".zshrc", 2) == ".zshrc (2)")
        #expect(FileNaming.numbered("my.folder", 2, hasExtension: false) == "my.folder (2)")
    }

    @Test func uniqueNameSkipsTakenNumbers() {
        let taken: Set = ["New folder", "New folder (2)", "New folder (3)"]
        #expect(FileNaming.uniqueName("New folder", hasExtension: false) { taken.contains($0) } == "New folder (4)")
        #expect(FileNaming.uniqueName("Other", hasExtension: false) { taken.contains($0) } == "Other")
    }

    @Test func copyNamesFollowWindows() {
        var taken: Set<String> = ["a.txt"]
        let first = FileNaming.copyName(for: "a.txt") { taken.contains($0) }
        #expect(first == "a - Copy.txt")
        taken.insert(first)
        #expect(FileNaming.copyName(for: "a.txt") { taken.contains($0) } == "a - Copy (2).txt")
        #expect(FileNaming.copyName(for: "Photos", hasExtension: false) { _ in false } == "Photos - Copy")
        #expect(FileNaming.copyName(for: "Tool.app") { _ in false } == "Tool - Copy.app")
    }

    @Test func packagesKeepExtensionsButFoldersDont() {
        #expect(FileNaming.hasExtension(URL(fileURLWithPath: "/x/Tool.app"), isDirectory: true))
        #expect(!FileNaming.hasExtension(URL(fileURLWithPath: "/x/my.folder"), isDirectory: true))
        #expect(FileNaming.hasExtension(URL(fileURLWithPath: "/x/notes.txt"), isDirectory: false))
    }

    @Test func validation() {
        #expect(FileNaming.validationError(for: "fine name.txt") == nil)
        #expect(FileNaming.validationError(for: "") != nil)
        #expect(FileNaming.validationError(for: "   ") != nil)
        #expect(FileNaming.validationError(for: "a/b") != nil)
        #expect(FileNaming.validationError(for: "a:b") != nil)
        #expect(FileNaming.validationError(for: "..") != nil)
        #expect(FileNaming.validationError(for: String(repeating: "x", count: 256)) != nil)
    }

    @Test func renameSelectsTheStem() {
        let docx = FileNaming.renameSelection(for: "report.final.docx", hasExtension: true)
        #expect(docx == NSRange(location: 0, length: 12))
        #expect(FileNaming.renameSelection(for: "Folder.v2", hasExtension: false) == NSRange(location: 0, length: 9))
        #expect(FileNaming.renameSelection(for: ".zshrc", hasExtension: true) == NSRange(location: 0, length: 6))
        // UTF-16 units, not characters.
        #expect(FileNaming.renameSelection(for: "😀.txt", hasExtension: true) == NSRange(location: 0, length: 2))
    }
}
