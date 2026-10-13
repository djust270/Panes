import Foundation
import Testing
@testable import ExplorerCore

@Suite struct SearchQueryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday 15 May 2024, noon UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2024, month: 5, day: 15, hour: 12))! }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func file(_ name: String, size: Int64? = 100, modified: Date? = nil, type: String? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, kind: .file, size: size,
                 dateModified: modified ?? now, typeIdentifier: type)
    }

    @Test func parsesWordsPhrasesAndFilters() {
        let query = SearchQuery(parsing: #"Annual "q1 report" kind:pictures ext:.PDF size:>1MB date:"last week""#,
                                calendar: calendar)
        #expect(query.terms == ["annual", "q1 report"])
        #expect(query.kinds == [.pictures])
        #expect(query.extensions == ["pdf"])
        #expect(query.size == SizeFilter(minimum: 1_048_577, maximum: nil))
        #expect(query.date == .lastWeek)
    }

    @Test func unquotedTwoWordDates() {
        #expect(SearchQuery(parsing: "date:this month notes").date == .thisMonth)
        #expect(SearchQuery(parsing: "date:this month notes").terms == ["notes"])
    }

    @Test func unknownFiltersAreSearchedForAsWords() {
        let query = SearchQuery(parsing: "foo:bar kind:nonsense http://x")
        #expect(query.terms == ["foo:bar", "kind:nonsense", "http://x"])
        #expect(query.kinds.isEmpty)
    }

    @Test func emptyQueries() {
        #expect(SearchQuery(parsing: "   ").isEmpty)
        #expect(SearchQuery(parsing: "*").isEmpty)
        #expect(!SearchQuery(parsing: "kind:folder").isEmpty)
    }

    @Test func namesMatchEveryWordIgnoringCaseAndAccents() {
        let query = SearchQuery(parsing: "cafe REPORT")
        #expect(query.matchesName("Café report 2024.txt"))
        #expect(!query.matchesName("Café notes.txt"))
    }

    @Test func wildcardsMatchTheWholeName() {
        #expect(SearchQuery(parsing: "*.pdf").matchesName("Report.PDF"))
        #expect(!SearchQuery(parsing: "*.pdf").matchesName("report.pdf.txt"))
        #expect(SearchQuery(parsing: "img_??.jpg").matchesName("IMG_12.jpg"))
        #expect(!SearchQuery(parsing: "img_??.jpg").matchesName("IMG_123.jpg"))
        #expect(SearchQuery(parsing: "a*b*c").matchesName("axxbyyc"))
    }

    @Test func kindAndExtensionFilters() {
        let pictures = SearchQuery(parsing: "kind:picture")
        #expect(pictures.matches(file("a.jpg", type: "public.jpeg")))
        #expect(!pictures.matches(file("a.txt", type: "public.plain-text")))
        let folder = FileItem(url: URL(fileURLWithPath: "/x/f"), name: "f", kind: .directory)
        #expect(SearchQuery(parsing: "kind:folder").matches(folder))
        #expect(!SearchQuery(parsing: "ext:pdf").matches(folder))
        #expect(SearchQuery(parsing: "ext:pdf ext:doc").matches(file("a.doc")))
    }

    @Test func sizeFilters() {
        #expect(SizeFilter(parsing: "empty") == SizeFilter(minimum: 0, maximum: 1))
        #expect(SizeFilter(parsing: "gigantic") == SizeFilter(minimum: 4 << 30, maximum: nil))
        #expect(SizeFilter(parsing: "<=1kb") == SizeFilter(minimum: nil, maximum: 1025))
        #expect(SizeFilter(parsing: "1.5 MB") == SizeFilter(minimum: 1_572_864, maximum: nil))
        #expect(SizeFilter(parsing: "10KB..20KB") == SizeFilter(minimum: 10240, maximum: 20481))
        #expect(SizeFilter(parsing: ">lots") == nil)
        let small = SearchQuery(parsing: "size:small")
        #expect(small.matches(file("a", size: 20_000)))
        #expect(!small.matches(file("a", size: 2_000_000)))
        #expect(!small.matches(FileItem(url: URL(fileURLWithPath: "/x/f"), name: "f", kind: .directory)))
    }

    @Test func namedDatePeriods() {
        let interval = DateFilter.lastWeek.interval(now: now, calendar: calendar)
        #expect(interval.from == day(2024, 5, 6))
        #expect(interval.to == day(2024, 5, 13))
        #expect(DateFilter.today.contains(day(2024, 5, 15), now: now, calendar: calendar))
        #expect(!DateFilter.today.contains(day(2024, 5, 14), now: now, calendar: calendar))
        #expect(DateFilter.yesterday.contains(day(2024, 5, 14), now: now, calendar: calendar))
        #expect(DateFilter.lastYear.contains(day(2023, 12, 31), now: now, calendar: calendar))
    }

    @Test func absoluteDates() {
        #expect(DateFilter(parsing: "2024-05-01", calendar: calendar)
            == .range(from: day(2024, 5, 1), to: day(2024, 5, 2)))
        #expect(DateFilter(parsing: ">2024-05-01", calendar: calendar) == .range(from: day(2024, 5, 2), to: nil))
        #expect(DateFilter(parsing: "<2024-05-01", calendar: calendar) == .range(from: nil, to: day(2024, 5, 1)))
        #expect(DateFilter(parsing: "2024-05-01..2024-05-03", calendar: calendar)
            == .range(from: day(2024, 5, 1), to: day(2024, 5, 4)))
        #expect(DateFilter(parsing: "2024-02-30", calendar: calendar) == nil)
        #expect(DateFilter(parsing: "soon", calendar: calendar) == nil)
        let query = SearchQuery(parsing: "date:>=2024-05-10", calendar: calendar)
        #expect(query.matches(file("a", modified: day(2024, 5, 10)), now: now, calendar: calendar))
        #expect(!query.matches(file("a", modified: day(2024, 5, 9)), now: now, calendar: calendar))
    }

    @Test func spotlightQueryCombinesClauses() {
        let query = SearchQuery(parsing: #"tax "a\b" *.pdf kind:music size:<1kb date:2024-05-01"#, calendar: calendar)
        let spotlight = query.spotlightQuery(now: now, calendar: calendar)
        #expect(spotlight.contains(#"(kMDItemFSName == "*tax*"cd || kMDItemTextContent == "tax*"cdw)"#))
        #expect(spotlight.contains(#"kMDItemFSName == "*a\\b*"cd"#))
        #expect(spotlight.contains(#"kMDItemFSName == "*.pdf"cd"#))
        #expect(spotlight.contains(#"kMDItemContentTypeTree == "public.audio""#))
        #expect(spotlight.contains("kMDItemFSSize < 1024"))
        #expect(spotlight.contains("kMDItemFSContentChangeDate >= $time.iso(2024-05-01T00:00:00Z)"))
        #expect(spotlight.contains("kMDItemFSContentChangeDate < $time.iso(2024-05-02T00:00:00Z)"))
        #expect(NSPredicate(fromMetadataQueryString: spotlight) != nil)
    }

    @Test func spotlightQueryEscapesStars() {
        // A literal "*" can't sneak in as a wildcard through a plain word.
        let spotlight = SearchQuery(terms: ["a\"b"]).spotlightQuery()
        #expect(spotlight.contains(#"*a\"b*"#))
    }
}

