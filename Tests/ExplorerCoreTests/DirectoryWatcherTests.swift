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

        // Earlier events (e.g. the temp directory's own creation) may arrive first.
        let received = try await collectChanges(in: changes, timeout: .seconds(5)) { change in
            change.mustRescan || change.paths.contains { $0.hasSuffix("/new.txt") }
        }
        #expect(!received.isEmpty)
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

        // Nothing delivered before (or with) the marker may mention the grandchild.
        let received = try await collectChanges(in: changes, timeout: .seconds(5)) { change in
            change.paths.contains { $0.hasSuffix("/marker.txt") }
        }
        #expect(!received.flatMap(\.paths).contains { $0.hasSuffix("/deep.txt") })
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

    /// Collects changes up to and including the first one matching `isTarget`.
    /// Records an issue and throws if no match arrives within `timeout`.
    private func collectChanges(
        in changes: AsyncStream<DirectoryWatcher.Change>,
        timeout: Duration,
        until isTarget: @escaping @Sendable (DirectoryWatcher.Change) -> Bool
    ) async throws -> [DirectoryWatcher.Change] {
        try await withThrowingTaskGroup(of: [DirectoryWatcher.Change]?.self) { group in
            group.addTask {
                var received: [DirectoryWatcher.Change] = []
                for await change in changes {
                    received.append(change)
                    if isTarget(change) { return received }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            guard let result else {
                Issue.record("No matching change within \(timeout)")
                throw CancellationError()
            }
            return result
        }
    }
}
