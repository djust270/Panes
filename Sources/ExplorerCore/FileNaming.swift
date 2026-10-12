import Foundation
import UniformTypeIdentifiers

/// Windows Explorer's naming rules for new, copied and conflicting items.
public enum FileNaming {
    public static let newFolderName = "New folder"
    public static let newTextDocumentName = "New Text Document.txt"

    /// Splits a name into stem and extension (including the dot). Folders and dot-files have
    /// no extension: "my.folder" stays whole, ".zshrc" has stem ".zshrc".
    static func split(_ name: String, hasExtension: Bool) -> (stem: String, ext: String) {
        guard hasExtension else { return (name, "") }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), "." + ext)
    }

    /// Whether the item at `url` shows an extension: files do, folders don't, packages
    /// (e.g. "Notes.app") do.
    static func hasExtension(_ url: URL, isDirectory: Bool) -> Bool {
        guard isDirectory else { return true }
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
        return type.conforms(to: .package)
    }

    /// "report.txt", 2 → "report (2).txt".
    public static func numbered(_ name: String, _ number: Int, hasExtension: Bool = true) -> String {
        let (stem, ext) = split(name, hasExtension: hasExtension)
        return "\(stem) (\(number))\(ext)"
    }

    /// The first of `name`, "name (2)", "name (3)", … that isn't taken.
    public static func uniqueName(_ name: String, hasExtension: Bool = true, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        var number = 2
        while isTaken(numbered(name, number, hasExtension: hasExtension)) {
            number += 1
        }
        return numbered(name, number, hasExtension: hasExtension)
    }

    /// Windows' "Compress to ZIP file" name: the item's name without its extension, plus ".zip".
    public static func zipName(for name: String, hasExtension: Bool = true) -> String {
        let stem = split(name, hasExtension: hasExtension).stem
        return (stem.isEmpty ? name : stem) + ".zip"
    }

    /// Windows' "Copy as path": each path in double quotes, one per line.
    public static func quotedPaths(_ urls: [URL]) -> String {
        urls.map { "\"\($0.path)\"" }.joined(separator: "\n")
    }

    /// A path typed or pasted into the address bar, without surrounding quotes or spaces.
    public static func unquotedPath(_ text: String) -> String {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        return path
    }

    /// The name for a copy made in the original's own folder: "report - Copy.txt", then
    /// "report - Copy (2).txt", and so on.
    public static func copyName(for name: String, hasExtension: Bool = true, isTaken: (String) -> Bool) -> String {
        let (stem, ext) = split(name, hasExtension: hasExtension)
        return uniqueName("\(stem) - Copy\(ext)", hasExtension: hasExtension, isTaken: isTaken)
    }

    /// Why `name` can't be used for a file or folder, or `nil` if it can.
    public static func validationError(for name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "You must type a file name."
        }
        if name.contains("/") || name.contains(":") {
            return "A file name can't contain a slash (/) or a colon (:)."
        }
        if name == "." || name == ".." {
            return "The names “.” and “..” are reserved."
        }
        if name.utf8.count > 255 {
            return "The file name is too long."
        }
        return nil
    }

    /// The part of the name to select when renaming starts: the stem for files, everything
    /// for folders. In UTF-16 units, for `NSText` selection.
    public static func renameSelection(for name: String, hasExtension: Bool) -> NSRange {
        let (stem, _) = split(name, hasExtension: hasExtension)
        return NSRange(location: 0, length: (stem as NSString).length)
    }

    /// `isTaken` closure checking names in `directory` (without following symlinks, and
    /// honouring the file system's case sensitivity).
    static func existsChecker(in directory: URL) -> (String) -> Bool {
        { name in
            var info = stat()
            return lstat(directory.appendingPathComponent(name).path, &info) == 0
        }
    }
}
