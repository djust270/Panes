import Foundation
import UniformTypeIdentifiers

/// A snapshot of a single file-system entry, as shown in a folder view.
///
/// Values are captured at load time; refresh by reloading the parent directory.
public struct FileItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        /// A directory presented as a single file (e.g. `.app`, `.rtfd`).
        case package
        case symlink
    }

    /// Standardized (`standardizedFileURL`), as folder listings, `load` and searches make
    /// them, so views can use it as a key directly: standardizing costs ~10 µs, which adds
    /// up to seconds over 100,000 items.
    public let url: URL
    public let name: String
    public let kind: Kind
    /// Logical size in bytes; `nil` for directories.
    public let size: Int64?
    public let dateModified: Date?
    public let dateCreated: Date?
    public let isHidden: Bool
    /// Uniform Type Identifier, e.g. `public.jpeg`.
    public let typeIdentifier: String?
    /// Where a Recycle Bin item came from; `nil` outside the Recycle Bin.
    public var trashInfo: TrashInfo?
    /// Tags, dimensions and duration; `nil` until read with `FilePropertiesReader`.
    public var properties: FileProperties?
    /// The drive, for This PC's items; `nil` elsewhere.
    public var volume: MountedVolume?
    /// In a cloud folder, whether only a placeholder is on disk (`SF_DATALESS`): reading the
    /// contents downloads them.
    public var isOnlineOnly = false
    /// Sync state, for items in cloud folders; `nil` elsewhere (and for most folders).
    public var cloudStatus: CloudStatus?

    public var id: URL { url }

    /// True for anything the user can navigate *into*.
    public var isFolder: Bool { kind == .directory }

    /// The name as shown in views: without a known extension unless `showingExtensions`.
    public func displayName(showingExtensions: Bool) -> String {
        FileNaming.displayName(name, isFolder: kind == .directory, showingExtensions: showingExtensions)
    }

    /// File name extension, lowercased, or empty if none.
    public var pathExtension: String { url.pathExtension.lowercased() }

    public init(
        url: URL,
        name: String,
        kind: Kind,
        size: Int64? = nil,
        dateModified: Date? = nil,
        dateCreated: Date? = nil,
        isHidden: Bool = false,
        typeIdentifier: String? = nil,
        trashInfo: TrashInfo? = nil
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.size = size
        self.dateModified = dateModified
        self.dateCreated = dateCreated
        self.isHidden = isHidden
        self.typeIdentifier = typeIdentifier
        self.trashInfo = trashInfo
    }
}

/// Recycle Bin details for a trashed item.
public struct TrashInfo: Sendable, Hashable {
    /// The item's path before it was deleted, if known.
    public let originalURL: URL?
    public let dateDeleted: Date?

    public init(originalURL: URL?, dateDeleted: Date?) {
        self.originalURL = originalURL
        self.dateDeleted = dateDeleted
    }
}

extension FileItem {
    /// Resource keys prefetched during enumeration. Keep this list minimal — every
    /// extra key costs time on folders with many entries.
    static let resourceKeys: [URLResourceKey] = [
        .nameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .contentTypeKey,
    ]

    static let resourceKeySet = Set(resourceKeys)

    /// Reads one item's attributes from disk (search results, Home); `nil` if it's gone.
    /// Items in cloud folders get their quick `CloudStatus`.
    public static func load(_ url: URL) -> FileItem? {
        guard var item = try? FileItem(prefetchedURL: url.standardizedFileURL) else { return nil }
        if CloudStorage.isInCloudFolder(item.url) {
            item.isOnlineOnly = CloudSync.isOnlineOnly(item.url)
            item.cloudStatus = CloudStatusReader.quickStatus(of: item)
        }
        return item
    }

    /// Builds an item from a URL whose resource values were prefetched with `resourceKeys`.
    init(prefetchedURL url: URL) throws {
        let values = try url.resourceValues(forKeys: Self.resourceKeySet)

        let kind: Kind
        if values.isSymbolicLink == true {
            kind = .symlink
        } else if values.isPackage == true {
            kind = .package
        } else if values.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }

        self.init(
            url: url,
            name: values.name ?? url.lastPathComponent,
            kind: kind,
            size: kind == .directory ? nil : values.fileSize.map(Int64.init),
            dateModified: values.contentModificationDate,
            dateCreated: values.creationDate,
            isHidden: values.isHidden ?? false,
            typeIdentifier: values.contentType?.identifier
        )
    }
}
