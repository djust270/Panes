import Darwin
import Foundation

/// `lstat` results the operation engine needs.
struct FileStatus {
    enum ObjectType {
        case file
        case directory
        case symlink
    }

    let type: ObjectType
    let size: Int64
    let dateModified: Date
    let device: dev_t

    /// `nil` if nothing exists at `path`. Symlinks are reported, not followed.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        default: type = .file
        }
        size = Int64(info.st_size)
        dateModified = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        device = info.st_dev
    }

    func conflictItem(_ url: URL) -> FileConflict.Item {
        FileConflict.Item(
            url: url,
            isDirectory: type == .directory,
            size: type == .directory ? nil : size,
            dateModified: dateModified
        )
    }
}

/// POSIX calls wrapped to throw Cocoa-style errors with a readable description.
enum POSIXCall {
    static func check(_ result: Int32, _ url: URL) throws {
        guard result != 0 else { return }
        throw error(errno, url)
    }

    static func error(_ code: Int32, _ url: URL) -> Error {
        let posix = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        let cocoaCode: CocoaError.Code = switch code {
        case ENOENT, ENOTDIR: .fileNoSuchFile
        case EACCES, EPERM: .fileWriteNoPermission
        case EEXIST: .fileWriteFileExists
        case ENOSPC: .fileWriteOutOfSpace
        case EROFS: .fileWriteVolumeReadOnly
        default: .fileWriteUnknown
        }
        return CocoaError(cocoaCode, userInfo: [NSURLErrorKey: url, NSUnderlyingErrorKey: posix])
    }
}

/// Copies single files and symlinks with `copyfile(3)`: clones on APFS, otherwise copies data,
/// extended attributes and ACLs (as AppleDouble files on exFAT/SMB), with progress and abort.
enum FileCopier {
    /// Called with the bytes copied so far (or -1 between stages); return false to abort.
    typealias ProgressHandler = (Int64) -> Bool

    private final class CallbackContext {
        let handler: ProgressHandler
        var aborted = false

        init(handler: @escaping ProgressHandler) {
            self.handler = handler
        }
    }

    /// Copies `source` to `destination`, which must not exist. Removes the partial copy and
    /// throws `CancellationError` if `progress` returns false, or the POSIX error on failure.
    static func copy(from source: URL, to destination: URL, progress: @escaping ProgressHandler) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXCall.error(ENOMEM, source) }
        defer { copyfile_state_free(state) }

        let context = CallbackContext(handler: progress)
        let callback: copyfile_callback_t = { what, stage, state, _, _, info in
            guard let info else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            var copied: off_t = -1
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            } else if stage == COPYFILE_ERR {
                // Data errors are fatal; metadata the destination can't hold (ACLs, some
                // xattrs) is skipped, as Finder does.
                return what == COPYFILE_COPY_DATA ? COPYFILE_QUIT : COPYFILE_SKIP
            } else if stage != COPYFILE_START {
                return COPYFILE_CONTINUE
            }
            guard context.handler(Int64(copied)) else {
                context.aborted = true
                return COPYFILE_QUIT
            }
            return COPYFILE_CONTINUE
        }

        withExtendedLifetime(context) {
            let callbackPointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
            _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer)
            _ = copyfile_state_set(
                state,
                UInt32(COPYFILE_STATE_STATUS_CTX),
                UnsafeRawPointer(Unmanaged.passUnretained(context).toOpaque())
            )
        }

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let result = withExtendedLifetime(context) {
            copyfile(source.path, destination.path, state, flags)
        }
        guard result != 0 else { return }

        let code = errno
        if code != EEXIST {
            unlink(destination.path)
        }
        if context.aborted { throw CancellationError() }
        throw POSIXCall.error(code, source)
    }

    /// Copies permissions, dates, flags, extended attributes and ACLs from one folder to
    /// another. Best effort: file systems that can't hold some of it keep what they can.
    static func copyDirectoryMetadata(from source: URL, to destination: URL) {
        _ = copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
    }
}
