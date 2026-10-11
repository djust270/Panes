import Foundation

/// Loads the immediate contents of a directory off the main thread.
public struct DirectoryLoader: Sendable {
    public struct Options: Sendable, Hashable {
        public var includeHidden: Bool

        public init(includeHidden: Bool = false) {
            self.includeHidden = includeHidden
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Returns the entries of `directory`, unsorted. Sorting is a view concern.
    ///
    /// Entries that disappear between listing and stat-ing are skipped silently.
    public func contents(of directory: URL) async throws -> [FileItem] {
        let options = self.options
        let task = Task.detached(priority: .userInitiated) {
            try Self.loadSync(directory, options: options)
        }
        // Detached tasks don't inherit cancellation, so forward it explicitly.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func loadSync(_ directory: URL, options: Options) throws -> [FileItem] {
        do {
            return try BulkDirectoryReader.read(directory, includeHidden: options.includeHidden)
        } catch is BulkDirectoryReader.Unsupported {
            return try loadWithFileManager(directory, options: options)
        }
    }

    /// Fallback for file systems that reject `getattrlistbulk`.
    static func loadWithFileManager(_ directory: URL, options: Options) throws -> [FileItem] {
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHidden {
            enumerationOptions.insert(.skipsHiddenFiles)
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: enumerationOptions
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            if let item = try? FileItem(prefetchedURL: url) {
                items.append(item)
            }
        }
        return items
    }
}
