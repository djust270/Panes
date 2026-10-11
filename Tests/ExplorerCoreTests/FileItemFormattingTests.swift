import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FileItemFormattingTests {
    @Test func directoryIsFolder() {
        let item = FileItem(url: URL(fileURLWithPath: "/dir", isDirectory: true), name: "dir", kind: .directory)
        #expect(item.typeDescription == "Folder")
    }

    @Test func knownExtensionUsesLocalizedDescriptionNotFallback() {
        // The exact system-provided string varies by OS version; just confirm we used it
        // rather than falling back to the bare "<EXT> File" form.
        let item = FileItem(
            url: URL(fileURLWithPath: "/a.txt"),
            name: "a.txt",
            kind: .file,
            typeIdentifier: "public.plain-text"
        )
        #expect(!item.typeDescription.isEmpty)
        #expect(item.typeDescription != "TXT File")
    }

    @Test func unknownExtensionFallsBackToUppercasedExtension() {
        let item = FileItem(url: URL(fileURLWithPath: "/a.xyz123"), name: "a.xyz123", kind: .file, typeIdentifier: nil)
        #expect(item.typeDescription == "XYZ123 File")
    }

    @Test func noExtensionFallsBackToDocument() {
        let item = FileItem(url: URL(fileURLWithPath: "/README"), name: "README", kind: .file, typeIdentifier: nil)
        #expect(item.typeDescription == "Document")
    }
}
