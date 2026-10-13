import Foundation
import Testing
@testable import ExplorerCore

@Suite struct DrivesTests {
    private let domain = TemporaryDefaults()
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func volume(
        _ path: String,
        kind: MountedVolume.Kind = .removable,
        root: Bool = false,
        share: String? = nil
    ) -> MountedVolume {
        var volume = MountedVolume(url: URL(fileURLWithPath: path, isDirectory: true),
                                   name: (path as NSString).lastPathComponent, isInternal: root)
        volume.kind = kind
        volume.isRootFileSystem = root
        volume.uuid = share == nil ? "UUID-\(path)" : nil
        volume.remountURL = share.flatMap(URL.init(string:))
        return volume
    }

    private var startup: MountedVolume { volume("/", kind: .local, root: true) }

    private func letters(_ store: DriveStore, _ volumes: [MountedVolume], at date: Date? = nil) -> [String: String] {
        let result = store.letters(for: volumes, now: date ?? now)
        return Dictionary(uniqueKeysWithValues: result.map { ($0.key.lastPathComponent, $0.value) })
    }

    @Test func startupDiskIsCOthersFromDAndNetworkFromZ() {
        let store = DriveStore(defaults: domain.defaults)
        let result = letters(store, [
            startup, volume("/Volumes/USB"), volume("/Volumes/Backup"),
            volume("/Volumes/Media", kind: .network, share: "smb://nas/Media"),
        ])
        #expect(result == ["/": "C", "USB": "D", "Backup": "E", "Media": "Z"])
    }

    @Test func volumesGetTheirLetterBackWhenRemounted() {
        let store = DriveStore(defaults: domain.defaults)
        _ = letters(store, [startup, volume("/Volumes/USB"), volume("/Volumes/Backup")])
        // USB is ejected; a new disk mustn't take its letter while a free one remains.
        let without = letters(store, [startup, volume("/Volumes/Backup"), volume("/Volumes/Camera")])
        #expect(without == ["/": "C", "Backup": "E", "Camera": "F"])
        let back = letters(DriveStore(defaults: domain.defaults), [startup, volume("/Volumes/USB")])
        #expect(back["USB"] == "D")
    }

    @Test func networkSharesAreRememberedByShareNotMountPoint() {
        let store = DriveStore(defaults: domain.defaults)
        _ = letters(store, [startup, volume("/Volumes/Media", kind: .network, share: "smb://dave@nas/Media")])
        let remounted = letters(store, [startup, volume("/Volumes/Media-1", kind: .network, share: "smb://NAS/media")])
        #expect(remounted["Media-1"] == "Z")
    }

    @Test func reusesTheLongestGoneLetterWhenFull() {
        let store = DriveStore(defaults: domain.defaults)
        let disks = DriveStore.allLetters.indices.map { volume("/Volumes/Disk\($0)") }
        for (index, disk) in disks.enumerated() {
            _ = store.letters(for: [startup, disk], now: now.addingTimeInterval(Double(index)))
        }
        // Every letter D…Z is remembered; Disk0 (D:) was seen longest ago.
        let result = letters(store, [startup, volume("/Volumes/New")], at: now.addingTimeInterval(100))
        #expect(result["New"] == "D")
    }

    @Test func mappedDrivesKeepTheirLetterAndReserveIt() throws {
        let store = DriveStore(defaults: domain.defaults)
        let share = try #require(URL(string: "smb://nas/Media"))
        store.map(MappedDrive(shareURL: share, letter: "M", reconnects: true))
        let result = letters(store, [startup, volume("/Volumes/Media", kind: .network, share: "smb://dave@nas/Media")])
        #expect(result["Media"] == "M")

        // An unmounted mapping still holds its letter.
        let disks = letters(store, (0..<10).map { volume("/Volumes/Disk\($0)") })
        #expect(!disks.values.contains("M"))
        #expect(!store.freeLetters(mounted: [startup]).contains("M"))
        #expect(store.freeLetters(mounted: [startup]).first == "Z")

        store.unmap(share)
        #expect(store.mappedDrives.isEmpty)
    }

