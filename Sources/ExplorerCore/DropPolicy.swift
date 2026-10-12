import Foundation

/// Decides whether dropping or pasting items into a folder copies or moves them, following
/// Windows: same volume moves, another volume copies, and modifier keys override.
public enum DropPolicy {
    public enum Intent: Sendable {
        /// No modifier: decide by volume.
        case automatic
        /// Ctrl (Windows) or Option (Mac) held.
        case forceCopy
        /// Shift (Windows) or Command (Mac) held.
        case forceMove
    }

    public enum Operation: Sendable, Equatable {
        case copy
        case move
    }

    /// The operation for dropping `sources` into `folder`, or `nil` if the drop makes no sense
    /// (a folder into itself, or moving items to where they already are).
    public static func operation(for sources: [URL], into folder: URL, intent: Intent) -> Operation? {
        guard !sources.isEmpty else { return nil }
        let folderPath = folder.standardizedFileURL.path
        for source in sources {
            let path = source.standardizedFileURL.path
            if folderPath == path || folderPath.hasPrefix(path + "/") { return nil }
        }

        let operation: Operation
        switch intent {
        case .forceCopy:
            operation = .copy
        case .forceMove:
            operation = .move
        case .automatic:
            let destinationDevice = FileStatus(path: folderPath)?.device
            let sameVolume = sources.allSatisfy { FileStatus(path: $0.path)?.device == destinationDevice }
            operation = sameVolume ? .move : .copy
        }

        let allAlreadyThere = sources.allSatisfy {
            $0.standardizedFileURL.deletingLastPathComponent().path == folderPath
        }
        if operation == .move, allAlreadyThere { return nil }
        return operation
    }
}
