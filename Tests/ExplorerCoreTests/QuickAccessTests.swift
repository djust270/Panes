import Foundation
import Testing
@testable import ExplorerCore

@Suite struct QuickAccessTests {
    private let domain = TemporaryDefaults()
    private let desktop = URL(fileURLWithPath: "/Users/me/Desktop")
    private let documents = URL(fileURLWithPath: "/Users/me/Documents")
    private let projects = URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func makeStore() -> QuickAccessStore {
        QuickAccessStore(defaults: domain.defaults, defaultPins: [desktop, documents])
    }

    @Test func startsWithTheDefaultPins() {
        #expect(makeStore().pinnedFolders.map(\.path) == [desktop.path, documents.path])
    }

    @Test func defaultPinsAreTheWellKnownFolders() {
        let store = QuickAccessStore(defaults: domain.defaults)
        #expect(store.pinnedFolders.map(\.lastPathComponent).contains("Downloads"))
        #expect(store.pinnedFolders.count == 6)
    }

    @Test func pinsUnpinsAndRemembers() {
        let store = makeStore()
        store.pin(projects)
        store.pin(URL(fileURLWithPath: "/Users/me/Projects/"))
        store.unpin(desktop)
        #expect(store.pinnedFolders.map(\.path) == [documents.path, projects.path])
        // A trailing slash doesn't make a different folder.
        #expect(store.isPinned(URL(fileURLWithPath: "/Users/me/Projects")))
        #expect(makeStore().pinnedFolders.map(\.path) == [documents.path, projects.path])
    }

    @Test func movesPins() {
        let store = makeStore()
        store.pin(projects)
        store.movePin(from: 2, to: 0)
        #expect(store.pinnedFolders.map(\.lastPathComponent) == ["Projects", "Desktop", "Documents"])
    }

    @Test func frequentFoldersNeedTwoVisitsAndSkipPins() {
        let store = makeStore()
        let music = URL(fileURLWithPath: "/Users/me/Music")
        store.recordVisit(to: projects, at: now)
        #expect(store.frequentFolders(now: now).isEmpty)
        store.recordVisit(to: projects, at: now)
        store.recordVisit(to: documents, at: now)
        store.recordVisit(to: documents, at: now)
        for _ in 0..<3 { store.recordVisit(to: music, at: now) }
        #expect(store.frequentFolders(now: now).map(\.lastPathComponent) == ["Music", "Projects"])
    }

    @Test func oldVisitsCountForLess() {
        let store = makeStore()
        let old = URL(fileURLWithPath: "/old")
        for _ in 0..<5 { store.recordVisit(to: old, at: now.addingTimeInterval(-200 * 86400)) }
        store.recordVisit(to: projects, at: now)
        store.recordVisit(to: projects, at: now)
        #expect(store.frequentFolders(now: now).map(\.lastPathComponent) == ["Projects", "old"])
    }

    @Test func removedFrequentFoldersStayHidden() {
        let store = makeStore()
        store.recordVisit(to: projects, at: now)
        store.recordVisit(to: projects, at: now)
        store.removeFromFrequent(projects)
        store.recordVisit(to: projects, at: now)
        #expect(store.frequentFolders(now: now).isEmpty)
    }

    @Test func favoritesAddAndRemove() {
        let store = makeStore()
        let file = URL(fileURLWithPath: "/Users/me/a.txt")
        store.addFavorite(file)
        store.addFavorite(file)
        #expect(store.favorites == [file])
        #expect(store.isFavorite(file))
        store.removeFavorite(file)
        #expect(store.favorites.isEmpty)
    }

