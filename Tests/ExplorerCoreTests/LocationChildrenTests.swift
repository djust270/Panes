import Foundation
import Testing
@testable import ExplorerCore

@Suite struct LocationChildrenTests {
    @Test func listsOnlyFoldersSortedNaturally() throws {
        let dir = try TemporaryDirectory()
        try dir.createFile("b.txt")
        try dir.createDirectory("Folder 10")
        try dir.createDirectory("Folder 2")
        try dir.createDirectory(".hidden")

        let children = LocationChildren.of(.folder(dir.url))
        let names = children.map { $0.fileURL!.lastPathComponent }
        #expect(names == ["Folder 2", "Folder 10"])
    }

    @Test func thisPCListsMountedVolumes() {
        let children = LocationChildren.of(.thisPC)
        #expect(children.contains { $0.fileURL?.path == "/" })
    }

    @Test func homeListsTheCloudFolders() {
        #expect(LocationChildren.of(.home) == CloudStorage.roots().map { .folder($0.url) })
    }

    @Test func nonexistentFolderYieldsEmpty() {
        let missing = ExplorerLocation.folder(path: "/no/such/path-\(UUID().uuidString)")
        #expect(LocationChildren.of(missing).isEmpty)
    }
}
