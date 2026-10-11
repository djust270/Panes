import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ExplorerLocationTests {
    @Test func folderPathsAreNormalised() {
        #expect(ExplorerLocation.folder(path: "/Users/../Users/") == ExplorerLocation.folder(path: "/Users"))
    }

    @Test func parentOfFolder() {
        #expect(ExplorerLocation.folder(path: "/Users/someone").parent == .folder(path: "/Users"))
    }

    @Test func volumeRootGoesUpToThisPC() {
        #expect(ExplorerLocation.folder(path: "/").parent == .thisPC)
        #expect(ExplorerLocation.thisPC.parent == nil)
    }

    @Test func searchGoesUpToItsScope() {
        let scope = URL(fileURLWithPath: "/Users", isDirectory: true)
        #expect(ExplorerLocation.search(query: "report", scope: scope).parent == .folder(scope))
    }

    @Test func virtualLocationsHaveNoParent() {
        for location in [ExplorerLocation.home, .network, .recycleBin] {
            #expect(location.parent == nil)
            #expect(location.fileURL == nil)
        }
    }

    @Test func ancestryRunsFromThisPCDown() {
        let ancestry = ExplorerLocation.folder(path: "/Users/someone").ancestry
        #expect(ancestry == [.thisPC, .folder(path: "/"), .folder(path: "/Users"), .folder(path: "/Users/someone")])
    }

    @Test func displayNames() {
        #expect(ExplorerLocation.thisPC.displayName == "This PC")
        #expect(ExplorerLocation.recycleBin.displayName == "Recycle Bin")
        #expect(!ExplorerLocation.folder(path: "/").displayName.isEmpty)
    }
}
