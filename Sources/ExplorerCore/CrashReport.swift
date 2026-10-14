import Foundation

/// A macOS crash report (`.ips`, as written to `~/Library/Logs/DiagnosticReports`), reduced to
/// what's useful in a bug report: versions, the exception and the crashed thread's stack.
/// Paths, user names and other threads are left out.
public struct CrashReport: Sendable, Equatable {
    public var processName: String
    public var appVersion: String
    public var buildVersion: String
    public var osVersion: String
    public var timestamp: String
    /// "EXC_BAD_ACCESS (SIGSEGV)", or the termination reason when there's no exception.
    public var exception: String
    /// Application-specific messages: assertion and uncaught-exception text.
    public var messages: [String]
    /// The crashed thread's frames, "image  symbol + offset".
    public var frames: [String]

    /// `bug_type` 309 is a crash (others are hangs, spins, jetsam events…).
    static let crashBugType = "309"

    /// Parses a report: a one-line JSON header, then the JSON body. `nil` if it isn't a crash.
    public init?(data: Data) {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              header["bug_type"] as? String == Self.crashBugType,
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])
                as? [String: Any]
        else { return nil }

        processName = header["name"] as? String ?? header["app_name"] as? String ?? "?"
        appVersion = header["app_version"] as? String ?? ""
        buildVersion = header["build_version"] as? String ?? ""
        osVersion = header["os_version"] as? String ?? ""
        timestamp = header["timestamp"] as? String ?? ""
        exception = Self.exception(in: body)
        messages = Self.messages(in: body)
        frames = Self.frames(in: body)
    }

    private static func exception(in body: [String: Any]) -> String {
        if let exception = body["exception"] as? [String: Any], let type = exception["type"] as? String {
            return (exception["signal"] as? String).map { "\(type) (\($0))" } ?? type
        }
        let termination = body["termination"] as? [String: Any]
        return termination?["indicator"] as? String ?? "Unknown"
    }

    private static func messages(in body: [String: Any]) -> [String] {
        // "asi": { "libsystem_c.dylib": ["abort() called"], "AppKit": ["*** Terminating app…"] }
        guard let asi = body["asi"] as? [String: Any] else { return [] }
        return asi.keys.sorted().flatMap { asi[$0] as? [String] ?? [] }
    }

    private static func frames(in body: [String: Any]) -> [String] {
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "???" }
        // An uncaught NSException's own backtrace says more than the abort() that followed it.
        var stack = body["lastExceptionBacktrace"] as? [[String: Any]] ?? []
        if stack.isEmpty, let threads = body["threads"] as? [[String: Any]] {
            let index = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
            if threads.indices.contains(index) { stack = threads[index]["frames"] as? [[String: Any]] ?? [] }
        }
        return stack.map { frame in
            let imageIndex = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(imageIndex) ? images[imageIndex] : "???"
            guard let symbol = frame["symbol"] as? String else {
                return "\(image)  +\(frame["imageOffset"] as? Int ?? 0)"
            }
            return "\(image)  \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
        }
    }

    /// Markdown for an issue: versions, exception, messages and up to `maxFrames` frames.
    public func issueBody(maxFrames: Int = 40) -> String {
        var lines = [
            "**Version:** \(appVersion) (\(buildVersion))",
            "**macOS:** \(osVersion)",
            "**When:** \(timestamp)",
            "**Exception:** \(exception)",
        ]
        if !messages.isEmpty {
            lines += ["", "```", messages.joined(separator: "\n"), "```"]
        }
        lines += ["", "Crashed thread:", "```"]
        lines += frames.prefix(maxFrames).enumerated().map { "\($0.offset)  \($0.element)" }
        if frames.count > maxFrames { lines.append("… \(frames.count - maxFrames) more") }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    /// Crash reports for `processName` in `directory` written after `date`, newest first.
    public static func reports(
        for processName: String,
        in directory: URL = defaultDirectory,
        after date: Date
    ) -> [(url: URL, date: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        )) ?? []
        return files.compactMap { url in
            // "Explorer-2026-10-13-101139.ips"; the date suffix keeps "Explorer Helper" out.
            guard url.pathExtension == "ips", url.lastPathComponent.hasPrefix(processName + "-"),
                  let modified = (try? url.resourceValues(forKeys: keys))?.contentModificationDate,
                  modified > date
            else { return nil }
            return (url, modified)
        }
        .sorted { $0.date > $1.date }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }
}
