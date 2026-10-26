import Darwin
import FileProvider
import Foundation

/// "Download now" and "Free up space": asks a cloud folder's sync client (any File Provider
/// client, or iCloud Drive) to download items, or to keep only placeholders of them.
public enum CloudSync {
    /// Whether only a placeholder of `url` is on disk (`SF_DATALESS`): reading it downloads it.
    public static func isOnlineOnly(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Whether `url` is online-only, or a folder with anything online-only inside. The system
    /// can't move such items to the Trash: it fails, or waits indefinitely on the File Provider.
    /// Stops at the first one found, and doesn't list online-only folders (that would wait on
    /// the network): they count as online-only themselves. Items outside cloud folders aren't
    /// looked into.
    public static func hasOnlineOnlyContents(_ url: URL) -> Bool {
        guard CloudStorage.isInCloudFolder(url)
                || (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        else { return false }
        return holdsOnlineOnlyItems(url)
    }

    private static func holdsOnlineOnlyItems(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        if info.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        guard info.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return names.contains { holdsOnlineOnlyItems(url.appendingPathComponent($0)) }
    }

    /// Asks the sync client for `url`'s contents. Returns at once; the file stays online-only
    /// until they arrive.
    public static func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Why `url` couldn't be downloaded, if it couldn't.
    public static func downloadError(_ url: URL) -> Error? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]))?.ubiquitousItemDownloadingError
    }

    /// Removes `url`'s local contents, keeping a placeholder; for a folder, everything inside.
    /// Fails for items with changes not yet uploaded. Stops a download in progress.
    public static func freeUpSpace(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    /// Frees up space for each of `urls`, returning those that failed. Pinned items ("Always
    /// keep on this device") can't be evicted: the provider's own unpin frees them, as Finder's
    /// "Free Up Space" does. Can take a while for folders: call off the main thread.
    public static func freeUpSpace(_ urls: [URL]) async -> [(url: URL, error: Error)] {
        var failures: [(url: URL, error: Error)] = []
        for url in urls {
            do {
                try freeUpSpace(url)
            } catch where isNonEvictable(error) {
                do {
                    if try await !ProviderActions.unpin(url) { failures.append((url, error)) }
                } catch {
                    failures.append((url, error))
                }
            } catch {
                failures.append((url, error))
            }
        }
        return failures
    }

    /// Whether eviction failed because the item is pinned (`NSFileProviderError.nonEvictable`,
    /// wrapped in a Cocoa error).
    static func isNonEvictable(_ error: Error) -> Bool {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return [error, underlying].contains {
            $0?.domain == NSFileProviderErrorDomain && $0?.code == NSFileProviderError.Code.nonEvictable.rawValue
        }
    }

    /// The cloud `url` syncs with, by its navigation pane name ("OneDrive - Contoso"); iCloud
    /// Drive for Desktop and Documents kept in iCloud. `nil` outside cloud folders.
    public static func providerName(for url: URL) -> String? {
        if let root = CloudStorage.root(containing: url) { return root.title }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true ? "iCloud Drive" : nil
    }
}
