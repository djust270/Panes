import Foundation

/// A network share connected with "Map network drive", remembered so it can be reconnected
/// when the app starts and keep its drive letter.
public struct MappedDrive: Sendable, Hashable, Codable {
    /// The share, e.g. `smb://server/share`.
    public var shareURL: URL
    /// "Z" etc.; `nil` if no letter was chosen.
    public var letter: String?
    /// Windows' "Reconnect at sign-in": here, when Explorer starts.
    public var reconnects: Bool

    public init(shareURL: URL, letter: String?, reconnects: Bool) {
        self.shareURL = shareURL
        self.letter = letter
        self.reconnects = reconnects
    }
}

/// Windows-style drive letters for mounted volumes ("Macintosh HD (C:)"), and mapped network
/// drives. As on Windows, the startup disk is C:, other disks take the first free letter from
/// D: up, and network drives from Z: down unless mapped to a letter; a volume gets the same
/// letter back when it's mounted again, if that letter is still free.
public final class DriveStore {
    private struct Remembered: Codable {
        var letter: String
        var lastSeen: Date
    }

    private struct Storage: Codable {
        var letters: [String: Remembered] = [:]
        var mapped: [MappedDrive] = []
    }

    public static let allLetters = (UnicodeScalar("D").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map { String(Character($0)) } }

    private static let storageKey = "Drives.v1"
    private let defaults: UserDefaults
    private var storage: Storage

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    // MARK: Letters

    /// Letters for `volumes`, by mount point (standardized). Remembers new assignments.
    public func letters(for volumes: [MountedVolume], now: Date = Date()) -> [URL: String] {
        var result: [URL: String] = [:]
        var used: Set<String> = []
        let mappedLetters = Set(storage.mapped.compactMap(\.letter))
        var pending: [MountedVolume] = []

        func take(_ letter: String, for volume: MountedVolume) {
            result[volume.url.standardizedFileURL] = letter
            used.insert(letter)
            if !volume.isRootFileSystem {
                storage.letters[volume.persistentKey] = Remembered(letter: letter, lastSeen: now)
            }
        }

        // The startup disk, then mapped drives, then letters remembered from before.
        for volume in volumes where volume.isRootFileSystem {
            take("C", for: volume)
        }
        for volume in volumes where !volume.isRootFileSystem {
            if let letter = mappedDrive(for: volume)?.letter, !used.contains(letter) {
                take(letter, for: volume)
            } else {
                pending.append(volume)
            }
        }
        var unassigned: [MountedVolume] = []
        for volume in pending {
            if let letter = storage.letters[volume.persistentKey]?.letter,
               !used.contains(letter), !mappedLetters.contains(letter) {
                take(letter, for: volume)
            } else {
                unassigned.append(volume)
            }
        }

        // New volumes: letters nobody remembers first, then those of the longest-gone volumes.
        let present = Set(volumes.map(\.persistentKey))
        let absentByAge = storage.letters.filter { !present.contains($0.key) }
            .sorted { $0.value.lastSeen < $1.value.lastSeen }
        for volume in unassigned {
            let candidates = volume.kind == .network ? Self.allLetters.reversed() : Self.allLetters
            let free = candidates.filter { !used.contains($0) && !mappedLetters.contains($0) }
            let remembered = Set(storage.letters.values.map(\.letter))
            let letter = free.first { !remembered.contains($0) }
                ?? absentByAge.map(\.value.letter).first { free.contains($0) }
            guard let letter else { continue }
            storage.letters = storage.letters.filter { $0.value.letter != letter || present.contains($0.key) }
            take(letter, for: volume)
        }
        persist()
        return result
    }

    /// Letters a new mapped drive can use: not taken by a mounted volume or another mapping,
    /// from Z: down, as in Windows' Map network drive dialog.
    public func freeLetters(mounted: [MountedVolume]) -> [String] {
        let taken = Set(letters(for: mounted).values).union(storage.mapped.compactMap(\.letter))
        return Self.allLetters.reversed().filter { !taken.contains($0) }
    }

    // MARK: Mapped drives

    public var mappedDrives: [MappedDrive] { storage.mapped }

    /// The mapped drive a network volume was mounted from, if any.
    public func mappedDrive(for volume: MountedVolume) -> MappedDrive? {
        guard let remountURL = volume.remountURL else { return nil }
        return storage.mapped.first { NetworkPath.sameShare($0.shareURL, remountURL) }
    }

    /// Adds or replaces the mapping for `drive`'s share.
    public func map(_ drive: MappedDrive) {
        storage.mapped.removeAll { NetworkPath.sameShare($0.shareURL, drive.shareURL) }
        if let letter = drive.letter {
            storage.mapped.removeAll { $0.letter == letter }
            storage.letters = storage.letters.filter { $0.value.letter != letter }
        }
        storage.mapped.append(drive)
        persist()
    }

    /// "Disconnect network drive": forgets the mapping for `shareURL`.
    public func unmap(_ shareURL: URL) {
        storage.mapped.removeAll { NetworkPath.sameShare($0.shareURL, shareURL) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Windows-style paths for "Copy as path": `\\server\share\folder\file` for items on SMB
/// shares, `D:\folder\file` on a volume with a drive letter.
public enum WindowsPath {
    /// - Parameters:
    ///   - volumeRoot: the mount point of the volume holding `url`.
    ///   - shareURL: the share the volume was mounted from, for network volumes.
    ///   - driveLetter: the volume's letter, if drive letters are shown.
    public static func string(for url: URL, volumeRoot: URL, shareURL: URL?, driveLetter: String?) -> String? {
        let item = url.standardizedFileURL.pathComponents
        let root = volumeRoot.standardizedFileURL.pathComponents
        guard item.starts(with: root) else { return nil }
        let relative = Array(item.dropFirst(root.count))
        if let shareURL, let unc = NetworkPath.uncPath(for: shareURL) {
            return ([unc] + relative).joined(separator: #"\"#)
        }
        guard let driveLetter else { return nil }
        return "\(driveLetter):\\" + relative.joined(separator: #"\"#)
    }
}
