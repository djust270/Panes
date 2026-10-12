import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FileGroupingTests {
    /// Wednesday 14 October 2026, noon UTC; weeks start on Sunday.
    private let grouper: FileGrouper = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 1
        return FileGrouper(now: Date(timeIntervalSince1970: 1_791_979_200), calendar: calendar)
    }()

    private func file(_ name: String, size: Int64? = 1, modified: Date? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/\(name)"), name: name, kind: .file, size: size, dateModified: modified)
    }

    private func daysAgo(_ days: Double) -> Date {
        grouper.now.addingTimeInterval(-days * 86_400)
    }

    private func titles(_ items: [FileItem], _ grouping: FileGrouping) -> [String] {
        grouper.groups(items, by: grouping).map(\.title)
    }

    @Test func nameGroupsUseWindowsRanges() {
        let items = ["apple", "Ice", "zebra", "7up", "Émile", "_x", "日本"].map { file($0) }
        #expect(titles(items, FileGrouping(key: .name)) == ["0 - 9", "A - H", "I - P", "Q - Z", "Other"])
        let groups = grouper.groups(items, by: FileGrouping(key: .name))
        #expect(groups[1].items.map(\.name) == ["apple", "Émile"])
        #expect(groups[4].items.map(\.name) == ["_x", "日本"])
    }

    @Test func descendingReversesGroupOrder() {
        let items = ["apple", "zebra"].map { file($0) }
        #expect(titles(items, FileGrouping(key: .name, ascending: false)) == ["Q - Z", "A - H"])
    }

    @Test func dateGroupsNewestFirstByDefault() {
        let items = [
            file("old", modified: daysAgo(800)),
            file("year", modified: daysAgo(100)),
            file("lastMonth", modified: daysAgo(30)),
            file("lastWeek", modified: daysAgo(6)),
            file("thisWeek", modified: daysAgo(2)),
            file("yesterday", modified: daysAgo(1)),
            file("today", modified: daysAgo(0.1)),
            file("unknown", modified: nil),
        ]
        #expect(titles(items, FileGrouping(key: .dateModified)) == [
            "Today", "Yesterday", "Earlier this week", "Last week", "Last month",
            "Earlier this year", "A long time ago", "Unspecified",
        ])
    }

    @Test func earlierThisMonthBeforeLastWeek() {
        // 1 October 2026 is earlier this month but before last week.
        let items = [file("a", modified: daysAgo(13))]
        #expect(titles(items, FileGrouping(key: .dateModified)) == ["Earlier this month"])
    }

    @Test func unspecifiedStaysLastWhenAscending() {
        let items = [file("unknown", modified: nil), file("old", modified: daysAgo(800))]
        #expect(titles(items, FileGrouping(key: .dateModified, ascending: true)) == ["A long time ago", "Unspecified"])
    }

    @Test func sizeGroups() {
        let items: [FileItem] = [
            file("empty", size: 0),
            file("tiny", size: 1_000),
            file("small", size: 500_000),
            file("medium", size: 50_000_000),
            file("large", size: 500_000_000),
            file("huge", size: 2_000_000_000),
            file("gigantic", size: 5_000_000_000),
            FileItem(url: URL(fileURLWithPath: "/dir"), name: "dir", kind: .directory),
        ]
        #expect(titles(items, FileGrouping(key: .size)) == [
            "Empty (0 KB)", "Tiny (0 - 16 KB)", "Small (16 KB - 1 MB)", "Medium (1 - 128 MB)",
            "Large (128 MB - 1 GB)", "Huge (1 - 4 GB)", "Gigantic (> 4 GB)", "Unspecified",
        ])
    }

    @Test func typeGroupsAreAlphabetical() {
        let items = [file("b.txt"), FileItem(url: URL(fileURLWithPath: "/d"), name: "d", kind: .directory)]
        let groups = grouper.groups(items, by: FileGrouping(key: .type))
        #expect(groups.map(\.title) == ["Folder", "TXT File"])
    }

    @Test func itemsKeepTheirOrderWithinGroups() {
        let items = ["b", "a", "c"].map { file($0) }
        #expect(grouper.groups(items, by: FileGrouping(key: .name))[0].items.map(\.name) == ["b", "a", "c"])
    }
}

@Suite struct FileListContentTests {
    private func file(_ name: String) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/f/\(name)"), name: name, kind: .file)
    }

    @Test func ungroupedHasNoHeaders() {
        let content = FileListContent(items: ["b", "a"].map(file))
        #expect(!content.isGrouped)
        #expect(content.rows.count == 2)
        #expect(content.item(atRow: 0)?.name == "a")
        #expect(content.row(of: URL(fileURLWithPath: "/f/b")) == 1)
    }

    @Test func groupedRowsInterleaveHeaders() {
        let items = ["apple", "zebra", "avocado"].map(file)
        let content = FileListContent(items: items, grouping: FileGrouping(key: .name))
        #expect(content.isGrouped)
        #expect(content.rows == [
            .header(section: 0), .item(section: 0, index: 0), .item(section: 0, index: 1),
            .header(section: 1), .item(section: 1, index: 0),
        ])
        #expect(content.item(atRow: 0) == nil)
        #expect(content.header(atRow: 3) == 1)
        #expect(content.itemRows(inSection: 1) == IndexSet(integer: 4))
        #expect(content.allItemRows == IndexSet([1, 2, 4]))
    }

    @Test func collapsedGroupsHideItemsButKeepCount() {
        let content = FileListContent(
            items: ["apple", "zebra"].map(file),
            grouping: FileGrouping(key: .name),
            collapsedGroups: ["name:A - H"]
        )
        #expect(content.sections[0].isCollapsed)
        #expect(content.sections[0].items.isEmpty)
        #expect(content.allItems.count == 2)
        #expect(content.row(of: URL(fileURLWithPath: "/f/apple")) == nil)
        #expect(content.position(of: URL(fileURLWithPath: "/f/zebra"))?.section == 1)
    }
}
