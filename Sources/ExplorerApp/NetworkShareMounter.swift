import AppKit
import ExplorerCore
import NetFS

/// Connects to network shares typed into the address bar. Mounting goes through NetFS, which
/// shows the system's sign-in dialog (and Keychain option), and a share picker when only a
/// server is given.
@MainActor
enum NetworkShareMounter {
    enum Outcome {
        case mounted(URL)
        case cancelled
        case failed(String)
    }

    /// Mounts `path`'s share (or reuses an existing mount) and returns the folder to open.
    static func mount(_ path: NetworkPath) async -> Outcome {
        if let existing = path.existingMountPoint() {
            return .mounted(path.folder(at: existing))
        }

        let (status, mountPoints) = await mountShare(path.shareURL)
        switch status {
        case 0:
            guard let first = mountPoints.first else { return .failed("The server didn’t report a mount point.") }
            return .mounted(path.folder(at: URL(fileURLWithPath: first, isDirectory: true)))
        case EEXIST:
            // Mounted between our check and the request (or under a slightly different URL).
            if let existing = path.existingMountPoint() { return .mounted(path.folder(at: existing)) }
            return .failed(message(for: status))
        case Int32(userCanceledErr), ECANCELED:
            return .cancelled
        default:
            return .failed(message(for: status))
        }
    }

    private static func mountShare(_ url: URL) async -> (Int32, [String]) {
        await withCheckedContinuation { continuation in
            var requestID: AsyncRequestID?
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil, // mount under /Volumes
                nil,
                nil,
                nil, // default open options: sign-in UI allowed
                nil,
                &requestID,
                DispatchQueue.main
            ) { status, _, mountPoints in
                let paths = (mountPoints as? [String]) ?? []
                continuation.resume(returning: (status, paths))
            }
            // A non-zero return means the request never started, so the block won't run.
            if status != 0 {
                continuation.resume(returning: (status, []))
            }
        }
    }

    private static let messages: [Int32: String] = {
        var messages: [Int32: String] = [
            ENETFSACCOUNTRESTRICTED: "This account isn’t allowed to sign in to the server.",
            ENETFSNOSHARESAVAIL: "The server has no shares available to you.",
            -6003: "The server has no shares available to you.",
            ENETFSPWDNEEDSCHANGE: "The password for this account must be changed.",
            ENETFSNOAUTHMECHSUPP: "The server doesn’t support a compatible sign-in method.",
            ENETFSNOPROTOVERSSUPP: "The server doesn’t support a compatible protocol version.",
            -6004: "The server doesn’t allow guest access.",
            ENOENT: "The share doesn’t exist on the server.",
        ]
        for code in [EAUTH, EACCES, EPERM] {
            messages[code] = "The user name or password is incorrect."
        }
        for code in [EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN] {
            messages[code] = "The server can’t be reached. Check the address and your network connection."
        }
        return messages
    }()

    /// NetFS returns errno values (positive) or OSStatus/NetAuth codes (negative).
    static func message(for status: Int32) -> String {
        if let message = messages[status] { return message }
        if (1...200).contains(status) { return String(cString: strerror(status)) }
        return "The connection failed (error \(status))."
    }
}
