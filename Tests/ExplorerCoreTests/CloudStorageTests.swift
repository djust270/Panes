import Foundation
import Testing
@testable import ExplorerCore

@Suite struct CloudStorageTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    private func cloudRoot(_ name: String) -> URL {
        CloudStorage.fileProviderFolder.appendingPathComponent(name, isDirectory: true)
    }

    @Test func namesFollowWindows() {
        func describe(_ name: String) -> (CloudRoot.Provider, String) {
            let root = CloudStorage.root(named: name, at: URL(fileURLWithPath: "/x/" + name))
            return (root.provider, root.title)
        }
        #expect(describe("OneDrive-Personal") == (.oneDrive, "OneDrive - Personal"))
        #expect(describe("OneDrive-Contoso Ltd") == (.oneDrive, "OneDrive - Contoso Ltd"))
        #expect(describe("OneDrive-SharedLibraries-Contoso Ltd") == (.sharePoint, "Contoso Ltd"))
        #expect(describe("GoogleDrive-me@example.com") == (.googleDrive, "Google Drive (me@example.com)"))
        #expect(describe("Dropbox") == (.dropbox, "Dropbox"))
        #expect(describe("Dropbox-Work") == (.dropbox, "Dropbox (Work)"))
        #expect(describe("Box-Box") == (.box, "Box"))
        #expect(describe("pCloud-Drive").0 == .other)
    }

    @Test func listsFoldersWithICloudDriveFirst() throws {
        let temp = try TemporaryDirectory()
        let storage = try temp.createDirectory("CloudStorage")
        let iCloud = try temp.createDirectory("CloudDocs")
        for name in ["OneDrive-Personal", "Dropbox", "GoogleDrive-me@example.com", ".hidden"] {
            try FileManager.default.createDirectory(
                at: storage.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try temp.createFile(at: "CloudStorage/stray.txt")

        let roots = CloudStorage.roots(fileProviderFolder: storage, iCloudDriveFolder: iCloud)
        #expect(roots.map(\.title) == ["iCloud Drive", "Dropbox", "Google Drive (me@example.com)",
                                       "OneDrive - Personal"])
        #expect(roots.first?.url == iCloud.standardizedFileURL)

        let withoutICloud = CloudStorage.roots(fileProviderFolder: storage,
                                               iCloudDriveFolder: temp.path("missing"))
        #expect(withoutICloud.count == 3)
        #expect(CloudStorage.roots(fileProviderFolder: temp.path("missing"),
                                   iCloudDriveFolder: temp.path("missing")).isEmpty)
    }

    @Test func findsTheRootAnItemIsIn() {
        let documents = cloudRoot("OneDrive-Contoso").appendingPathComponent("Documents/report.docx")
        #expect(CloudStorage.root(containing: documents)?.title == "OneDrive - Contoso")
        #expect(CloudStorage.root(containing: documents)?.url == cloudRoot("OneDrive-Contoso").standardizedFileURL)
        #expect(CloudStorage.root(containing: cloudRoot("Dropbox"))?.title == "Dropbox")
        let iCloudFile = CloudStorage.iCloudDriveFolder.appendingPathComponent("Notes/a.txt")
        #expect(CloudStorage.root(containing: iCloudFile)?.provider == .iCloudDrive)
        #expect(CloudStorage.root(containing: CloudStorage.iCloudDriveFolder)?.provider == .iCloudDrive)
        #expect(CloudStorage.root(containing: CloudStorage.fileProviderFolder) == nil)
        #expect(CloudStorage.root(containing: cloudRoot(".hidden").appendingPathComponent("a")) == nil)
        #expect(CloudStorage.root(containing: home.appendingPathComponent("Documents")) == nil)
    }

    @Test func recognisesRootsByPath() {
        #expect(CloudStorage.root(at: cloudRoot("OneDrive-Personal"))?.title == "OneDrive - Personal")
        #expect(CloudStorage.root(at: CloudStorage.iCloudDriveFolder)?.provider == .iCloudDrive)
        #expect(CloudStorage.root(at: cloudRoot("OneDrive-Personal/Documents")) == nil)
        #expect(CloudStorage.root(at: cloudRoot(".hidden")) == nil)
        #expect(CloudStorage.root(at: CloudStorage.fileProviderFolder) == nil)
        #expect(CloudStorage.root(at: home) == nil)
    }

    @Test func containsOnlyPathsInsideCloudFolders() {
        let home = "/Users/me"
        #expect(CloudStorage.contains("/Users/me/Library/CloudStorage/OneDrive-Personal/a.docx", home: home))
        #expect(CloudStorage.contains("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.txt", home: home))
        #expect(!CloudStorage.contains("/Users/me/Library/Mobile Documents/other/a.txt", home: home))
        #expect(!CloudStorage.contains("/Users/me/Library/CloudStorage", home: home))
        #expect(!CloudStorage.contains("/Users/me/Documents/a.txt", home: home))
    }

    @Test func cloudRootIsTheTopOfItsBreadcrumb() {
        let root = ExplorerLocation.folder(cloudRoot("OneDrive-Personal").standardizedFileURL)
        let documents = ExplorerLocation.folder(cloudRoot("OneDrive-Personal/Documents").standardizedFileURL)
        #expect(root.displayName == "OneDrive - Personal")
        #expect(root.parent == .home)
        #expect(documents.ancestry == [.home, root, documents])
    }

    @Test func cloudFoldersComeBetweenHomeAndThePins() {
        let cloud = CloudRoot(url: cloudRoot("OneDrive-Personal"), provider: .oneDrive, title: "OneDrive - Personal")
        let pin = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let roots = SidebarTree.roots(pinnedFolders: [pin], cloudRoots: [cloud])
        #expect(roots.map(\.title).prefix(2) == ["Home", "OneDrive - Personal"])
        #expect(roots[1].location == .folder(cloud.url))
        #expect(!roots[1].isPinnedFolder && !roots[1].isExpandable)
        #expect(roots[2].isPinnedFolder)
        #expect(SidebarTree.appearance(of: cloud.url).title == "OneDrive - Personal")
    }

    @Test func pinMovesSkipTheCloudFolders() {
        // Home, two cloud folders, then three pins at roots 3...5.
        #expect(SidebarTree.pinMove(fromRoot: 5, toRoot: 3, firstPin: 3, pinCount: 3)! == (2, 0))
        #expect(SidebarTree.pinMove(fromRoot: 3, toRoot: 6, firstPin: 3, pinCount: 3)! == (0, 2))
        // Dropped among the cloud folders: the first gap.
        #expect(SidebarTree.pinMove(fromRoot: 4, toRoot: 1, firstPin: 3, pinCount: 3)! == (1, 0))
        // A cloud folder isn't a pin.
        #expect(SidebarTree.pinMove(fromRoot: 2, toRoot: 4, firstPin: 3, pinCount: 3) == nil)
    }

    @Test func searchAndRecentIncludeCloudFolders() {
        let homePath = home.path
        let file = homePath + "/Library/CloudStorage/OneDrive-Personal/Report.docx"
        #expect(FileSearch.isSearchable(file, in: homePath, includeHidden: false))
        #expect(!FileSearch.isSearchable(homePath + "/Library/Caches/a.txt", in: homePath, includeHidden: false))
        #expect(SpotlightRecents.isUserFile("/Users/me/Library/CloudStorage/Dropbox/a.pdf", home: "/Users/me"))
        #expect(SpotlightRecents.isUserFile(
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", home: "/Users/me"))
    }
}
