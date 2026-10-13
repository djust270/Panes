import Foundation

/// What a Properties dialog adds up: files and folders inside, and their size and size on disk.
public struct ContentTotals: Sendable, Hashable {
    public var files = 0
    public var folders = 0
    /// Logical size in bytes.
    public var size: Int64 = 0
    /// Allocated size in bytes ("Size on disk").
    public var sizeOnDisk: Int64 = 0
    /// Folders that couldn't be read (permissions), so the totals are a minimum.
    public var unreadable = 0

    public init() {}

    /// "12 Files, 3 Folders", as on Windows.
    public var containsText: String {
        Self.countText(files: files, folders: folders)
    }

    public static func countText(files: Int, folders: Int) -> String {
        let fileText = files == 1 ? "1 File" : "\(files.formatted()) Files"
        let folderText = folders == 1 ? "1 Folder" : "\(folders.formatted()) Folders"
        return "\(fileText), \(folderText)"
    }

    /// "1.2 MB (1,234,567 bytes)", as on Windows.
    public static func sizeText(_ bytes: Int64) -> String {
        let exact = bytes == 1 ? "1 byte" : "\(bytes.formatted()) bytes"
        return "\(FileSizeFormat.string(for: bytes)) (\(exact))"
    }
}

/// Adds up the items in a selection, descending into folders. Packages (apps, bundles) count
/// as one file whose size includes everything inside; symbolic links count as themselves.
public enum ContentCounter {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
    ]

    /// Running totals for `urls`, at most every `interval`; the stream ends after the final
    /// totals. Folders' own entries aren't counted, only what's inside them — so a folder's
    /// "Contains" is its totals, as on Windows.
    public static func count(_ urls: [URL], interval: TimeInterval = 0.1) -> AsyncStream<ContentTotals> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var lastReport = Date()
                let report: (ContentTotals) -> Void = { running in
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) >= interval else { return }
                    lastReport = now
                    continuation.yield(running)
                }
                let totals = totals(of: urls, isCancelled: { Task.isCancelled }, progress: report)
                if !Task.isCancelled { continuation.yield(totals) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The totals for `urls`, calling `progress` with running totals as it goes.
    public static func totals(
        of urls: [URL],
        isCancelled: () -> Bool = { false },
        progress: (ContentTotals) -> Void = { _ in }
    ) -> ContentTotals {
        var totals = ContentTotals()
        for url in urls {
            guard !isCancelled() else { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
                addContents(of: url, to: &totals, isCancelled: isCancelled, progress: progress)
            } else if values?.isPackage == true {
                totals.files += 1
                addContents(of: url, to: &totals, countingItems: false, isCancelled: isCancelled, progress: progress)
            } else {
                totals.files += 1
                add(values, to: &totals)
            }
        }
        return totals
    }

    private static func addContents(
        of folder: URL,
        to totals: inout ContentTotals,
        countingItems: Bool = true,
        isCancelled: () -> Bool,
        progress: (ContentTotals) -> Void
    ) {
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else {
            totals.unreadable += 1
            return
        }
        // Inside a package, sizes count but the items don't (the package is one "file").
        var packagePath: String?
        for case let url as URL in enumerator {
            if isCancelled() { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = url.path
            if let current = packagePath, !path.hasPrefix(current + "/") { packagePath = nil }
            let counts = countingItems && packagePath == nil
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                if values?.isPackage == true, packagePath == nil {
                    if counts { totals.files += 1 }
                    packagePath = path
                } else if counts {
                    totals.folders += 1
                }
            } else {
                if counts { totals.files += 1 }
                add(values, to: &totals)
            }
            progress(totals)
        }
        totals.unreadable += unreadable
    }

    private static func add(_ values: URLResourceValues?, to totals: inout ContentTotals) {
        totals.size += Int64(values?.fileSize ?? 0)
        totals.sizeOnDisk += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
