import Foundation
import UniformTypeIdentifiers

/// Lists folders on SSH servers as `FileItem`s.
public enum RemoteListing {
    /// The items in `folder` (which must be resolved), following symbolic links to tell
    /// folders from files. Hidden means a name starting with ".", as ssh servers use.
    public static func items(
        in folder: RemotePath,
        includeHidden: Bool,
        using client: SFTPClient
    ) throws -> [FileItem] {
        let entries = try client.listDirectory(folder.path).filter { includeHidden || !$0.name.hasPrefix(".") }
        let links = entries.indices.filter { entries[$0].attributes.fileType == .symlink }
        let targets = try client.statMany(links.map { folder.appending(entries[$0].name).path })
        var resolved: [Int: SFTPAttributes?] = [:]
        for (index, target) in zip(links, targets) {
            resolved[index] = target
        }
        return entries.indices.map { index in
            let entry = entries[index]
            let target = resolved[index] ?? entry.attributes
            return item(named: entry.name, in: folder, attributes: entry.attributes, target: target)
        }
    }

    /// The item for one entry. `target` is what a link points to (`nil` if it's broken).
    public static func item(
        named name: String,
        in folder: RemotePath,
        attributes: SFTPAttributes,
        target: SFTPAttributes?
    ) -> FileItem {
        let isDirectory = target?.fileType == .directory
        let type: UTType? = isDirectory
            ? .folder
            : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return FileItem(
            url: folder.appending(name).url,
            name: name,
            kind: isDirectory ? .directory : .file,
            size: isDirectory ? nil : target?.size.map { Int64(clamping: $0) },
            dateModified: (target ?? attributes).dateModified,
            isHidden: name.hasPrefix("."),
            typeIdentifier: type?.identifier
        )
    }
}

extension SFTPError {
    /// Windows-style wording for an error about `path`.
    public func message(for path: String) -> String {
        switch self {
        case .status(.noSuchFile, _):
            return "“\(path)” doesn’t exist on the server. Check the location."
        case .status(.permissionDenied, _):
            return "You don’t currently have permission to access “\(path)”."
        case .status(.eof, _):
            return "The file ended unexpectedly."
        case .status(.unsupported, _):
            return "The server doesn’t support this operation."
        case .status(_, let message):
            return message.isEmpty ? "The server reported an error." : message
        case .connectionLost:
            return "The connection to the server was lost."
        case .unexpectedData:
            return "The server sent unexpected data."
        case .timedOut:
            return "The server stopped responding."
        }
    }
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(.noSuchFile, _): return "The item doesn’t exist on the server."
        case .status(.permissionDenied, _): return "You don’t have permission to access this item on the server."
        default: return message(for: "")
        }
    }
}
