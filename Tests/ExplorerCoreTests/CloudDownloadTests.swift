import Foundation
import Testing
@testable import ExplorerCore

/// Copies, "Download now" and deleting with online-only files, against a fake sync client.
@Suite struct CloudDownloadTests {
    @Test func copyingAnOnlineOnlyFileDownloadsItFirst() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "OneDrive/report.txt", contents: "report")
        try temp.createDirectory("dst")
        let cloud = FakeSyncClient(onlineOnly: [file], downloadTime: 0.3)

        let progress = Recorder<FileOperationProgress>()
        let result = await run(
            cloud.task(.copy([file], into: temp.path("dst")), in: temp),
            handlers: FileOperationHandlers(progress: { progress.append($0) })
        )

        #expect(result.failures.isEmpty)
        #expect(try temp.contents("dst/report.txt") == "report")
        #expect(cloud.requested == [file])
        #expect(progress.items.contains { $0.downloadingFrom != nil })
        #expect(progress.items.last?.downloadingFrom == nil)
    }

    @Test func filesWithLocalContentsAreCopiedWithoutAsking() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "OneDrive/local.txt", contents: "here")
        try temp.createDirectory("dst")
        let cloud = FakeSyncClient(onlineOnly: [])

        _ = await run(cloud.task(.copy([file], into: temp.path("dst")), in: temp))

        #expect(cloud.requested.isEmpty)
        #expect(temp.exists("dst/local.txt"))
    }

    @Test func cancellingDuringADownloadStopsIt() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "OneDrive/movie.mp4", contents: "frames")
        try temp.createDirectory("dst")
        let cloud = FakeSyncClient(onlineOnly: [file], downloadTime: nil)

        let task = cloud.task(.copy([file], into: temp.path("dst")), in: temp)
        let running = Task { await run(task) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await running.value

        #expect(result.wasCancelled)
        #expect(cloud.stopped == [file])
        #expect(!temp.exists("dst/movie.mp4"))
    }

    @Test func aFailedDownloadCanBeSkipped() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "OneDrive/broken.txt")
        try temp.createDirectory("dst")
        let cloud = FakeSyncClient(onlineOnly: [file], downloadTime: nil)
        cloud.error = CocoaError(.ubiquitousFileUnavailable)

        let failures = Recorder<FileOperationFailure>()
        let result = await run(
            cloud.task(.copy([file], into: temp.path("dst")), in: temp),
            handlers: FileOperationHandlers(failure: { failure, reply in
                failures.append(failure)
                reply(.skip)
            })
        )

        #expect(failures.items.map(\.url) == [file])
        #expect(result.failures.count == 1)
        #expect(!temp.exists("dst/broken.txt"))
    }

    @Test func downloadAsksForEveryOnlineOnlyFileFirst() async throws {
        let temp = try TemporaryDirectory()
        let a = try temp.createFile(at: "OneDrive/a.txt", contents: "aa")
        let b = try temp.createFile(at: "OneDrive/Folder/b.txt", contents: "bbb")
        let c = try temp.createFile(at: "OneDrive/Folder/Sub/c.txt", contents: "c")
        try temp.createFile(at: "OneDrive/Folder/local.txt")
        let cloud = FakeSyncClient(onlineOnly: [a, b, c], downloadTime: 0.2)

        let progress = Recorder<FileOperationProgress>()
        let result = await run(
            cloud.task(.download([a, temp.path("OneDrive/Folder")]), in: temp),
            handlers: FileOperationHandlers(progress: { progress.append($0) })
        )

        #expect(!result.wasCancelled)
        #expect(result.failures.isEmpty)
        #expect(result.inverse == nil)
        #expect(Set(cloud.requested) == [a, b, c])
        #expect(cloud.onlineOnlyFiles.isEmpty)
        let last = try #require(progress.items.last)
        #expect(last.totalItems == 3)
        #expect(last.totalBytes == 6)
        #expect(last.completedItems == 3)
    }

    @Test func cancellingADownloadStopsTheFilesStillComing() async throws {
        let temp = try TemporaryDirectory()
        let a = try temp.createFile(at: "OneDrive/a.txt")
        let b = try temp.createFile(at: "OneDrive/b.txt")
        let cloud = FakeSyncClient(onlineOnly: [a, b], downloadTime: nil)

        let task = cloud.task(.download([a, b]), in: temp)
        let running = Task { await run(task) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await running.value

        #expect(result.wasCancelled)
        #expect(Set(cloud.stopped) == [a, b])
    }

    @Test func onlineOnlyItemsAreDeletedRatherThanTrashed() async throws {
        let temp = try TemporaryDirectory()
        let local = try temp.createFile(at: "OneDrive/local.txt")
        let online = try temp.createFile(at: "OneDrive/online.txt")
        try temp.createFile(at: "OneDrive/Mixed/inner.txt")
        let inner = temp.path("OneDrive/Mixed/inner.txt")
        let cloud = FakeSyncClient(onlineOnly: [online, inner])

        let result = await run(cloud.task(.trash([local, online, temp.path("OneDrive/Mixed")]), in: temp))

        #expect(result.failures.isEmpty)
        #expect(!temp.exists("OneDrive/local.txt"))
        #expect(!temp.exists("OneDrive/online.txt"))
        #expect(!temp.exists("OneDrive/Mixed"))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: temp.path(".trash").path)
        #expect(trashed.count == 1 && trashed[0].hasSuffix("local.txt"))
        guard case .relocate(let undo) = result.inverse else {
            Issue.record("no undo")
            return
        }
        #expect(undo.map(\.destination) == [local.standardizedFileURL])
    }

    @Test func onlyCloudItemsAreLookedIntoForOnlineOnlyContents() throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "Folder/a.txt")
        #expect(!CloudSync.hasOnlineOnlyContents(temp.path("Folder")))
        #expect(!CloudSync.hasOnlineOnlyContents(temp.path("missing")))
    }
}

