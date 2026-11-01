import Foundation
import Testing
@testable import ExplorerCore

/// Against a real SSH server, through `/usr/bin/ssh`: signing in, reusing the master
/// connection, listing, a transfer round trip, disconnecting and reconnecting.
///
///     EXPLORER_SSH_TESTS=1 [EXPLORER_SSH_HOST=host] [EXPLORER_SSH_CONFIG=file] scripts/test.sh
///
/// Needs key (or agent) sign-in to the host, `localhost` by default (Remote Login on).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXPLORER_SSH_TESTS"] == "1"))
struct SSHIntegrationTests {
    let environment = ProcessInfo.processInfo.environment
    var host: RemoteHost {
        RemoteHost(user: nil, hostname: environment["EXPLORER_SSH_HOST"] ?? "localhost", port: nil)!
    }

    func makePool() -> SSHConnectionPool {
        let sockets = URL(fileURLWithPath: "/tmp/panes-test-\(getpid())-\(UInt16.random(in: 0...UInt16.max))")
        let command = SSHCommand(socketDirectory: sockets, configFile: environment["EXPLORER_SSH_CONFIG"])
        return SSHConnectionPool(configuration: .init(command: command))
    }

    @Test func connectsListsTransfersAndReconnects() async throws {
        let pool = makePool()
        let host = self.host
        try await pool.connect(host)

        let start = Date()
        try await pool.connect(host)
        #expect(Date().timeIntervalSince(start) < 1, "reusing the master should be quick")

        let home = try await pool.browse(host) { try $0.realpath(".") }
        #expect(home.hasPrefix("/"))
        let folder = RemotePath(host: host, path: home)
        _ = try await pool.browse(host) { try RemoteListing.items(in: folder, includeHidden: true, using: $0) }

        // Upload a file to the remote home folder, download it back, then remove it.
        let temp = try TemporaryDirectory()
        let name = "panes-ssh-test-\(UUID().uuidString).txt"
        try temp.createFile(name, contents: "round trip")
        try temp.createDirectory("back")
        var environment = fakeTrash(temp)
        environment.openSFTP = { try pool.openTransferClient($0) }
        let up = await run(FileOperationTask(request: .remoteUpload([temp.path(name)], into: folder),
                                             environment: environment))
        #expect(up.failures.isEmpty)
        let downloadRequest = FileOperationRequest.remoteDownload([folder.appending(name)], into: temp.path("back"))
        let down = await run(FileOperationTask(request: downloadRequest, environment: environment))
        #expect(down.failures.isEmpty)
        #expect(try temp.contents("back/\(name)") == "round trip")
        try await pool.browse(host) { try $0.remove(folder.appending(name).path) }

        // After disconnecting, browsing signs in again by itself.
        await pool.disconnect(host)
        #expect(await !pool.isConnected(host))
        let again = try await pool.browse(host) { try $0.realpath(".") }
        #expect(again == home)
        await pool.shutdown()
    }

    @Test func reportsUnknownHosts() async {
        let pool = makePool()
        let nowhere = RemoteHost(user: nil, hostname: "no-such-host.invalid", port: nil)!
        await #expect(throws: SSHError.unknownHost) { try await pool.connect(nowhere) }
    }
}
