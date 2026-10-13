import Foundation

/// Archives that "Extract All…" can unpack: ZIP with `ditto` (Finder's own tool, which
/// restores resource forks and extended attributes), and tar, 7-Zip, RAR, xar and cpio with
/// `bsdtar` (libarchive).
public enum Archive {
    /// Multi-part extensions first, so "a.tar.gz" loses ".tar.gz", not just ".gz".
    private static let tarExtensions = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar", ".tgz", ".tbz", ".tbz2", ".txz",
        ".7z", ".rar", ".xar", ".cpio",
    ]

    public static func isExtractable(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip" || tarSuffix(of: url) != nil
    }

    private static func tarSuffix(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return tarExtensions.first { name.hasSuffix($0) && name.count > $0.count }
    }

    /// The name without the archive's extension: "Photos.zip" → "Photos", "src.tar.gz" → "src".
    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        let suffixLength = url.pathExtension.lowercased() == "zip" ? 4 : (tarSuffix(of: url)?.count ?? 0)
        let stem = String(name.dropLast(suffixLength))
        return stem.isEmpty ? name : stem
    }

    /// Windows' suggested destination: a folder named after the archive, beside it.
    public static func defaultDestination(for archive: URL) -> URL {
        archive.deletingLastPathComponent().appendingPathComponent(stem(of: archive), isDirectory: true)
    }

    /// The tool and arguments that unpack `archive` into the existing folder `directory`.
    public static func extractionCommand(for archive: URL, into directory: URL) -> (tool: String, arguments: [String]) {
        if archive.pathExtension.lowercased() == "zip" {
            return ("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        }
        return ("/usr/bin/tar", ["-x", "-f", archive.path, "-C", directory.path])
    }
}
