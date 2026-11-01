import Foundation

/// A computer reached over SSH: a host name, IP address or `~/.ssh/config` alias, with an
/// optional user name and port (otherwise ssh's own config decides).
public struct RemoteHost: Sendable, Hashable, Codable {
    public let user: String?
    /// Without brackets, also for IPv6 addresses.
    public let hostname: String
    public let port: Int?

    /// `nil` for values ssh could mistake for options (a leading `-`) or that can't be a
    /// host or user name.
    public init?(user: String?, hostname: String, port: Int?) {
        let user = user.flatMap { $0.isEmpty ? nil : $0 }
        guard Self.isValidName(hostname), !hostname.contains("/") else { return nil }
        if let user, !Self.isValidName(user) || user.contains("@") { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        self.user = user
        self.hostname = hostname
        self.port = port
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }

    /// "dave@server", "server" or "dave@server:2222".
    public var displayName: String {
        var name = user.map { "\($0)@" } ?? ""
        name += port == nil ? hostname : bracketedHostname
        if let port { name += ":\(port)" }
        return name
    }

    /// Identifies the connection: equal for hosts ssh would connect to the same way.
    public var key: String {
        "\(user ?? "")@\(hostname.lowercased()):\(port.map(String.init) ?? "")"
    }

    /// IPv6 addresses in brackets, as URLs and scp-style addresses need them.
    var bracketedHostname: String {
        hostname.contains(":") ? "[\(hostname)]" : hostname
    }
}

/// A folder or file on an SSH server.
public struct RemotePath: Sendable, Hashable, Codable {
    public let host: RemoteHost
    /// Absolute and normalised once resolved; until then relative to the user's home folder
    /// (`""` is the home folder itself), as typed in `host:path`.
    public let path: String

    public static let urlScheme = "sftp"

    public init(host: RemoteHost, path: String) {
        self.host = host
        self.path = path.hasPrefix("/") ? Self.normalized(path) : Self.trimmedRelative(path)
    }

    /// Whether `path` is absolute. Unresolved paths are only navigation targets; listings
    /// and items always use resolved ones.
    public var isResolved: Bool { path.hasPrefix("/") }

    /// The last path component, or the host at `/` and the home folder.
    public var name: String {
        guard path != "/", let last = path.split(separator: "/").last else { return host.displayName }
        return String(last)
    }

    /// The folder holding this one; `nil` at `/` and for unresolved paths.
    public var parent: RemotePath? {
        guard isResolved, path != "/" else { return nil }
        let parentPath = (path as NSString).deletingLastPathComponent
        return RemotePath(host: host, path: parentPath.isEmpty ? "/" : parentPath)
    }

    public func appending(_ name: String) -> RemotePath {
        if path.isEmpty { return RemotePath(host: host, path: name) }
        return RemotePath(host: host, path: path.hasSuffix("/") ? path + name : path + "/" + name)
    }

    /// `sftp://user@host:port/path`, percent-encoded: a remote item's `FileItem.url`.
    /// Unresolved paths sit under `/~/`, as in the SFTP URI draft.
    public var url: URL {
        var string = "\(Self.urlScheme)://"
        if let user = host.user {
            string += (user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user) + "@"
        }
        string += host.bracketedHostname
        if let port = host.port { string += ":\(port)" }
        let fullPath = isResolved ? path : "/~" + (path.isEmpty ? "" : "/" + path)
        string += fullPath.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? fullPath
        // Only fails for hosts `RemoteHost` rejects; fall back to something inert.
        return URL(string: string) ?? URL(string: "\(Self.urlScheme)://invalid")!
    }

    /// The path of a remote item's `url`; `nil` for other URLs.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme,
              var hostname = url.host(percentEncoded: false), !hostname.isEmpty else { return nil }
        if hostname.hasPrefix("["), hostname.hasSuffix("]") { hostname = String(hostname.dropFirst().dropLast()) }
        guard let host = RemoteHost(user: url.user(percentEncoded: false), hostname: hostname, port: url.port)
        else { return nil }
        self.init(host: host, path: Self.urlPath(url.path(percentEncoded: false)))
    }