    @Test func recentMergesNewestUseAndSkipsFavoritesAndRemoved() {
        let store = makeStore()
        let a = URL(fileURLWithPath: "/f/a.txt")
        let b = URL(fileURLWithPath: "/f/b.txt")
        let c = URL(fileURLWithPath: "/f/c.txt")
        let d = URL(fileURLWithPath: "/f/d.txt")
        store.recordOpen(of: a, at: now)
        store.addFavorite(c)
        let found = [
            RecentFile(url: a, lastUsed: now.addingTimeInterval(-100)),
            RecentFile(url: b, lastUsed: now.addingTimeInterval(-50)),
            RecentFile(url: c, lastUsed: now),
            RecentFile(url: d, lastUsed: now.addingTimeInterval(-10)),
        ]
        store.removeFromRecent(d, at: now)
        let recent = store.recentFiles(merging: found)
        #expect(recent.map(\.url.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(recent.first?.lastUsed == now)
    }

    @Test func removedRecentFilesComeBackWhenUsedAgain() {
        let store = makeStore()
        let a = URL(fileURLWithPath: "/f/a.txt")
        store.removeFromRecent(a, at: now)
        #expect(store.recentFiles(merging: [RecentFile(url: a, lastUsed: now)]).isEmpty)
        let later = RecentFile(url: a, lastUsed: now.addingTimeInterval(60))
        #expect(store.recentFiles(merging: [later]).count == 1)
        store.recordOpen(of: a, at: now.addingTimeInterval(-60))
        #expect(store.recentFiles(merging: []).count == 1)
    }

    @Test func recentIsLimited() {
        let store = makeStore()
        let found = (0..<30).map { RecentFile(url: URL(fileURLWithPath: "/f/\($0)"), lastUsed: now) }
        #expect(store.recentFiles(merging: found, limit: 20).count == 20)
    }

    @Test func sidebarShowsPinsBetweenHomeAndThisPC() {
        let roots = SidebarTree.roots(pinnedFolders: [projects, desktop])
        #expect(roots.map(\.title).prefix(3) == ["Home", "Projects", "Desktop"])
        #expect(roots[1].isPinnedFolder)
        #expect(roots[3].id == SidebarTree.thisPCID)
        #expect(roots[1].location == .folder(projects.standardizedFileURL))
    }

    @Test func pinDropsBecomeMoves() {
        // Pins are roots 1...3; the target is the gap before that root.
        #expect(SidebarTree.pinMove(fromRoot: 3, toRoot: 1, pinCount: 3)! == (2, 0))
        #expect(SidebarTree.pinMove(fromRoot: 1, toRoot: 4, pinCount: 3)! == (0, 2))
        #expect(SidebarTree.pinMove(fromRoot: 1, toRoot: 3, pinCount: 3)! == (0, 1))
        // Dropped in its own gaps: no move.
        #expect(SidebarTree.pinMove(fromRoot: 2, toRoot: 2, pinCount: 3) == nil)
        #expect(SidebarTree.pinMove(fromRoot: 2, toRoot: 3, pinCount: 3) == nil)
        // Above Home or below This PC: clamped to the first and last gap.
        #expect(SidebarTree.pinMove(fromRoot: 3, toRoot: 0, pinCount: 3)! == (2, 0))
        #expect(SidebarTree.pinMove(fromRoot: 1, toRoot: 9, pinCount: 3)! == (0, 2))
        // Not a pin.
        #expect(SidebarTree.pinMove(fromRoot: 0, toRoot: 2, pinCount: 3) == nil)
        #expect(SidebarTree.pinMove(fromRoot: 4, toRoot: 2, pinCount: 3) == nil)
    }

    @Test func recentsSkipLibraryHiddenAndPackageContents() {
        let home = "/Users/me"
        #expect(SpotlightRecents.isUserFile("/Users/me/Documents/a.pdf", home: home))
        #expect(!SpotlightRecents.isUserFile("/Users/me/Library/Caches/x.db", home: home))
        #expect(!SpotlightRecents.isUserFile("/Users/me/.config/x.json", home: home))
        #expect(!SpotlightRecents.isUserFile("/Applications/X.app/Contents/Resources/a.png", home: home))
    }
}
