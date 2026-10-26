import Foundation

/// Online-only files in cloud folders: "Download now", and copies that must download their
/// source first. The sync client downloads; the task asks for it and polls until it's done.
extension FileOperationTask {
    private static let downloadPollInterval: TimeInterval = 0.1

    /// Downloads the online-only files among `urls` and inside folders among them. All are
    /// asked for first, so the sync client can fetch them side by side; cancelling stops the
    /// ones still coming.
    func runDownload(_ urls: [URL]) throws {
        var files: [(url: URL, size: Int64)] = []
        for url in urls {
            try collectOnlineOnlyFiles(at: url, into: &files)
        }
        progress.totalItems = files.count
        progress.totalBytes = files.reduce(0) { $0 + $1.size }
        progress.phase = .running
        report(force: true)

        for file in files {
            try? environment.startDownloading(file.url)
        }
        var next = 0
        do {
            for file in files {
                progress.currentName = file.url.lastPathComponent
                report()
                _ = try attempt(file.url) { try downloadIfOnlineOnly(file.url) }
                progress.completedItems += 1
                progress.completedBytes += file.size
                next += 1
            }
        } catch {
            for file in files[next...] where environment.isOnlineOnly(file.url) {
                environment.stopDownloading(file.url)
            }
            throw error
        }
        result.resultingItems = urls
    }

    private func collectOnlineOnlyFiles(at url: URL, into files: inout [(url: URL, size: Int64)]) throws {
        try checkpoint()
        guard let status = FileStatus(path: url.path) else { return }
        switch status.type {
        case .directory:
            progress.currentName = url.lastPathComponent
            report()
            var names: [String] = []
            // Listing a cloud folder may wait for the sync client to fetch it.
            guard try attempt(url, { names = try FileManager.default.contentsOfDirectory(atPath: url.path) }) else {
                return
            }
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                try collectOnlineOnlyFiles(at: url.appendingPathComponent(name), into: &files)
            }
        case .file where environment.isOnlineOnly(url):
            files.append((url, status.size))
            progress.totalItems = files.count
        default:
            break
        }
    }

    /// If only a placeholder of `url` is on disk, asks for its contents and waits for them,
    /// telling the progress dialog where they come from. Cancelling stops the download.
    func downloadIfOnlineOnly(_ url: URL, reportingProvider: Bool = false) throws {
        guard environment.isOnlineOnly(url) else { return }
        if reportingProvider {
            progress.downloadingFrom = CloudSync.providerName(for: url) ?? "the cloud"
            report(force: true)
        }
        defer {
            if reportingProvider {
                progress.downloadingFrom = nil
                report(force: true)
            }
        }
        try environment.startDownloading(url)
        while environment.isOnlineOnly(url) {
            do {
                try checkpoint()
            } catch {
                environment.stopDownloading(url)
                throw error
            }
            if let error = environment.downloadError(url) { throw error }
            Thread.sleep(forTimeInterval: Self.downloadPollInterval)
        }
    }
}
