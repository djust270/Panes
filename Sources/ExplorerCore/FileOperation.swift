import Foundation

/// A file-system change the user asked for. Each request runs as a `FileOperationTask`, and a
/// finished task reports the request that undoes it (`FileOperationResult.inverse`).
public enum FileOperationRequest: Sendable, Hashable {
    /// Copies items into a folder. Copying an item into its own folder makes "Name - Copy".
    case copy([URL], into: URL)
    /// Moves items into a folder. Items already in that folder are left alone.
    case move([URL], into: URL)
    /// Moves each item to an exact path, creating missing parent folders. Used by undo/redo
    /// of moves and by the Recycle Bin's "Restore".
    case relocate([Relocation])
    /// Moves items to the Trash.
    case trash([URL])
    /// Deletes items permanently. Cannot be undone.
    case delete([URL])
    case rename(URL, to: String)
    /// Creates an empty folder named `name`, or "name (2)" etc. if that is taken.
    case createFolder(in: URL, name: String)
    /// Creates an empty file named `name`, or "name (2).ext" etc. if that is taken.
    case createFile(in: URL, name: String)
    /// Downloads the online-only files among items in cloud folders, and in folders among them.
    case download([URL])
}

/// One item's move to an exact destination path.
public struct Relocation: Sendable, Hashable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    var reversed: Relocation {
        Relocation(source: destination, destination: source)
    }
}

extension FileOperationRequest {
    /// Name used in "Undo …"/"Redo …" menu items.
    public var actionName: String {
        switch self {
        case .copy: return "Copy"
        case .move, .relocate: return "Move"
        case .trash, .delete: return "Delete"
        case .rename: return "Rename"
        case .createFolder: return "New Folder"
        case .createFile: return "New File"
        case .download: return "Download"
        }
    }

    /// The items the request acts on, before it runs.
    public var sourceURLs: [URL] {
        switch self {
        case .copy(let urls, _), .move(let urls, _), .trash(let urls), .delete(let urls), .download(let urls):
            return urls
        case .relocate(let relocations):
            return relocations.map(\.source)
        case .rename(let url, _):
            return [url]
        case .createFolder, .createFile:
            return []
        }
    }
}

/// Two items competing for the same destination path.
public struct FileConflict: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public let url: URL
        public let isDirectory: Bool
        /// `nil` for folders.
        public let size: Int64?
        public let dateModified: Date?

        public init(url: URL, isDirectory: Bool, size: Int64?, dateModified: Date?) {
            self.url = url
            self.isDirectory = isDirectory
            self.size = size
            self.dateModified = dateModified
        }
    }

    /// The item being copied or moved.
    public let source: Item
    /// The item already at the destination.
    public let destination: Item
    /// False when either side is a folder: a file and a folder can't replace each other.
    public let canReplace: Bool
    /// Conflicts known to follow this one, for "Do this for the next N conflicts".
    public let remainingCount: Int

    public init(source: Item, destination: Item, canReplace: Bool, remainingCount: Int) {
        self.source = source
        self.destination = destination
        self.canReplace = canReplace
        self.remainingCount = remainingCount
    }
}

public enum ConflictResolution: Sendable, Hashable {
    /// Overwrite the destination item.
    case replace
    /// Leave both items where they are.
    case skip
    /// Copy or move under a numbered name, e.g. "report (2).txt".
    case keepBoth
    /// Stop the whole operation.
    case cancel
}

public struct ConflictDecision: Sendable, Hashable {
    public var resolution: ConflictResolution
    /// Apply the same resolution to every later conflict without asking.
    public var appliesToRemaining: Bool

    public init(_ resolution: ConflictResolution, appliesToRemaining: Bool = false) {
        self.resolution = resolution
        self.appliesToRemaining = appliesToRemaining
    }
}

/// An item the operation could not process.
public struct FileOperationFailure: Error, Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// Rename/create: the name is already taken.
        case alreadyExists
        /// Rename/create: the name isn't allowed.
        case invalidName
        /// Copy/move of a folder into itself or one of its subfolders.
        case destinationInsideSource
        /// Trash isn't available for the item's volume.
        case trashUnavailable
        case other
    }

    public let url: URL
    public let reason: Reason
    public let message: String

    public init(url: URL, reason: Reason = .other, message: String) {
        self.url = url
        self.reason = reason
        self.message = message
    }

    init(url: URL, error: Error) {
        let nsError = error as NSError
        let reason: Reason
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.featureUnsupported.rawValue {
            reason = .trashUnavailable
        } else if Self.posixCode(of: nsError) == EEXIST {
            reason = .alreadyExists
        } else {
            reason = .other
        }
        self.init(url: url, reason: reason, message: nsError.localizedDescription)
    }

    private static func posixCode(of error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return posixCode(of: underlying)
        }
        return nil
    }
}

