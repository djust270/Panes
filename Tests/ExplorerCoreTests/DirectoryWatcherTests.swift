import Foundation
import Testing
@testable import ExplorerCore

@Suite struct DirectoryWatcherTests {
    @Test func reportsNewFile() async throws {
        let temp = try TemporaryDirectory()
        let watcher = DirectoryWatcher(directory: temp.url, latency: 0.05)
        let changes = watcher.start()
        defer { watcher.stop() }

        // FSEvents needs a moment to arm before it reports events "since now".
        try await Task.sleep(for: .milliseconds(300))
        try temp.createFile("new.txt")

        let change = try await firstChange(in: changes, timeout: .seconds(5))
        #expect(change.mustRescan || change.paths.contains { $0.hasSuffix("/new.txt") })
    }

    @Test func ignoresGrandchildrenWhenNotWatchingSubtree() async throws {
        let temp = try TemporaryDirectory()
        let sub = try temp.createDirectory("sub")
        try await Task.sleep(for: .milliseconds(300))

        let watcher = DirectoryWatcher(directory: temp.url, latency: 0.05)
        let changes = watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try Data().write(to: sub.appendingPathComponent("deep.txt"))
        try await Task.sleep(for: .milliseconds(300))
        try temp.createFile("marker.txt")

        // The first change delivered must be the marker, not the grandchild.
        let change = try await firstChange(in: changes, timeout: .seconds(5))
        #expect(!change.paths.contains { $0.hasSuffix("/deep.txt") })
        #expect(change.paths.contains { $0.hasSuffix("/marker.txt") })
    }

    @Test func stopFinishesStream() async throws {
        let temp = try TemporaryDirectory()
        let watcher = DirectoryWatcher(directory: temp.url)
        let changes = watcher.start()
        watcher.stop()

        var received = 0
        for await _ in changes { received += 1 }
        #expect(received == 0)
    }

    private func firstChange(
        in changes: AsyncStream<DirectoryWatcher.Change>,
        timeout: Duration
    ) async throws -> DirectoryWatcher.Change {
        try await withThrowingTaskGroup(of: DirectoryWatcher.Change?.self) { group in
            group.addTask {
                for await change in changes { return change }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            guard let result else {
                Issue.record("No change within \(timeout)")
                throw CancellationError()
            }
            return result
        }
    }
}