/// A sync client whose online-only files arrive `downloadTime` seconds after they're asked
/// for, or never if `nil`.
final class FakeSyncClient: @unchecked Sendable {
    private let lock = NSLock()
    private var online: Set<URL>
    private var asked: [URL] = []
    private var stops: [URL] = []
    private let downloadTime: TimeInterval?
    private var failure: Error?

    init(onlineOnly: [URL], downloadTime: TimeInterval? = 0.1) {
        online = Set(onlineOnly.map(\.standardizedFileURL))
        self.downloadTime = downloadTime
    }

    var requested: [URL] { lock.withLock { asked } }
    var stopped: [URL] { lock.withLock { stops } }
    var onlineOnlyFiles: Set<URL> { lock.withLock { online } }
    var error: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    func task(_ request: FileOperationRequest, in temp: TemporaryDirectory) -> FileOperationTask {
        var environment = fakeTrash(temp)
        environment.isOnlineOnly = { [self] url in lock.withLock { online.contains(url.standardizedFileURL) } }
        environment.startDownloading = { [self] url in
            let url = url.standardizedFileURL
            let isNew = lock.withLock {
                guard online.contains(url), !asked.contains(url) else { return false }
                asked.append(url)
                return true
            }
            guard isNew, let downloadTime else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + downloadTime) { [self] in
                _ = lock.withLock { online.remove(url) }
            }
        }
        environment.downloadError = { [self] _ in error }
        environment.stopDownloading = { [self] url in lock.withLock { stops.append(url.standardizedFileURL) } }
        environment.hasOnlineOnlyContents = { [self] url in
            let path = url.standardizedFileURL.path
            return lock.withLock { online.contains { $0.path == path || $0.path.hasPrefix(path + "/") } }
        }
        return FileOperationTask(request: request, environment: environment)
    }
}
