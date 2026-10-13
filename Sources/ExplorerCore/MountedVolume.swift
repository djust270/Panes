import Foundation

/// A mounted volume, shown as a "drive" under This PC.
public struct MountedVolume: Sendable, Hashable, Identifiable {
    /// What Windows' Type column calls a drive.
    public enum Kind: Sendable, Hashable {
        /// The startup disk and other internal disks.
        case local
        /// External disks, card readers, disk images.
        case removable
        /// SMB, AFP and NFS shares.
        case network
    }

    public let url: URL
    public let name: String
    public let isInternal: Bool
    public var kind: Kind = .local
    /// Bytes; `nil` if the file system doesn't say.
    public var totalCapacity: Int64?
    public var availableCapacity: Int64?
    /// e.g. "APFS", "SMB (NTFS)", "ExFAT".
    public var fileSystem: String = ""
    public var isRootFileSystem = false
    public var isEjectable = false
    public var isReadOnly = false
    /// The share a network volume was mounted from, e.g. `smb://user@server/share`.
    public var remountURL: URL?
    public var uuid: String?

    public var id: URL { url }

    public init(url: URL, name: String, isInternal: Bool) {
        self.url = url
        self.name = name
        self.isInternal = isInternal
    }

    /// Network shares, removable and ejectable disks can be ejected; the internal disks can't.
    public var canEject: Bool {
        !isRootFileSystem && (kind != .local || isEjectable)
    }

    /// Used space as a fraction of capacity (0…1), for the capacity bar.
    public var usedFraction: Double? {
        guard let totalCapacity, let availableCapacity, totalCapacity > 0 else { return nil }
        return min(1, max(0, Double(totalCapacity - availableCapacity) / Double(totalCapacity)))
    }

    /// Windows turns the capacity bar red when a drive is more than 90% full.
    public var isNearlyFull: Bool { (usedFraction ?? 0) > 0.9 }

    /// Windows' Type column: "Local Disk", "Removable Disk", "Network Drive".
    public var typeDescription: String {
        switch kind {
        case .local: return "Local Disk"
        case .removable: return "Removable Disk"
        case .network: return "Network Drive"
        }
    }

    /// A key that survives remounting, for remembering drive letters: the volume UUID, or the
    /// share for network volumes, or the mount point.
    public var persistentKey: String {
        if let remountURL { return "share:" + NetworkPath.shareKey(remountURL) }
        if let uuid { return "uuid:" + uuid }
        return "path:" + url.standardizedFileURL.path
    }

    /// "120 GB free of 500 GB", under the capacity bar.
    public var capacityText: String {
        guard let totalCapacity else { return "" }
        let total = FileSizeFormat.string(for: totalCapacity)
        guard let availableCapacity else { return total }
        return "\(FileSizeFormat.string(for: availableCapacity)) free of \(total)"
    }
}

public enum VolumeLister {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeURLForRemountingKey,
        .volumeUUIDStringKey,
    ]

    /// Currently mounted, user-visible volumes, in the order `FileManager` reports them.
    public static func mountedVolumes() -> [MountedVolume] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }
        return urls.map(volume(at:))
    }

    /// The volume mounted at `url` (a mount point).
    public static func volume(at url: URL) -> MountedVolume {
        let values = try? url.resourceValues(forKeys: Set(keys))
        var volume = MountedVolume(
            url: url,
            name: values?.volumeName ?? FileManager.default.displayName(atPath: url.path),
            isInternal: values?.volumeIsInternal ?? false
        )
        let isLocal = values?.volumeIsLocal ?? true
        let isRemovable = values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
        volume.isRootFileSystem = values?.volumeIsRootFileSystem ?? (url.path == "/")
        if !isLocal {
            volume.kind = .network
        } else if isRemovable || values?.volumeIsInternal == false {
            volume.kind = volume.isRootFileSystem ? .local : .removable
        }
        volume.isEjectable = values?.volumeIsEjectable ?? false
        volume.isReadOnly = values?.volumeIsReadOnly ?? false
        volume.totalCapacity = values?.volumeTotalCapacity.map(Int64.init)
        // "Important usage" counts purgeable space as free, as Finder does. Only APFS has it
        // (asking other volumes logs errors and returns 0); the plain figure elsewhere.
        var important: Int64 = 0
        if isLocal, values?.volumeLocalizedFormatDescription?.hasPrefix("APFS") == true {
            important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
        }
        volume.availableCapacity = important > 0 ? important : values?.volumeAvailableCapacity.map(Int64.init)
        volume.fileSystem = values?.volumeLocalizedFormatDescription ?? ""
        volume.remountURL = values?.volumeURLForRemounting
        volume.uuid = values?.volumeUUIDString
        return volume
    }

    /// The volume holding `url`, if it can be found among the mounted volumes.
    public static func volume(containing url: URL) -> MountedVolume? {
        guard let root = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return volume(at: root)
    }
}
