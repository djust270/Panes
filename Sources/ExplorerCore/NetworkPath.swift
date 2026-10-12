import Foundation

/// A network share typed into the address bar, e.g. `\\server\share\folder` or
/// `smb://server/share/folder`, split into the share to mount and the folder inside it.
public struct NetworkPath: Sendable, Hashable {
    /// The share itself, e.g. `smb://server/share`. This is what gets mounted.
    public let shareURL: URL
    /// Path components below the share, e.g. `["folder"]`.
    public let subpath: [String]

    private static let schemes: Set = ["smb", "afp", "nfs", "cifs"]

    /// Parses `input`, or returns `nil` if it isn't a network path. UNC paths (`\\server\share`
    /// or `//server/share`) are treated as SMB, as on Windows.
    public init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        if trimmed.hasPrefix("\\\\") || trimmed.hasPrefix("//") {
            let unc = trimmed.replacingOccurrences(of: "\\", with: "/").drop { $0 == "/" }
            guard let encoded = unc.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            urlString = "smb://" + encoded
        } else {
            urlString = trimmed
        }

        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), Self.schemes.contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }

        let parts = components.path.split(separator: "/").map(String.init)
        var share = components
        share.scheme = scheme == "cifs" ? "smb" : scheme
        share.query = nil
        share.fragment = nil
        // NFS exports are whole paths (server:/export/dir); only SMB/AFP have a one-level share.
        if scheme == "nfs" {
            subpath = []
        } else {
            share.path = parts.first.map { "/" + $0 } ?? ""
            subpath = Array(parts.dropFirst())
        }
        guard let url = share.url else { return nil }
        shareURL = url
    }

    /// The folder to open once the share is mounted at `mountPoint`.
    public func folder(at mountPoint: URL) -> URL {
        subpath.reduce(mountPoint) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
    }

    /// The mount point of this share if it is already mounted, matched by server and share
    /// name (case-insensitively, as SMB does).
    public func existingMountPoint() -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys) ?? []
        return volumes.first { volume in
            guard let remount = try? volume.resourceValues(forKeys: Set(keys)).volumeURLForRemounting else {
                return false
            }
            return Self.sameShare(remount, shareURL)
        }
    }

    static func sameShare(_ lhs: URL, _ rhs: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = components.host else { return nil }
            let share = components.path.split(separator: "/").first.map(String.init) ?? ""
            let decoded = share.removingPercentEncoding ?? share
            return "\(components.scheme?.lowercased() ?? "")://\(host.lowercased())/\(decoded.lowercased())"
        }
        guard let left = key(lhs) else { return false }
        return left == key(rhs)
    }
}
