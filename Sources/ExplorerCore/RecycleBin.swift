import Foundation

/// The Recycle Bin: the user's Trash folders on every mounted volume, seen as one location.
public enum RecycleBin {
    /// Thrown when the Trash can't be listed. macOS protects `~/.Trash` unless the app has
    /// Full Disk Access.
    public struct AccessDenied: Error {}

    /// `~/.Trash`, plus `.Trashes/<uid>` on each other mounted volume that has one.
    public static func trashDirectories() -> [URL] {
        var directories = [homeTrash]
        for volume in VolumeLister.mountedVolumes() where volume.url.path != "/" {
            let trash = volume.url.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
            if FileStatus(path: trash.path)?.type == .directory {
                directories.append(trash.standardizedFileURL)
            }
        }
        return directories
    }

    static var homeTrash: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
    }

    /// Every trashed item, with its original location where Finder's `.DS_Store` or this
    /// app's `TrashLog` knows it.
    public static func contents(includeHidden: Bool, log: TrashLog = .shared) throws -> [FileItem] {
        var items: [FileItem] = []
        for directory in trashDirectories() {
            do {
                items += try contents(of: directory, includeHidden: includeHidden, log: log)
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                throw AccessDenied()
            } catch where directory != homeTrash {
                // A volume's trash vanishing (ejected mid-listing) shouldn't hide the rest.
                continue
            }
        }
        return items
    }

    static func contents(of directory: URL, includeHidden: Bool, log: TrashLog) throws -> [FileItem] {
        let listed = try DirectoryLoader.loadSync(directory, options: .init(includeHidden: includeHidden))
        let volumeRoot = directory == homeTrash
            ? URL(fileURLWithPath: "/")
            : (try? directory.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(fileURLWithPath: "/")
        let putBack = (try? DSStore(contentsOf: directory.appendingPathComponent(".DS_Store")))?
            .putBackLocations(volumeRoot: volumeRoot) ?? [:]

        return listed.compactMap { item in
            guard item.name != ".DS_Store" else { return nil }
            var item = item
            let added = try? item.url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
            item.trashInfo = TrashInfo(
                originalURL: log.originalURL(forTrashed: item.url) ?? putBack[item.name],
                dateDeleted: added
            )
            return item
        }
    }
}