    /// `dave@server:/home/dave`, scp style, as shown when editing the address bar and by
    /// "Copy as path"; `sftp://` form when a port is needed. `parse` reads both back.
    public var addressString: String {
        if host.port != nil {
            let fullPath = isResolved ? path : "/~" + (path.isEmpty ? "" : "/" + path)
            return "\(Self.urlScheme)://\(host.displayName)\(fullPath)"
        }
        return host.displayName + ":" + path
    }

    // MARK: Parsing

    /// Reads an address typed into the address bar: `sftp://`, `ssh://` or `scp://` URLs, or
    /// scp-style `[user@]host:[path]`. `nil` if it isn't one. Local paths, `C:\…` and
    /// network shares (`\\server\share`) never parse.
    public static func parse(_ input: String) -> RemotePath? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard ["sftp", "ssh", "scp"].contains(scheme) else { return nil }
            return parseURL(String(text[schemeEnd.upperBound...]))
        }
        return parseSCP(text)
    }

    /// `user@host:port/path` after the scheme. Split by hand rather than with `URL`, so
    /// typed spaces and other unencoded characters work.
    private static func parseURL(_ rest: String) -> RemotePath? {
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = String(rest[..<slash])
        let rawPath = String(rest[slash...])
        var user: String?
        if let at = authority.lastIndex(of: "@") {
            // ssh:// URLs may add ";fingerprint=…" to the user name.
            let userPart = authority[..<at].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            user = userPart.removingPercentEncoding ?? userPart
            authority = String(authority[authority.index(after: at)...])
        }
        guard let (hostname, port) = splitHostPort(authority),
              let host = RemoteHost(user: user, hostname: hostname, port: port) else { return nil }
        return RemotePath(host: host, path: urlPath(rawPath.removingPercentEncoding ?? rawPath))
    }

    /// `host`, `host:port`, `[v6]` or `[v6]:port`. A bad port is an error, not part of the host.
    private static func splitHostPort(_ authority: String) -> (String, Int?)? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let hostname = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.isEmpty { return (hostname, nil) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (hostname, port)
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (authority, nil)
        case 2:
            if parts[1].isEmpty { return (String(parts[0]), nil) }
            guard let port = Int(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default: return nil
        }
    }

    /// `/~` and `/~/x` are relative to the home folder; an empty path is the home folder.
    private static func urlPath(_ path: String) -> String {
        if path.isEmpty || path == "/~" || path == "/~/" { return "" }
        if path.hasPrefix("/~/") { return String(path.dropFirst(3)) }
        return path
    }

    private static let scpHostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    /// `[user@]host:[path]`. Strict, so drive letters (`C:`), local paths and Windows paths
    /// aren't mistaken for hosts.
    private static func parseSCP(_ text: String) -> RemotePath? {
        guard !text.contains("\\"), let first = text.first, !"/~.".contains(first) else { return nil }
        var user: String?
        var rest = Substring(text)
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"), at < colon {
            user = String(text[..<at])
            rest = text[text.index(after: at)...]
        }
        let hostname: String
        let afterHost: Substring
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            hostname = String(rest[rest.index(after: rest.startIndex)..<close])
            afterHost = rest[rest.index(after: close)...]
            guard hostname.contains(":") else { return nil }
        } else {
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            hostname = String(rest[..<colon])
            afterHost = rest[colon...]
            guard hostname.count >= 2, !hostname.contains("/"),
                  hostname.unicodeScalars.allSatisfy(scpHostCharacters.contains) else { return nil }
        }
        guard afterHost.hasPrefix(":"),
              let host = RemoteHost(user: user, hostname: hostname, port: nil) else { return nil }
        var path = String(afterHost.dropFirst())
        if path == "~" {
            path = ""
        } else if path.hasPrefix("~/") {
            path = String(path.dropFirst(2))
        }
        return RemotePath(host: host, path: path)
    }

    // MARK: Normalising

    /// Collapses `//`, `.` and `..`; `..` at the root stays at the root.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func trimmedRelative(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    /// `urlPathAllowed` keeps `;` and `=`; fine in paths. `%`, `?` and `#` are encoded.
    private static let pathAllowed = CharacterSet.urlPathAllowed
}

extension FileItem {
    /// Whether this is an item on an SSH server (its `url` is an `sftp://` URL).
    public var isRemote: Bool { url.scheme == RemotePath.urlScheme }
}