    @Test func mappingReplacesTheSameShareAndLetter() throws {
        let store = DriveStore(defaults: domain.defaults)
        store.map(MappedDrive(shareURL: try #require(URL(string: "smb://nas/A")), letter: "X", reconnects: false))
        store.map(MappedDrive(shareURL: try #require(URL(string: "smb://user@NAS/a")), letter: "Y", reconnects: true))
        store.map(MappedDrive(shareURL: try #require(URL(string: "smb://nas/B")), letter: "Y", reconnects: true))
        #expect(store.mappedDrives.map(\.shareURL.absoluteString) == ["smb://nas/B"])
    }

    // MARK: Volumes

    @Test func capacityAndType() {
        var drive = volume("/Volumes/USB")
        drive.totalCapacity = 1000
        drive.availableCapacity = 50
        #expect(drive.usedFraction == 0.95)
        #expect(drive.isNearlyFull)
        #expect(drive.typeDescription == "Removable Disk")
        #expect(drive.canEject)
        #expect(!startup.canEject)
        #expect(volume("/Volumes/Media", kind: .network, share: "smb://nas/Media").typeDescription == "Network Drive")
    }

    @Test func listsTheStartupDiskWithCapacity() throws {
        let root = try #require(VolumeLister.mountedVolumes().first { $0.url.path == "/" })
        #expect(root.isRootFileSystem)
        #expect(root.kind == .local)
        #expect((root.totalCapacity ?? 0) > 0)
        #expect(root.usedFraction != nil)
    }

    @Test func thisPCShowsOnlyDriveColumns() {
        var settings = FolderViewSettings(sort: FileItemSort(key: .dateModified), grouping: FileGrouping(key: .type),
                                          columns: [.name, .dateModified, .size, .freeSpace])
        settings = settings.sanitized(for: .drives)
        #expect(settings.columns == [.name, .freeSpace])
        #expect(settings.sort.key == .name)
        #expect(settings.grouping == nil)
        #expect(FolderViewSettings(columns: [.name, .freeSpace]).sanitized(for: .folder).columns == [.name])
        #expect(ExplorerLocation.thisPC.listKind == .drives)
    }

    @Test func sortsDrivesByFreeSpace() {
        func item(_ name: String, free: Int64?) -> FileItem {
            var drive = volume("/Volumes/\(name)")
            drive.availableCapacity = free
            var item = FileItem(url: drive.url, name: name, kind: .directory)
            item.volume = drive
            return item
        }
        let items = [item("A", free: 10), item("B", free: nil), item("C", free: 30)]
        let sorted = FileItemSort(key: .freeSpace, ascending: false).sorted(items)
        #expect(sorted.map(\.name) == ["C", "A", "B"])
        #expect(items[0].typeDescription == "Removable Disk")
    }

    // MARK: Windows paths

    @Test func windowsPathsForSharesAndLetters() throws {
        let file = URL(fileURLWithPath: "/Volumes/Team Files/Q3/report.docx")
        let root = URL(fileURLWithPath: "/Volumes/Team Files", isDirectory: true)
        let share = try #require(URL(string: "smb://dave@nas.local/Team%20Files"))
        #expect(WindowsPath.string(for: file, volumeRoot: root, shareURL: share, driveLetter: "Z")
            == #"\\nas.local\Team Files\Q3\report.docx"#)
        #expect(WindowsPath.string(for: file, volumeRoot: root, shareURL: nil, driveLetter: "E")
            == #"E:\Q3\report.docx"#)
        #expect(WindowsPath.string(for: root, volumeRoot: root, shareURL: nil, driveLetter: "E") == #"E:\"#)
        #expect(WindowsPath.string(for: file, volumeRoot: root, shareURL: nil, driveLetter: nil) == nil)
        let home = URL(fileURLWithPath: "/Users/me/a.txt")
        #expect(WindowsPath.string(for: home, volumeRoot: URL(fileURLWithPath: "/"), shareURL: nil, driveLetter: "C")
            == #"C:\Users\me\a.txt"#)
    }

    @Test func uncAndServerURLs() throws {
        #expect(NetworkPath.uncPath(for: try #require(URL(string: "smb://nas/Media"))) == #"\\nas\Media"#)
        #expect(NetworkPath.uncPath(for: try #require(URL(string: "afp://nas/Media"))) == nil)
        let server = NetworkPath.serverURL(for: try #require(URL(string: "smb://dave@nas/Media")))
        #expect(server?.absoluteString == "smb://nas")
    }
}

@Suite struct NetworkNeighborhoodTests {
    @Test func mergesAdvertisedComputersWithServersOfMountedShares() throws {
        let advertised = [
            NetworkComputer(name: "Dave’s NAS", url: try #require(URL(string: "smb://Daves-NAS.local."))),
            NetworkComputer(name: "Old Mac", url: try #require(URL(string: "afp://old-mac.local"))),
            NetworkComputer(name: "Old Mac", url: try #require(URL(string: "smb://old-mac.local"))),
        ]
        let shares = [
            try #require(URL(string: "smb://smb@10.4.3.210/Media")),
            try #require(URL(string: "smb://smb@10.4.3.210/NAS")),
            try #require(URL(string: "smb://dave@daves-nas.local/Backups")),
        ]
        let computers = NetworkNeighborhood.computers(advertised: advertised, shares: shares)
        #expect(computers.map(\.name) == ["10.4.3.210", "Dave’s NAS", "Old Mac"])
        #expect(computers.map(\.url.absoluteString)
            == ["smb://10.4.3.210", "smb://Daves-NAS.local.", "smb://old-mac.local"])
    }
}
