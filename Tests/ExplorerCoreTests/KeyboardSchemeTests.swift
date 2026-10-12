import Foundation
import Testing
@testable import ExplorerCore

@Suite struct KeyboardSchemeTests {
    @Test func windowsSchemeShowsCtrlKeysFirst() {
        let scheme = KeyboardScheme.windows
        #expect(scheme.shortcuts(for: .copy).first == KeyShortcut("c", .control))
        #expect(scheme.shortcuts(for: .redo).first == KeyShortcut("y", .control))
        #expect(scheme.shortcuts(for: .newFolder).first == KeyShortcut("n", [.control, .shift]))
        #expect(scheme.shortcuts(for: .back).first == KeyShortcut(.leftArrow, .option))
        #expect(scheme.shortcuts(for: .up).first == KeyShortcut(.upArrow, .option))
        #expect(scheme.shortcuts(for: .refresh).first == KeyShortcut(.f5))
        #expect(scheme.shortcuts(for: .viewMode(6)).first == KeyShortcut("6", [.control, .shift]))
    }

    @Test func windowsSchemeKeepsMacKeysAsAlternates() {
        let copy = KeyboardScheme.windows.shortcuts(for: .copy)
        #expect(copy.contains(KeyShortcut("c", .command)))
        // Duplicates appear once.
        let nextTab = KeyboardScheme.windows.shortcuts(for: .nextTab)
        #expect(nextTab.filter { $0 == KeyShortcut(.tab, .control) }.count == 1)
    }

    @Test func macSchemeUsesCommandAndAddsOnlyFunctionKeys() {
        let scheme = KeyboardScheme.mac
        #expect(scheme.shortcuts(for: .copy) == [KeyShortcut("c", .command)])
        #expect(scheme.shortcuts(for: .refresh) == [KeyShortcut("r", .command), KeyShortcut(.f5)])
        #expect(scheme.shortcuts(for: .rename) == [KeyShortcut(.f2)])
        #expect(scheme.shortcuts(for: .viewMode(3)) == [KeyShortcut("3", .command)])
        #expect(!scheme.shortcuts(for: .back).contains(KeyShortcut(.leftArrow, .option)))
    }

    @Test(arguments: KeyboardScheme.allCases)
    func noShortcutIsSharedByTwoCommands(scheme: KeyboardScheme) {
        var owners: [KeyShortcut: ExplorerCommand] = [:]
        for command in ExplorerCommand.allCases {
            for shortcut in scheme.shortcuts(for: command) {
                if let owner = owners[shortcut] {
                    Issue.record("\(shortcut) is used by both \(owner) and \(command)")
                }
                owners[shortcut] = command
            }
        }
    }

    @Test func outOfRangeIndexesHaveNoShortcut() {
        #expect(KeyboardScheme.windows.shortcuts(for: .viewMode(9)).isEmpty)
        #expect(KeyboardScheme.windows.shortcuts(for: .selectTab(10)).isEmpty)
    }

    @Test func describesShortcutsInMacNotation() {
        #expect(KeyShortcut("n", [.control, .shift]).description == "⌃⇧N")
        #expect(KeyShortcut(.leftArrow, .option).description == "⌥←")
        #expect(KeyShortcut(.f5).description == "F5")
    }
}

@Suite struct TypeAheadSelectorTests {
    let names = ["apple", "Avocado", "banana", "blueberry", "Cherry", "Élan"]
    let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func prefixBuildsUpWithinTimeout() {
        var selector = TypeAheadSelector()
        #expect(selector.type("b", at: start, names: names, current: nil) == 2)
        #expect(selector.type("l", at: start + 0.3, names: names, current: 2) == 3)
        #expect(selector.currentPrefix(at: start + 0.5) == "bl")
    }

    @Test func pauseStartsANewPrefix() {
        var selector = TypeAheadSelector()
        _ = selector.type("b", at: start, names: names, current: nil)
        #expect(selector.type("c", at: start + 2, names: names, current: 2) == 4)
        #expect(selector.currentPrefix(at: start + 2) == "c")
    }

    @Test func repeatingALetterCycles() {
        var selector = TypeAheadSelector()
        #expect(selector.type("a", at: start, names: names, current: nil) == 0)
        #expect(selector.type("a", at: start + 0.2, names: names, current: 0) == 1)
        #expect(selector.type("a", at: start + 0.4, names: names, current: 1) == 0)
    }

