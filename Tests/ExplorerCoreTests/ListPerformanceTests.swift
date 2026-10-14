import Foundation
import Testing
@testable import ExplorerCore

/// Sorting and grouping 100k items, as a folder view does on every change. In a debug build
/// each takes 0.4–1.7 s here (release about half); the limit is loose for slower CI machines
/// but catches per-comparison costs creeping back (sorting by type once took 89 s).
/// Opt-in: `EXPLORER_PERF_TESTS=1 scripts/test.sh --filter ListPerformance`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXPLORER_PERF_TESTS"] == "1"))
struct ListPerformanceTests {
    static let items: [FileItem] = {
        let extensions = ["txt", "jpg", "pdf", "swift", "png", "md", "zip", "mov", "docx", "csv"]
        let types = ["public.plain-text", "public.jpeg", "com.adobe.pdf", "public.swift-source", "public.png",
                     "net.daringfireball.markdown", "public.zip-archive", "com.apple.quicktime-movie",
                     "org.openxmlformats.wordprocessingml.document", "public.comma-separated-values-text"]
        let folder = URL(fileURLWithPath: "/tmp/big", isDirectory: true)
        return (0..<100_000).map { index in
            let name = "file \(String(format: "%06d", (index * 7919) % 100_000)).\(extensions[index % 10])"
            return FileItem(url: folder.appendingPathComponent(name), name: name, kind: .file,
                            size: Int64(index % 5000) * 1000, dateModified: Date(timeIntervalSince1970: Double(index)),
                            typeIdentifier: types[index % 10])
        }
    }()

    static func time(_ label: String, _ body: () -> Void) -> Double {
        let start = Date()
        body()
        let seconds = Date().timeIntervalSince(start)
        print("\(label): \(Int(seconds * 1000)) ms")
        return seconds
    }

    @Test(arguments: [FileItemSortKey.name, .type, .size, .dateModified])
    func sorting(key: FileItemSortKey) {
        let items = Self.items
        let seconds = Self.time("sort by \(key)") {
            _ = FileListContent(items: items, sort: FileItemSort(key: key))
        }
        #expect(seconds < 5)
    }

    @Test(arguments: [FileGroupKey.name, .type, .size, .dateModified])
    func grouping(key: FileGroupKey) {
        let items = Self.items
        let seconds = Self.time("group by \(key)") {
            _ = FileListContent(items: items, sort: FileItemSort(), grouping: FileGrouping(key: key))
        }
        #expect(seconds < 5)
    }
}