public enum FailureResolution: Sendable, Hashable {
    case retry
    case skip
    /// Skip this and every later failing item without asking.
    case skipAll
    case cancel
}

public struct FileOperationProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// Walking the source items to find out how much work there is.
        case preparing
        case running
        case finished
    }

    public var phase: Phase = .preparing
    public var totalItems = 0
    public var completedItems = 0
    public var totalBytes: Int64 = 0
    public var completedBytes: Int64 = 0
    /// Name of the item being processed.
    public var currentName: String?
    /// While a copy waits for an online-only file to download: where from ("OneDrive - Contoso").
    public var downloadingFrom: String?

    public init() {}

    /// 0…1, by bytes when there is data to copy, otherwise by items.
    public var fractionCompleted: Double {
        if phase == .finished { return 1 }
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return min(1, Double(completedItems) / Double(totalItems)) }
        return 0
    }
}

public struct FileOperationResult: Sendable, Hashable {
    /// True if the user cancelled before the operation finished.
    public var wasCancelled = false
    /// Items that were skipped because of errors.
    public var failures: [FileOperationFailure] = []
    /// Top-level items now at their destination (copies, moved items, renamed/created items),
    /// for selecting after a paste.
    public var resultingItems: [URL] = []
    /// The request that reverses what this operation did, or `nil` if it did nothing or
    /// cannot be undone (permanent delete).
    public var inverse: FileOperationRequest?

    public init() {}
}

/// Callbacks from a running `FileOperationTask`. All are called on the task's worker thread.
public struct FileOperationHandlers: Sendable {
    /// Progress updates, throttled to roughly 20 per second.
    public var progress: @Sendable (FileOperationProgress) -> Void
    /// Asks how to resolve a conflict. Call the reply closure exactly once, from any thread;
    /// the task waits for it (or for cancellation).
    public var conflict: @Sendable (FileConflict, @escaping @Sendable (ConflictDecision) -> Void) -> Void
    /// Asks what to do about an item that failed. Same reply rules as `conflict`.
    public var failure: @Sendable (FileOperationFailure, @escaping @Sendable (FailureResolution) -> Void) -> Void

    public init(
        progress: @escaping @Sendable (FileOperationProgress) -> Void = { _ in },
        conflict: @escaping @Sendable (FileConflict, @escaping @Sendable (ConflictDecision) -> Void) -> Void = {
            $1(ConflictDecision(.skip))
        },
        failure: @escaping @Sendable (FileOperationFailure, @escaping @Sendable (FailureResolution) -> Void) -> Void = {
            $1(.skip)
        }
    ) {
        self.progress = progress
        self.conflict = conflict
        self.failure = failure
    }
}

/// System services a task uses, replaceable in tests.
public struct FileOperationEnvironment: Sendable {
    /// Moves an item to the Trash and returns where it ended up.
    public var trash: @Sendable (URL) throws -> URL
    /// Testing hook: treat every move as crossing volumes (copy, then delete the source).
    var forcesCrossVolumeMoves = false
    /// Online-only files in cloud folders: whether a file is one, asking its sync client for
    /// it, why it couldn't come, and stopping it (`CloudSync`).
    var isOnlineOnly: @Sendable (URL) -> Bool = { CloudSync.isOnlineOnly($0) }
    var startDownloading: @Sendable (URL) throws -> Void = { try CloudSync.startDownloading($0) }
    var downloadError: @Sendable (URL) -> Error? = { CloudSync.downloadError($0) }
    var stopDownloading: @Sendable (URL) -> Void = { try? CloudSync.freeUpSpace($0) }
    /// Whether an item can't be moved to the Trash for being online-only (`CloudSync`).
    var hasOnlineOnlyContents: @Sendable (URL) -> Bool = { CloudSync.hasOnlineOnlyContents($0) }

    public init(trash: @escaping @Sendable (URL) throws -> URL) {
        self.trash = trash
    }

    public static let live = FileOperationEnvironment { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let trashed = resulting as URL? else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url])
        }
        TrashLog.shared.record(original: url, trashed: trashed)
        return trashed
    }
}
