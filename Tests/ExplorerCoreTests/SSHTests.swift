import Foundation
import Testing
@testable import ExplorerCore

@Suite struct SSHConfigTests {
    @Test func splitsConfigLines() {
        #expect(SSHConfigParser.tokens("Host a b") == ["Host", "a", "b"])
        #expect(SSHConfigParser.tokens("  HostName=example.com") == ["HostName", "example.com"])
        #expect(SSHConfigParser.tokens("IdentityFile \"~/My Keys/id\"") == ["IdentityFile", "~/My Keys/id"])
        #expect(SSHConfigParser.tokens("# comment") == [])
        #expect(SSHConfigParser.tokens("User dave # trailing") == ["User", "dave"])
    }

    @Test func listsConcreteHostsWithIncludes() throws {
        let temp = try TemporaryDirectory()
        let included = try temp.createFile("extra.conf", contents: """
        Host included
            User inc
        """)
        let config = try temp.createFile("config", contents: """
        # Personal servers
        Host web web-alias
            HostName web.example.com
            User deploy
            Port 2222

        Host *.internal !bastion
            ProxyJump bastion

        Host *
            User fallback

        Match host something
            User ignored

        Include \(included.path)

        Host WEB
            HostName duplicate
        """)

        let hosts = SSHConfigParser.hosts(in: config)
        #expect(hosts.map(\.alias) == ["web", "web-alias", "included"])
        #expect(hosts[0] == SSHConfigHost(alias: "web", hostname: "web.example.com", user: "deploy", port: 2222))
        #expect(hosts[2].user == "inc")
        #expect(SSHConfigParser.hosts(in: temp.path("missing")).isEmpty)
    }
}

@Suite struct SSHCommandTests {
    private let host = RemoteHost(user: "dave", hostname: "server", port: 2222)!
    private let command = SSHCommand(socketDirectory: URL(fileURLWithPath: "/tmp/sockets"))

    @Test func hostComesLastAfterDoubleDash() {
        let signIn = command.signInArguments(for: host)
        #expect(signIn.suffix(6) == ["-p", "2222", "-l", "dave", "--", "server"])
        #expect(signIn.contains("ControlPath=\(command.controlPath(for: host))"))
        #expect(!signIn.contains { $0.contains("BatchMode") })

        let sftp = command.sftpArguments(for: host)
        #expect(sftp.suffix(3) == ["--", "server", "sftp"])
        #expect(sftp.contains("BatchMode=yes"))
        #expect(sftp.contains("-s"))

        let configured = SSHCommand(socketDirectory: URL(fileURLWithPath: "/tmp"), configFile: "/tmp/cfg")
        #expect(configured.checkArguments(for: host).prefix(2) == ["-F", "/tmp/cfg"])
    }

    @Test func controlPathsFitUnixSockets() {
        let directory = SSHCommand.defaultSocketDirectory()
        let path = SSHCommand(socketDirectory: directory).controlPath(for: host)
        #expect(path.utf8.count + SSHCommand.bindSuffix < SSHCommand.maximumSocketPath)
        let long = SSHCommand.defaultSocketDirectory(temporary: "/" + String(repeating: "x", count: 120))
        #expect(long.path.hasPrefix("/tmp/"))
        let otherHost = RemoteHost(user: nil, hostname: "server", port: nil)!
        #expect(command.controlPath(for: host) != command.controlPath(for: otherHost))
    }

    @Test func classifiesSSHErrors() {
        let cases: [(String, SSHError)] = [
            ("dave@server: Permission denied (publickey,password).", .authenticationFailed),
            ("Host key verification failed.", .hostKeyRejected),
            ("@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.",
             .hostKeyChanged),
            ("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known", .unknownHost),
            ("ssh: connect to host server port 22: Connection refused", .refused),
            ("ssh: connect to host 10.0.0.9 port 22: Operation timed out", .unreachable),
            ("subsystem request failed on channel 0", .sftpUnavailable),
            ("Warning: Permanently added 'x' to the list of known hosts.\nSomething odd", .other("Something odd")),
        ]
        for (output, expected) in cases {
            #expect(SSHError.classify(errorOutput: output, exitStatus: 255) == expected, "\(output)")
        }
        #expect(SSHError.classify(errorOutput: "", exitStatus: 255) == .other("ssh exited with status 255."))
    }
}

@Suite struct AskpassTests {
    @Test func classifiesOpenSSHPrompts() {
        let hostKey = """
        The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established.
        ED25519 key fingerprint is SHA256:eIIGLY26j8qIA85qPP7f0DaptPaMry+KvNmWmHJCaec.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        #expect(AskpassPrompt.classify(text: hostKey, hint: nil) == .hostKey(message: hostKey))
        #expect(AskpassPrompt.classify(text: "Enter passphrase for key '/Users/d/.ssh/id_ed25519': ", hint: nil)
            == .passphrase(keyPath: "/Users/d/.ssh/id_ed25519"))
        #expect(AskpassPrompt.classify(text: "dave@server's password: ", hint: nil)
            == .password(prompt: "dave@server's password:"))
        #expect(AskpassPrompt.classify(text: "(dave@server) Password:", hint: nil)
            == .password(prompt: "(dave@server) Password:"))
        #expect(AskpassPrompt.classify(text: "Allow use of key?", hint: "confirm")
            == .confirm(message: "Allow use of key?"))
        #expect(AskpassPrompt.classify(text: "Confirm user presence", hint: "none")
            == .notice(message: "Confirm user presence"))
        #expect(AskpassPrompt.classify(text: "Verification code:", hint: nil) == .secret(prompt: "Verification code:"))
    }

    @Test func answersOnlyRequestsWithTheToken() throws {
        // Socket paths must be short; the test temp directory may not be.
        let socket = "/tmp/panes-test-\(getpid())-\(UInt16.random(in: 0...UInt16.max)).sock"
        let seen = Recorder<AskpassRequest>()
        let server = try AskpassServer(socketPath: socket) { request, reply in
            seen.append(request)
            reply(AskpassReply(answer: request.prompt == "cancel" ? nil : "s3cret"))
        }
        defer { server.stop() }

        let good = AskpassRequest(token: server.token, connection: "dave@server:", prompt: "Password:", hint: nil)
        #expect(AskpassClient.ask(good, socketPath: socket) == "s3cret")
        let cancelled = AskpassRequest(token: server.token, connection: "c", prompt: "cancel", hint: nil)
        #expect(AskpassClient.ask(cancelled, socketPath: socket) == nil)
        let forged = AskpassRequest(token: "wrong", connection: "c", prompt: "Password:", hint: nil)
        #expect(AskpassClient.ask(forged, socketPath: socket) == nil)
        #expect(seen.items.count == 2)
        #expect(seen.items.first?.connection == "dave@server:")
    }
}
