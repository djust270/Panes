import Foundation
import Testing
@testable import ExplorerCore

@Suite struct NetworkPathTests {
    @Test func parsesUNCPathsAsSMB() throws {
        let path = try #require(NetworkPath(#"\\nas\Media\Movies\2024"#))
        #expect(path.shareURL.absoluteString == "smb://nas/Media")
        #expect(path.subpath == ["Movies", "2024"])

        let forward = try #require(NetworkPath("//nas/Media/"))
        #expect(forward.shareURL.absoluteString == "smb://nas/Media")
        #expect(forward.subpath.isEmpty)
    }

    @Test func encodesSpacesInUNCPaths() throws {
        let path = try #require(NetworkPath(#"\\nas\Team Files\Q3 Reports"#))
        #expect(path.shareURL.absoluteString == "smb://nas/Team%20Files")
        #expect(path.subpath == ["Q3 Reports"])
        #expect(path.folder(at: URL(fileURLWithPath: "/Volumes/Team Files")).path == "/Volumes/Team Files/Q3 Reports")
    }

    @Test func parsesURLs() throws {
        let smb = try #require(NetworkPath("smb://dave@fileserver.local/share/docs"))
        #expect(smb.shareURL.absoluteString == "smb://dave@fileserver.local/share")
        #expect(smb.subpath == ["docs"])

        let cifs = try #require(NetworkPath("cifs://server/share"))
        #expect(cifs.shareURL.scheme == "smb")

        let nfs = try #require(NetworkPath("nfs://server/export/home"))
        #expect(nfs.shareURL.absoluteString == "nfs://server/export/home")
        #expect(nfs.subpath.isEmpty)

        let serverOnly = try #require(NetworkPath("smb://server"))
        #expect(serverOnly.shareURL.absoluteString == "smb://server")
    }

    @Test func rejectsLocalPathsAndOtherSchemes() {
        #expect(NetworkPath("/Users/me") == nil)
        #expect(NetworkPath("~/Documents") == nil)
        #expect(NetworkPath("https://example.com/share") == nil)
        #expect(NetworkPath(#"\\"#) == nil)
        #expect(NetworkPath("smb://") == nil)
    }

    @Test func matchesSharesCaseInsensitively() throws {
        let typed = try #require(URL(string: "smb://NAS/media"))
        let mounted = try #require(URL(string: "smb://dave@nas/Media"))
        #expect(NetworkPath.sameShare(typed, mounted))
        #expect(!NetworkPath.sameShare(typed, try #require(URL(string: "smb://nas/Other"))))
        #expect(!NetworkPath.sameShare(typed, try #require(URL(string: "afp://nas/media"))))
    }
}
