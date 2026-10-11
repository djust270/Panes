import Testing
@testable import ExplorerCore

@Suite struct FileSizeFormatTests {
    @Test func zeroBytesIsNonEmpty() {
        #expect(!FileSizeFormat.string(for: 0).isEmpty)
    }

    @Test func formatsInMegabytes() {
        let result = FileSizeFormat.string(for: 1_200_000)
        #expect(result.contains("MB"))
    }

    @Test func formatsInKilobytes() {
        let result = FileSizeFormat.string(for: 2_048)
        #expect(result.contains("KB"))
    }
}