@Suite struct DirectorySearchTests {
    @Test func findsMatchesInSubfoldersButNotInsidePackages() async throws {
        let directory = try TemporaryDirectory()
        try directory.createFile(at: "report.txt")
        try directory.createFile(at: "a/b/Report 2.pdf")
        try directory.createFile(at: "a/notes.txt")
        try directory.createFile(at: "App.app/Contents/report.txt")
        try directory.createDirectory("reports")

        let results = DirectorySearch.start(SearchQuery(parsing: "report"), in: directory.url, includeHidden: false)
        var last: SearchProgress?
        for await progress in results { last = progress }
        let names = Set(last?.items.map(\.name) ?? [])
        #expect(names == ["report.txt", "Report 2.pdf", "reports"])
        #expect(last?.isComplete == true)
        #expect(last?.isTruncated == false)
    }

    @Test func stopsAtTheLimit() async throws {
        let directory = try TemporaryDirectory()
        for index in 0..<5 { try directory.createFile("file \(index).txt") }
        let results = DirectorySearch.start(SearchQuery(parsing: "file"), in: directory.url, includeHidden: false,
                                            limit: 3)
        var last: SearchProgress?
        for await progress in results { last = progress }
        #expect(last?.items.count == 3)
        #expect(last?.isTruncated == true)
    }

    @Test func filtersApplyToo() async throws {
        let directory = try TemporaryDirectory()
        try directory.createFile("a.txt", contents: "")
        try directory.createFile("b.txt", contents: "hello")
        let results = DirectorySearch.start(SearchQuery(parsing: "size:empty"), in: directory.url,
                                            includeHidden: false)
        var last: SearchProgress?
        for await progress in results { last = progress }
        #expect(last?.items.map(\.name) == ["a.txt"])
    }
}

@Suite struct SpotlightResultFilterTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    @Test func leavesOutLibraryAndHiddenFoldersUnlessSearchingThere() {
        #expect(FileSearch.isSearchable(home + "/Documents/a.txt", in: home, includeHidden: false))
        #expect(!FileSearch.isSearchable(home + "/Library/Caches/a.txt", in: home, includeHidden: false))
        #expect(FileSearch.isSearchable(home + "/Library/Caches/a.txt", in: home + "/Library", includeHidden: false))
        #expect(!FileSearch.isSearchable(home + "/p/.git/config", in: home, includeHidden: false))
        #expect(FileSearch.isSearchable(home + "/p/.git/config", in: home, includeHidden: true))
        #expect(!FileSearch.isSearchable("/elsewhere/a.txt", in: home, includeHidden: false))
    }

    @Test func sourceCodeIsNotADocument() {
        let script = FileItem(url: URL(fileURLWithPath: "/x/a.js"), name: "a.js", kind: .file,
                              typeIdentifier: "com.netscape.javascript-source")
        let text = FileItem(url: URL(fileURLWithPath: "/x/a.txt"), name: "a.txt", kind: .file,
                            typeIdentifier: "public.plain-text")
        #expect(!FileKind.documents.matches(script))
        #expect(FileKind.documents.matches(text))
    }
}
