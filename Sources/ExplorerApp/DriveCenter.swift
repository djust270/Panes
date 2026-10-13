import AppKit
import ExplorerCore

/// The app's drives: mounted volumes with their optional drive letters, mapped network
/// drives, Eject, and a notification whenever a volume is mounted, unmounted or renamed.
@MainActor
enum DriveCenter {
    static let didChangeNotification = Notification.Name("DriveCenterDidChange")
    /// Posted with the unmounted volume's URL as the object.
    static let didUnmountNotification = Notification.Name("DriveCenterDidUnmount")

    static let store = DriveStore()
    private static var observers: [NSObjectProtocol] = []

    /// Starts following mounts and unmounts. Called once at launch.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let unmounted = notification.name == NSWorkspace.didUnmountNotification
                MainActor.assumeIsolated {
                    if unmounted, let volume {
                        NotificationCenter.default.post(name: didUnmountNotification, object: volume)
                    }
                    NotificationCenter.default.post(name: didChangeNotification, object: nil)
                }
            })
        }
        showsLetters = AppSettings.showsDriveLetters
        observers.append(AppSettings.observe {
            guard AppSettings.showsDriveLetters != showsLetters else { return }
            showsLetters = AppSettings.showsDriveLetters
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        })
    }

    /// Mapped drives set to reconnect, mounted without asking (as Windows does at sign-in).
    static func reconnectMappedDrives() {
        for drive in store.mappedDrives where drive.reconnects {
            guard let path = NetworkPath(drive.shareURL.absoluteString),
                  path.existingMountPoint() == nil else { continue }
            Task { _ = await NetworkShareMounter.mount(path, signIn: .silent) }
        }
    }

    /// Remembers a mapped drive and refreshes This PC.
    static func map(_ drive: MappedDrive) {
        store.map(drive)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// The drive-letter setting as last seen, to notice when it changes.
    private static var showsLetters = false

    /// Calls `body` after every change, until the returned token is released.
    static func observe(_ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    // MARK: Volumes

    /// Mounted volumes with their letters (when shown), for This PC and the navigation pane.
    static func volumes() -> [(volume: MountedVolume, letter: String?)] {
        let volumes = VolumeLister.mountedVolumes()
        let letters = AppSettings.showsDriveLetters ? store.letters(for: volumes) : [:]
        return volumes.map { ($0, letters[$0.url.standardizedFileURL]) }
    }

    /// "Macintosh HD (C:)" with drive letters on, otherwise the volume's name.
    static func displayName(_ volume: MountedVolume, letter: String?) -> String {
        letter.map { "\(volume.name) (\($0):)" } ?? volume.name
    }

    /// This PC's items: one per volume, carrying its capacity for the tiles and columns.
    static func items() -> [FileItem] {
        volumes().map { volume, letter in
            var item = FileItem(
                url: volume.url.standardizedFileURL,
                name: displayName(volume, letter: letter),
                kind: .directory
            )
            item.volume = volume
            return item
        }
    }

    /// The letter of the volume holding `url`, if drive letters are shown.
    static func letter(forVolumeAt root: URL) -> String? {
        guard AppSettings.showsDriveLetters else { return nil }
        return volumes().first { $0.volume.url.standardizedFileURL == root.standardizedFileURL }?.letter
    }

    // MARK: Eject

    /// Ejects a disk or disconnects a network share (forgetting its mapping, as Windows'
    /// "Disconnect" does). Returns an error message on failure.
    static func eject(_ volume: MountedVolume) async -> String? {
        let options: FileManager.UnmountOptions = volume.kind == .network ? [] : [.allPartitionsAndEjectDisk]
        let error: String? = await withCheckedContinuation { continuation in
            FileManager.default.unmountVolume(at: volume.url, options: options) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        if error == nil, let mapped = store.mappedDrive(for: volume) {
            store.unmap(mapped.shareURL)
        }
        return error
    }

    /// Ejects the volume at `url`, telling the user (on `window`) if it's in use.
    static func eject(at url: URL, from window: NSWindow?) {
        let volume = VolumeLister.volume(at: url)
        Task {
            guard let message = await eject(volume) else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = volume.kind == .network
                ? "Couldn’t disconnect “\(volume.name)”"
                : "Problem ejecting “\(volume.name)”"
            alert.informativeText = "This device is currently in use. Close any programs or windows that might be "
                + "using it, and then try again.\n\n\(message)"
            if let window {
                _ = await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}
