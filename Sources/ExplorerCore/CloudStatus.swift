import Foundation

/// An item's sync state in a cloud folder (OneDrive, iCloud Drive…): the Status column.
public enum CloudStatus: Int, Sendable, Hashable, CaseIterable {
    /// Pinned: "Always keep on this device".
    case alwaysAvailable
    case availableOnDevice
    case onlineOnly
    case syncing
    case error

    /// As Windows words it.
    public var title: String {
        switch self {
        case .alwaysAvailable: return "Always available on this device"
        case .availableOnDevice: return "Available on this device"
        case .onlineOnly: return "Available when online"
        case .syncing: return "Sync pending"
        case .error: return "Sync problem"
        }
    }
}

/// Reads `CloudStatus`. The listing gives most of it for free (`FileItem.isOnlineOnly`);
/// syncing, errors and pinning need the File Provider's view of the item, ~2 ms each, so only
/// items that can have them (those with local contents) are asked, off the main thread.
public enum CloudStatusReader {
    private static let keys: Set<URLResourceKey> = [
        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
    ]

    /// Whether `folder`'s items are synced: it's in a cloud folder, or the provider says so
    /// (e.g. Desktop and Documents kept in iCloud Drive).
    public static func isCloudFolder(_ folder: URL) -> Bool {
        if CloudStorage.isInCloudFolder(folder) { return true }
        return (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// The status the listing alone tells: files are online-only or on this device. Folders
    /// have none (a folder's own state says nothing about what's in it) unless syncing.
    public static func quickStatus(of item: FileItem) -> CloudStatus? {
        guard !item.isFolder else { return nil }
        return item.isOnlineOnly ? .onlineOnly : .availableOnDevice
    }

    /// Whether `read` could tell more than `quickStatus`: online-only items can't be syncing or
    /// pinned.
    public static func needsReading(_ item: FileItem) -> Bool {
        !item.isOnlineOnly && item.kind != .symlink
    }

    /// The full status, asking the File Provider.
    public static func read(_ item: FileItem) -> CloudStatus? {
        var url = item.url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: keys) else { return quickStatus(of: item) }
        let provider = ProviderActions.state(of: item.url)
        return status(
            isFolder: item.isFolder,
            isOnlineOnly: item.isOnlineOnly,
            isUploaded: values.ubiquitousItemIsUploaded ?? true,
            isTransferring: values.ubiquitousItemIsUploading == true || values.ubiquitousItemIsDownloading == true
                || provider?.isSyncing == true,
            hasProblem: values.ubiquitousItemHasUnresolvedConflicts == true
                || values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil,
            isPinned: { provider?.isPinned == true }
        )
    }

    /// `items` with `read` statuses for those that `needsReading`; the rest unchanged.
    public static func refined(_ items: [FileItem]) -> [FileItem] {
        items.map { item in
            guard needsReading(item) else { return item }
            var item = item
            item.cloudStatus = read(item)
            return item
        }
    }

    static func status(
        isFolder: Bool,
        isOnlineOnly: Bool,
        isUploaded: Bool,
        isTransferring: Bool,
        hasProblem: Bool,
        isPinned: () -> Bool = { false }
    ) -> CloudStatus? {
        if hasProblem { return .error }
        if isTransferring || !isUploaded { return .syncing }
        if isFolder { return nil }
        if isOnlineOnly { return .onlineOnly }
        return isPinned() ? .alwaysAvailable : .availableOnDevice
    }
}
