import Foundation
import Testing
@testable import ExplorerCore

@Suite struct RemotePathTests {
    private func host(_ user: String?, _ name: String, _ port: Int? = nil) throws -> RemoteHost {
        try #require(RemoteHost(user: user, hostname: name, port: port))
    }

    // MARK: Parsing

    @Test func parsesSCPStyleAddresses() throws {
        #expect(RemotePath.parse("dave@server:/var/www") ==
            RemotePath(host: try host("dave", "server"), path: "/var/www"))
        #expect(RemotePath.parse("server:/") == RemotePath(host: try host(nil, "server"), path: "/"))
        #expect(RemotePath.parse("server.example.com:") ==
            RemotePath(host: try host(nil, "server.example.com"), path: ""))
        #expect(RemotePath.parse("pi@10.0.0.5:projects/site") ==
            RemotePath(host: try host("pi", "10.0.0.5"), path: "projects/site"))
        #expect(RemotePath.parse("box:~/notes") == RemotePath(host: try host(nil, "box"), path: "notes"))
        #expect(RemotePath.parse("box:~") == RemotePath(host: try host(nil, "box"), path: ""))
        #expect(RemotePath.parse("dave@[fe80::1]:/tmp") == RemotePath(host: try host("dave", "fe80::1"), path: "/tmp"))
    }

    @Test func parsesURLs() throws {
        #expect(RemotePath.parse("sftp://dave@server:2222/home/dave") ==
            RemotePath(host: try host("dave", "server", 2222), path: "/home/dave"))
        #expect(RemotePath.parse("ssh://server") == RemotePath(host: try host(nil, "server"), path: ""))
        #expect(RemotePath.parse("SCP://server/~/docs") == RemotePath(host: try host(nil, "server"), path: "docs"))
        let myFiles = RemotePath(host: try host(nil, "server"), path: "/My Files")
        #expect(RemotePath.parse("sftp://server/My%20Files") == myFiles)
        #expect(RemotePath.parse("sftp://server/My Files") == myFiles)
        #expect(RemotePath.parse("sftp://[::1]:22/") == RemotePath(host: try host(nil, "::1", 22), path: "/"))
        #expect(RemotePath.parse("ssh://dave;fingerprint=SHA256-abc@server/") ==
            RemotePath(host: try host("dave", "server"), path: "/"))
    }

    @Test func rejectsWhatIsntARemoteAddress() {
        for input in ["C:", #"C:\Users"#, "/Users/dave", "~/Documents", "./a:b", #"\\server\share"#,
                      "smb://server/share", "http://example.com", "plain", "a:b", "-oProxyCommand=evil:x",
                      "dave@-oProxyCommand=x:/", "sftp://-oProxyCommand=x/", "sftp://server:99999/",
                      "sftp://ser ver/", "sftp://server:abc/"] {
            #expect(RemotePath.parse(input) == nil, "\(input)")
        }
    }

    @Test func normalisesPaths() throws {
        let server = try host(nil, "server")
        #expect(RemotePath(host: server, path: "/a//b/./c/../d/").path == "/a/b/d")
        #expect(RemotePath(host: server, path: "/../..").path == "/")
        #expect(RemotePath(host: server, path: "docs/./x/").path == "docs/x")
    }

    // MARK: URLs

    @Test func urlRoundTripsAwkwardNames() throws {
        let folder = RemotePath(host: try host("dåve", "server", 2200), path: "/home")
        for name in ["a b", "100% #1?", "line\nbreak", "😀.txt", "semi;colon=x"] {
            let item = folder.appending(name)
            #expect(item.url.scheme == "sftp")
            #expect(RemotePath(url: item.url) == item, "\(name)")
            #expect(item.url.standardizedFileURL == item.url)
        }
        let home = RemotePath(host: try host(nil, "server"), path: "docs")
        #expect(home.url.absoluteString == "sftp://server/~/docs")
        #expect(RemotePath(url: home.url) == home)
        #expect(RemotePath(url: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func addressStringParsesBack() throws {
        for path in [RemotePath(host: try host("dave", "server"), path: "/srv/My Files"),
                     RemotePath(host: try host(nil, "server", 2222), path: "/srv/My Files"),
                     RemotePath(host: try host(nil, "server"), path: "")] {
            #expect(RemotePath.parse(path.addressString) == path, "\(path.addressString)")
        }
        #expect(RemotePath(host: try host("dave", "server"), path: "/srv").addressString == "dave@server:/srv")
    }

    // MARK: Hierarchy

    @Test func parentsAndNames() throws {
        let server = try host("dave", "server")
        let docs = RemotePath(host: server, path: "/home/dave/docs")
        #expect(docs.name == "docs")
        #expect(docs.parent?.path == "/home/dave")
        #expect(RemotePath(host: server, path: "/home").parent?.path == "/")
        #expect(RemotePath(host: server, path: "/").parent == nil)
        #expect(RemotePath(host: server, path: "/").name == "dave@server")
        #expect(RemotePath(host: server, path: "docs").parent == nil)
        #expect(RemotePath(host: server, path: "/").appending("etc").path == "/etc")
    }

    @Test func remoteLocationsGoUpToNetwork() throws {
        let server = try host("dave", "server")
        let location = ExplorerLocation.remote(RemotePath(host: server, path: "/home/dave"))
        #expect(location.ancestry == [
            .network,
            .remote(RemotePath(host: server, path: "/")),
            .remote(RemotePath(host: server, path: "/home")),
            location,
        ])
        #expect(location.displayName == "dave")
        #expect(location.fileURL == nil)
        #expect(location.editableAddress == "dave@server:/home/dave")
        #expect(ExplorerLocation.remote(RemotePath(host: server, path: "")).parent == nil)
        #expect(location.viewSettingsKey == "folder:sftp://dave@server/home/dave")
    }

    @Test func hostKeysIgnoreHostCase() throws {
        #expect(try host("dave", "Server").key == host("dave", "server").key)
        #expect(try host("dave", "server").key != host("other", "server").key)
        #expect(try host(nil, "server", 22).key != host(nil, "server").key)
    }

    @Test func savedConnectionsAreOnePerHost() throws {
        let temp = TemporaryDefaults()
        let store = RemoteConnectionStore(defaults: temp.defaults)
        store.save(SavedRemoteConnection(host: try host("dave", "a")))
        store.save(SavedRemoteConnection(host: try host("dave", "b"), startPath: "/srv"))
        store.save(SavedRemoteConnection(host: try host("dave", "A"), startPath: "/x"))
        let reloaded = RemoteConnectionStore(defaults: temp.defaults)
        #expect(reloaded.connections.map(\.startPath) == ["/x", "/srv"])
        reloaded.remove(try host("dave", "b"))
        #expect(RemoteConnectionStore(defaults: temp.defaults).connections.count == 1)
    }
}
