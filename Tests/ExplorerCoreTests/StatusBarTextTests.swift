import Testing
@testable import ExplorerCore

@Suite struct StatusBarTextTests {
    @Test func noSelectionShowsJustTotal() {
        #expect(StatusBarText.make(totalCount: 5, selectedCount: 0, selectedSizeBytes: nil) == "5 items")
    }

    @Test func singularTotal() {
        #expect(StatusBarText.make(totalCount: 1, selectedCount: 0, selectedSizeBytes: nil) == "1 item")
    }

    @Test func selectionWithSizeAppendsSizeClause() {
        let text = StatusBarText.make(totalCount: 10, selectedCount: 2, selectedSizeBytes: 1_200_000)
        #expect(text.hasPrefix("10 items | 2 items selected "))
        #expect(text.contains("MB"))
    }

    @Test func singularSelection() {
        let text = StatusBarText.make(totalCount: 10, selectedCount: 1, selectedSizeBytes: 10)
        #expect(text.hasPrefix("10 items | 1 item selected"))
    }

    @Test func allFoldersSelectedOmitsSizeClause() {
        let text = StatusBarText.make(totalCount: 3, selectedCount: 2, selectedSizeBytes: nil)
        #expect(text == "3 items | 2 items selected")
    }
}