    @Test func singleLetterStartsAfterTheCurrentItem() {
        var selector = TypeAheadSelector()
        #expect(selector.type("b", at: start, names: names, current: 2) == 3)
    }

    @Test func longerPrefixKeepsTheCurrentMatch() {
        var selector = TypeAheadSelector()
        _ = selector.type("b", at: start, names: names, current: 0)
        #expect(selector.type("a", at: start + 0.1, names: names, current: 2) == 2)
    }

    @Test func ignoresCaseAndDiacritics() {
        var selector = TypeAheadSelector()
        #expect(selector.type("el", at: start, names: names, current: nil) == 5)
        selector.reset()
        #expect(selector.type("CH", at: start, names: names, current: nil) == 4)
    }

    @Test func noMatchReturnsNil() {
        var selector = TypeAheadSelector()
        #expect(selector.type("z", at: start, names: names, current: 1) == nil)
        #expect(selector.type("a", at: start, names: [], current: nil) == nil)
    }
}

@Suite struct TabStripLayoutTests {
    @Test func tabsShareWidthWithinLimits() {
        #expect(TabStripLayout.tabWidth(count: 1, available: 1000) == TabStripLayout.maximumTabWidth)
        #expect(TabStripLayout.tabWidth(count: 5, available: 1000) == 200)
        #expect(TabStripLayout.tabWidth(count: 50, available: 1000) == TabStripLayout.minimumTabWidth)
    }

    @Test func insertionIndexIsClamped() {
        #expect(TabStripLayout.insertionIndex(forX: -20, tabWidth: 100, count: 3) == 0)
        #expect(TabStripLayout.insertionIndex(forX: 150, tabWidth: 100, count: 3) == 1)
        #expect(TabStripLayout.insertionIndex(forX: 900, tabWidth: 100, count: 3) == 2)
    }

    @Test func closingSelectsTheRightNeighbour() {
        #expect(TabStripLayout.selectionAfterClosing(1, selected: 1, count: 4) == 1)
        #expect(TabStripLayout.selectionAfterClosing(3, selected: 3, count: 4) == 2)
        #expect(TabStripLayout.selectionAfterClosing(0, selected: 2, count: 4) == 1)
        #expect(TabStripLayout.selectionAfterClosing(3, selected: 1, count: 4) == 1)
        #expect(TabStripLayout.selectionAfterClosing(0, selected: 0, count: 1) == nil)
    }

    @Test func indexesShiftAroundAMovedTab() {
        // [a b c d], move a (0) to 2 → [b c a d]
        #expect(TabStripLayout.indexAfterMove(0, from: 0, to: 2) == 2)
        #expect(TabStripLayout.indexAfterMove(1, from: 0, to: 2) == 0)
        #expect(TabStripLayout.indexAfterMove(3, from: 0, to: 2) == 3)
        // move d (3) to 1 → [a d b c]
        #expect(TabStripLayout.indexAfterMove(1, from: 3, to: 1) == 2)
        #expect(TabStripLayout.indexAfterMove(0, from: 3, to: 1) == 0)
    }
}

@Suite struct FileKindFilterTests {
    func item(_ name: String, _ kind: FileItem.Kind = .file) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, kind: kind)
    }

    @Test func classifiesByExtension() {
        #expect(FileKind.pictures.matches(item("a.jpg")))
        #expect(FileKind.music.matches(item("a.mp3")))
        #expect(FileKind.videos.matches(item("a.mov")))
        #expect(FileKind.archives.matches(item("a.zip")))
        #expect(FileKind.documents.matches(item("a.pdf")))
        #expect(FileKind.documents.matches(item("a.txt")))
        #expect(!FileKind.pictures.matches(item("a.txt")))
    }

    @Test func foldersAreOnlyFolders() {
        #expect(FileKind.folders.matches(item("Stuff", .directory)))
        #expect(!FileKind.folders.matches(item("a.jpg")))
        #expect(!FileKind.pictures.matches(item("Photos.jpg", .directory)))
    }

    @Test func setMatchesAnyKindAndEmptyMatchesAll() {
        let items = [item("a.jpg"), item("b.mp3"), item("c.txt"), item("D", .directory)]
        #expect(Set<FileKind>().filter(items).count == 4)
        #expect(Set([FileKind.pictures, .music]).filter(items).map(\.name) == ["a.jpg", "b.mp3"])
    }
}
