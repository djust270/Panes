import Foundation

/// Whether macOS lets this app read privacy-protected places (Mail, Messages, Safari data,
/// the Trash, Time Machine, other users' folders). There's no API to ask, so it probes files
/// only readable with Full Disk Access.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// None of the probe files exist (an unusual system), so it can't tell.
        case unknown
    }

    /// Files every user has that only Full Disk Access can open.
    static let probes = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
        "Library/Safari/CloudTabs.db",
    ]

    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        var denied = false
        for probe in probes {
            let fd = open(home.appendingPathComponent(probe).path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return denied ? .denied : .unknown
    }

    /// Whether `error` is macOS privacy protection ("Operation not permitted", EPERM) rather
    /// than ordinary file permissions ("Permission denied", EACCES), which Full Disk Access
    /// doesn't override.
    public static func isPrivacyDenial(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(EPERM) }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isPrivacyDenial(underlying)
    }

    /// Whether `error` is any kind of "no permission to read".
    public static func isPermissionDenial(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSPOSIXErrorDomain:
            return error.code == Int(EPERM) || error.code == Int(EACCES)
        case NSCocoaErrorDomain where error.code == CocoaError.fileReadNoPermission.rawValue:
            return true
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            return isPermissionDenial(underlying)
        }
    }
}
