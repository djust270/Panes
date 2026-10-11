import Foundation

/// A mounted volume, shown as a "drive" under This PC.
public struct MountedVolume: Sendable, Hashable, Identifiable {
    public let url: URL
    public let name: String
    public let isInternal: Bool

    public var id: URL { url }

    public init(url: URL, name: String, isInternal: Bool) {
        self.url = url
        self.name = name
        self.isInternal = isInternal
    }
}

public enum VolumeLister {
    /// Currently mounted, user-visible volumes, in the order `FileManager` reports them.
    public static func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return MountedVolume(
                url: url,
                name: values?.volumeName ?? FileManager.default.displayName(atPath: url.path),
                isInternal: values?.volumeIsInternal ?? false
            )
        }
    }
}
