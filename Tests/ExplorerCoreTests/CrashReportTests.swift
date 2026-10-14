import Foundation
import Testing
@testable import ExplorerCore

@Suite struct CrashReportTests {
    static let header = """
    {"app_name":"Explorer","timestamp":"2026-10-13 10:11:39.00 -0400","app_version":"0.2.0",\
    "build_version":"7","bug_type":"309","os_version":"macOS 15.7.4 (24G517)","name":"Explorer"}
    """

    static func report(body: [String: Any], bugType: String = "309") throws -> Data {
        let header = Self.header.replacingOccurrences(of: "\"309\"", with: "\"\(bugType)\"")
        return Data((header + "\n").utf8) + (try JSONSerialization.data(withJSONObject: body))
    }

    nonisolated(unsafe) static let threads: [[String: Any]] = [
        ["frames": [["imageOffset": 1, "symbol": "main", "symbolLocation": 4, "imageIndex": 0]]],
        ["triggered": true, "frames": [
            ["imageOffset": 10, "symbol": "ContentViewController.rebuild()", "symbolLocation": 64, "imageIndex": 0],
            ["imageOffset": 20, "imageIndex": 1],
        ]],
    ]
    nonisolated(unsafe) static let images: [[String: Any]] = [
        ["name": "Explorer", "path": "/Users/someone/x"],
        ["name": "AppKit"],
    ]

    @Test func readsTheCrashedThread() throws {
        let data = try Self.report(body: [
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "faultingThread": 1,
            "threads": Self.threads,
            "usedImages": Self.images,
        ])
        let report = try #require(CrashReport(data: data))
        #expect(report.appVersion == "0.2.0")
        #expect(report.buildVersion == "7")
        #expect(report.exception == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(report.frames == ["Explorer  ContentViewController.rebuild() + 64", "AppKit  +20"])
        let body = report.issueBody()
        #expect(body.contains("macOS 15.7.4"))
        #expect(body.contains("0  Explorer  ContentViewController.rebuild() + 64"))
        #expect(!body.contains("/Users/"))
    }

    @Test func prefersTheUncaughtExceptionBacktrace() throws {
        let data = try Self.report(body: [
            "exception": ["type": "EXC_CRASH", "signal": "SIGABRT"],
            "asi": ["CoreFoundation": ["*** Terminating app due to uncaught exception 'NSRangeException'"]],
            "lastExceptionBacktrace": [["imageOffset": 5, "symbol": "-[NSArray objectAtIndex:]",
                                        "symbolLocation": 8, "imageIndex": 1]],
            "faultingThread": 1,
            "threads": Self.threads,
            "usedImages": Self.images,
        ])
        let report = try #require(CrashReport(data: data))
        #expect(report.messages == ["*** Terminating app due to uncaught exception 'NSRangeException'"])
        #expect(report.frames == ["AppKit  -[NSArray objectAtIndex:] + 8"])
    }

    @Test func ignoresOtherReportKinds() throws {
        #expect(CrashReport(data: try Self.report(body: [:], bugType: "211")) == nil)
        #expect(CrashReport(data: Data("not a report".utf8)) == nil)
    }

    @Test func findsNewReportsForTheProcess() throws {
        let folder = try TemporaryDirectory()
        let old = try folder.createFile("Explorer-2026-10-01-100000.ips")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: old.path)
        try folder.createFile("Explorer-2026-10-13-100000.ips")
        try folder.createFile("Explorer Helper-2026-10-13-100000.ips")
        try folder.createFile("Other-2026-10-13-100000.ips")
        let found = CrashReport.reports(for: "Explorer", in: folder.url, after: Date(timeIntervalSinceNow: -60))
        #expect(found.map(\.url.lastPathComponent) == ["Explorer-2026-10-13-100000.ips"])
    }
}
