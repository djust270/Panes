import Darwin
import Foundation

/// A `Host` entry from `~/.ssh/config`, offered as a ready-made connection.
public struct SSHConfigHost: Sendable, Hashable {
    /// The alias after `Host`; what ssh is given, so the rest of the block applies.
    public let alias: String
    public let hostname: String?
    public let user: String?
    public let port: Int?

    public init(alias: String, hostname: String? = nil, user: String? = nil, port: Int? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
    }

    /// Connects by alias, leaving user and port to ssh's config.
    public var remoteHost: RemoteHost? {
        RemoteHost(user: nil, hostname: alias, port: nil)
    }
}

/// Reads the concrete hosts from an ssh config file: `Host` lines without patterns, with
/// `Include`s followed as ssh does. Not a full parser: only what a host list needs.
public enum SSHConfigParser {
    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    private static let maximumIncludeDepth = 16

    /// Hosts in `file` and the files it includes, in order, without duplicates.
    public static func hosts(in file: URL = defaultFile) -> [SSHConfigHost] {
        var state = ParseState()
        parse(file, depth: 0, state: &state)
        state.finishBlock()
        var seen: Set<String> = []
        return state.hosts.filter { seen.insert($0.alias.lowercased()).inserted }
    }

    private struct ParseState {
        var hosts: [SSHConfigHost] = []
        /// Aliases of the current `Host` block (empty inside `Match` or a pattern-only block).
        var aliases: [String] = []
        var hostname: String?
        var user: String?
        var port: Int?

        mutating func finishBlock() {
            for alias in aliases {
                hosts.append(SSHConfigHost(alias: alias, hostname: hostname, user: user, port: port))
            }
            aliases = []
            hostname = nil
            user = nil
            port = nil
        }

        /// One `keyword arguments…` line; as in ssh, a block's first value for a keyword wins.
        mutating func apply(_ keyword: String, _ arguments: [String]) {
            switch keyword {
            case "host":
                finishBlock()
                aliases = arguments.filter(SSHConfigParser.isConcrete)
            case "match":
                finishBlock()
            case "hostname":
                hostname = hostname ?? arguments.first
            case "user":
                user = user ?? arguments.first
            case "port":
                port = port ?? arguments.first.flatMap { Int($0) }
            default:
                break
            }
        }
    }

    private static func parse(_ file: URL, depth: Int, state: inout ParseState) {
        guard depth <= maximumIncludeDepth,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let words = tokens(String(line))
            guard let keyword = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            if keyword == "include" {
                for included in arguments.flatMap(expand(include:)) {
                    parse(included, depth: depth + 1, state: &state)
                }
            } else {
                state.apply(keyword, arguments)
            }
        }
    }

    /// Patterns (`*`, `?`, `!negated`) aren't hosts one can connect to.
    static func isConcrete(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.contains(where: { "*?!".contains($0) }) && !alias.hasPrefix("-")
    }

    /// Splits a config line into words: `key value`, `key=value`, quoted arguments and
    /// `#` comments.
    static func tokens(_ line: String) -> [String] {
        var words: [String] = []
        /// The word being read; `nil` between words.
        var current: String?
        var inQuotes = false
        func endWord() {
            if let current { words.append(current) }
            current = nil
        }
        for character in line {
            if inQuotes {
                if character == "\"" { inQuotes = false } else { current?.append(character) }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                current = current ?? ""
            case "#" where current == nil:
                return words
            case " ", "\t":
                endWord()
            case "=" where words.isEmpty:
                // `Key=value`: the first `=` ends the keyword.
                endWord()
            default:
                current = (current ?? "") + String(character)
            }
        }
        endWord()
        return words
    }

    /// Files an `Include` names: `~` expanded, relative paths under `~/.ssh`, globs sorted.
    private static func expand(include pattern: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = pattern
        if path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            path = home + "/.ssh/" + path
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        let paths = (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
        return paths.sorted().map { URL(fileURLWithPath: $0) }
    }
}
