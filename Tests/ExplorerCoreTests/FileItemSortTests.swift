import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FileItemSortTests {
    private func file(_ name: String, size: Int64? = nil, dateModified: Date? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/\(name)"), name: name, kind: .file, size: size, dateModified: dateModified)
    }

    private func folder(_ name: String) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/\(name)", isDirectory: true), name: name, kind: .directory)
    }

    @Test func foldersClusterBeforeFilesAscending() {
        let items = [file("b.txt"), folder("Z"), file("a.txt")]
        let sorted = FileItemSort(key: .name, ascending: true).sorted(items)
        #expect(sorted.map(\.name) == ["Z", "a.txt", "b.txt"])
    }

    @Test func foldersClusterBeforeFilesDescending() {
        let items = [file("b.txt"), folder("Z"), file("a.txt")]
        let sorted = FileItemSort(key: .name, ascending: false).sorted(items)
        #expect(sorted.map(\.name) == ["Z", "b.txt", "a.txt"])
    }

    @Test func nameSortIsNatural() {
        let items = [file("File 10"), file("File 2"), file("File 1")]
        let sorted = FileItemSort(key: .name, ascending: true).sorted(items)
        #expect(sorted.map(\.name) == ["File 1", "File 2", "File 10"])
    }

    @Test func dateModifiedSortsNilAsOldest() {
        let now = Date()
        let items = [file("a", dateModified: now), file("b", dateModified: nil)]
        let ascending = FileItemSort(key: .dateModified, ascending: true).sorted(items)
        #expect(ascending.map(\.name) == ["b", "a"])

        let descending = FileItemSort(key: .dateModified, ascending: false).sorted(items)
        #expect(descending.map(\.name) == ["a", "b"])
    }

    @Test func sizeSortPutsNilLastRegardlessOfDirection() {
        let items = [file("a", size: 100), file("b", size: nil), file("c", size: 10)]
        let ascending = FileItemSort(key: .size, ascending: true).sorted(items)
        #expect(ascending.map(\.name) == ["c", "a", "b"])

        let descending = FileItemSort(key: .size, ascending: false).sorted(items)
        #expect(descending.map(\.name) == ["a", "c", "b"])
    }

    @Test func tiesBreakByName() {
        let items = [file("b", size: 10), file("a", size: 10)]
        let sorted = FileItemSort(key: .size, ascending: true).sorted(items)
        #expect(sorted.map(\.name) == ["a", "b"])
    }
}
