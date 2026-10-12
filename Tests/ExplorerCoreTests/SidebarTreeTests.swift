import Testing
@testable import ExplorerCore

@Suite struct SidebarTreeTests {
    @Test func rootsStartWithHomeAndEndWithNetworkAndRecycleBin() {
        let roots = SidebarTree.roots()
        #expect(roots.first?.title == "Home")
        #expect(roots.first?.location == .home)
        #expect(roots.suffix(2).map(\.location) == [.network, .recycleBin])
    }

    @Test func rootsContainTheSixWellKnownFolders() {
        let titles = SidebarTree.roots().map(\.title)
        for expected in ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Videos"] {
            #expect(titles.contains(expected))
        }
    }

    @Test func thisPCIsExpandableAndEverythingElseIsNot() {
        let roots = SidebarTree.roots()
        let thisPC = roots.first { $0.id == SidebarTree.thisPCID }
        #expect(thisPC?.isExpandable == true)
        #expect(roots.filter { $0.id != SidebarTree.thisPCID }.allSatisfy { !$0.isExpandable })
    }

    @Test func thisPCChildrenIncludeTheBootVolume() {
        let roots = SidebarTree.roots()
        let thisPC = roots.first { $0.id == SidebarTree.thisPCID }!
        let children = SidebarTree.children(of: thisPC)
        #expect(children.contains { $0.location.fileURL?.path == "/" })
    }

    @Test func leafItemsHaveNoChildren() {
        let home = SidebarTree.roots().first { $0.id == "home" }!
        #expect(SidebarTree.children(of: home).isEmpty)
    }

    @Test func networkHasNoChildrenYet() {
        let network = SidebarTree.roots().first { $0.id == "network" }!
        #expect(SidebarTree.children(of: network).isEmpty)
    }
}
