import Darwin
import Foundation

/// A source item and, for folders, its contents once enumerated.
struct TransferNode {
    let source: URL
    let status: FileStatus
    /// `nil` until enumerated: same-volume moves rename whole folders without looking inside.
    var children: [TransferNode]?
    var totalBytes: Int64
    var totalItems: Int

    var isDirectory: Bool { status.type == .directory }
    var name: String { source.lastPathComponent }
}

/// Copy and move, including folder merges, conflicts, and cross-volume moves.
extension FileOperationTask {
    enum TransferMode {
        case copy
        case move
    }

    private enum RenameOutcome {
        case moved
        case skipped
        /// Source and destination are on different volumes: copy, then delete.
        case crossVolume
    }

    /// Destination paths for copying or moving `sources` into `folder`. Copies into an item's
    /// own folder get Windows' "- Copy" names; moves into the item's own folder are dropped.
    func transfers(of sources: [URL], into folder: URL, copying: Bool) -> [Relocation] {
        let folder = folder.standardizedFileURL
        let exists = FileNaming.existsChecker(in: folder)
        var planned: Set<String> = []

        return sources.compactMap { source in
            let source = source.standardizedFileURL
            let isDirectory = FileStatus(path: source.path)?.type == .directory
            var name = source.lastPathComponent
            if source.deletingLastPathComponent().path == folder.path {
                guard copying else { return nil }
                let hasExtension = FileNaming.hasExtension(source, isDirectory: isDirectory)
                name = FileNaming.copyName(for: name, hasExtension: hasExtension) { candidate in
                    exists(candidate) || planned.contains(candidate.lowercased())
                }
                planned.insert(name.lowercased())
            }
            let destination = folder.appendingPathComponent(name, isDirectory: isDirectory)
            return Relocation(source: source, destination: destination)
        }
    }

    func runTransfer(_ relocations: [Relocation], mode: TransferMode) throws {
        transferRoots = []
        defer {
            if !transferRoots.isEmpty {
                switch mode {
                case .copy: result.inverse = .trash(transferRoots.map(\.destination))
                case .move: result.inverse = .relocate(transferRoots.map(\.reversed))
                }
            }
        }

        var plan: [(node: TransferNode, destination: URL)] = []
        for relocation in relocations {
            try checkpoint()
            let enumerating = shouldEnumerate(relocation, mode: mode)
            guard let node = try makeNode(relocation.source, enumerating: enumerating) else {
                _ = try shouldRetry(after: FileOperationFailure(
                    url: relocation.source,
                    error: POSIXCall.error(ENOENT, relocation.source)
                ))
                continue
            }
            plan.append((node, relocation.destination))
            remainingConflicts += conflictCount(node, at: relocation.destination)
        }

        progress.phase = .running
        report(force: true)
        for (node, destination) in plan {
            if isInside(destination, node.source) {
                _ = try shouldRetry(after: FileOperationFailure(
                    url: node.source,
                    reason: .destinationInsideSource,
                    message: "The destination folder is a subfolder of the source folder."
                ))
                skip(node)
                continue
            }
            let parent = destination.deletingLastPathComponent()
            guard try attempt(parent, {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }) else {
                skip(node)
                continue
            }
            let finalDestination = try transfer(node, to: destination, mode: mode, recordsRoot: true)
            if let finalDestination {
                result.resultingItems.append(finalDestination)
            }
        }
    }

    // MARK: Planning

    private func shouldEnumerate(_ relocation: Relocation, mode: TransferMode) -> Bool {
        guard mode == .move, !environment.forcesCrossVolumeMoves,
              let source = FileStatus(path: relocation.source.path) else { return true }
        return device(ofNearestExisting: relocation.destination.deletingLastPathComponent()) != source.device
    }

    /// Builds the node for `url`, walking folders when `enumerating`. `nil` if `url` is gone.
    /// Folders that can't be listed are left unenumerated; the error surfaces when copying.
    private func makeNode(_ url: URL, enumerating: Bool) throws -> TransferNode? {
        guard let status = FileStatus(path: url.path) else { return nil }
        var node = TransferNode(
            source: url,
            status: status,
            children: nil,
            totalBytes: status.type == .file ? status.size : 0,
            totalItems: 1
        )
        progress.totalItems += 1
        progress.totalBytes += node.totalBytes
        report()

        if enumerating, status.type == .directory, let names = try? childNames(of: url) {
            var children: [TransferNode] = []
            for name in names {
                try checkpoint()
                if let child = try makeNode(url.appendingPathComponent(name), enumerating: true) {
                    children.append(child)
                    node.totalBytes += child.totalBytes
                    node.totalItems += child.totalItems
                }
            }
            node.children = children
        }
        return node
    }

    /// Folder contents in display order, so items are processed predictably.
    private func childNames(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Conflicts `node` will raise at `destination`, as far as can be known before starting.
    private func conflictCount(_ node: TransferNode, at destination: URL) -> Int {
        guard let existing = FileStatus(path: destination.path) else { return 0 }
        guard node.isDirectory, existing.type == .directory else { return 1 }
        return (node.children ?? []).reduce(0) { count, child in
            count + conflictCount(child, at: destination.appendingPathComponent(child.name))
        }
    }

    // MARK: Execution

    /// Copies or moves `node` to `destination`. Returns where the item ended up, or `nil` if
    /// it was skipped. `recordsRoot` adds newly created destinations to the undo record;
    /// it's false inside folders that are themselves recorded.
    private func transfer(
        _ node: TransferNode,
        to destination: URL,
        mode: TransferMode,
        recordsRoot: Bool
    ) throws -> URL? {
        try checkpoint()
        progress.currentName = node.name
        report()

        if node.source.standardizedFileURL.path == destination.standardizedFileURL.path {
            complete(node)
            return destination
        }
        var destination = destination
        var replacing = false
        switch try prepareDestination(for: node, at: destination, mode: mode) {
        case .free:
            break
        case .merged:
            return destination
        case .replace:
            replacing = true
        case .rename(let numbered):
            destination = numbered
        case .skip:
            skip(node)
            return nil
        }
        return try place(node, at: destination, replacing: replacing, mode: mode, recordsRoot: recordsRoot)
    }

    /// Moves or copies `node` to a destination that is free (or being replaced).
    private func place(
        _ node: TransferNode,
        at destination: URL,
        replacing: Bool,
        mode: TransferMode,
        recordsRoot: Bool
    ) throws -> URL? {
        if mode == .move {
            switch try moveByRenaming(node, to: destination, replacing: replacing) {
            case .moved:
                if recordsRoot { transferRoots.append(Relocation(source: node.source, destination: destination)) }
                complete(node)
                return destination
            case .skipped:
                skip(node)
                return nil
            case .crossVolume:
                break
            }
        }

        let copied = node.isDirectory
            ? try copyDirectory(node, to: destination, mode: mode, recordsRoot: recordsRoot)
            : try copyLeaf(node, to: destination, replacing: replacing, mode: mode, recordsRoot: recordsRoot)
        return copied ? destination : nil
    }

    private enum DestinationPlan {
        /// Nothing is in the way.
        case free
        /// A folder was merged into the existing folder; nothing left to do.
        case merged
        case replace
        /// Keep both: use this numbered destination instead.
        case rename(URL)
        case skip
    }

    /// Deals with whatever already exists at `destination`: merges folders, or asks about
    /// the conflict.
    private func prepareDestination(
        for node: TransferNode,
        at destination: URL,
        mode: TransferMode
    ) throws -> DestinationPlan {
        guard let existing = FileStatus(path: destination.path) else { return .free }
        if node.isDirectory, existing.type == .directory {
            try merge(node, into: destination, mode: mode)
            return .merged
        }
        switch try resolveConflict(node, destination: destination, existing: existing) {
        case .replace:
            return .replace
        case .keepBoth:
            let folder = destination.deletingLastPathComponent()
            let name = FileNaming.uniqueName(
                destination.lastPathComponent,
                hasExtension: FileNaming.hasExtension(node.source, isDirectory: node.isDirectory),
                isTaken: FileNaming.existsChecker(in: folder)
            )
            return .rename(folder.appendingPathComponent(name, isDirectory: node.isDirectory))
        case .skip, .cancel:
            return .skip
        }
    }

    private func resolveConflict(
        _ node: TransferNode,
        destination: URL,
        existing: FileStatus
    ) throws -> ConflictResolution {
        let canReplace = !node.isDirectory && existing.type != .directory
        remainingConflicts = max(0, remainingConflicts - 1)

        var resolution: ConflictResolution
        if let conflictPolicy {
            resolution = conflictPolicy
        } else {
            let conflict = FileConflict(
                source: node.status.conflictItem(node.source),
                destination: existing.conflictItem(destination),
                canReplace: canReplace,
                remainingCount: remainingConflicts
            )
            guard let decision: ConflictDecision = ask({ handlers.conflict(conflict, $0) }) else {
                throw CancellationError()
            }
            resolution = decision.resolution
            if decision.appliesToRemaining { conflictPolicy = resolution }
        }

        if resolution == .cancel { throw CancellationError() }
        // A blanket "Replace" can't turn a file into a folder or back.
        if resolution == .replace, !canReplace { resolution = .skip }
        return resolution
    }

    private func moveByRenaming(_ node: TransferNode, to destination: URL, replacing: Bool) throws -> RenameOutcome {
        guard !environment.forcesCrossVolumeMoves,
              device(ofNearestExisting: destination.deletingLastPathComponent()) == node.status.device else {
            return .crossVolume
        }
        var crossesVolumes = false
        let moved = try attempt(node.source) {
            let flags = replacing ? 0 : UInt32(RENAME_EXCL)
            guard renamex_np(node.source.path, destination.path, flags) != 0 else { return }
            if errno == EXDEV {
                crossesVolumes = true
                return
            }
            throw POSIXCall.error(errno, node.source)
        }
        if crossesVolumes { return .crossVolume }
        return moved ? .moved : .skipped
    }

    private func merge(_ node: TransferNode, into destination: URL, mode: TransferMode) throws {
        progress.completedItems += 1
        try transferChildren(of: node, into: destination, mode: mode, recordsRoots: true)
        if mode == .move {
            // Fails, leaving the folder, if anything inside was skipped.
            rmdir(node.source.path)
        }
    }

    private func copyDirectory(
        _ node: TransferNode,
        to destination: URL,
        mode: TransferMode,
        recordsRoot: Bool
    ) throws -> Bool {
        guard try attempt(destination, { try POSIXCall.check(mkdir(destination.path, 0o755), destination) }) else {
            skip(node)
            return false
        }
        if recordsRoot { transferRoots.append(Relocation(source: node.source, destination: destination)) }
        progress.completedItems += 1

        try transferChildren(of: node, into: destination, mode: mode, recordsRoots: false)

        // Applied last so copying the contents doesn't change the folder's dates.
        FileCopier.copyDirectoryMetadata(from: node.source, to: destination)
        if mode == .move {
            rmdir(node.source.path)
        }
        return true
    }

    private func transferChildren(
        of node: TransferNode,
        into destination: URL,
        mode: TransferMode,
        recordsRoots: Bool
    ) throws {
        var children = node.children
        if children == nil {
            var loaded: [TransferNode] = []
            let listed = try attempt(node.source) {
                loaded = try childNames(of: node.source).compactMap { name in
                    try makeNode(node.source.appendingPathComponent(name), enumerating: false)
                }
            }
            guard listed else { return }
            children = loaded
        }
        for child in children ?? [] {
            let target = destination.appendingPathComponent(child.name, isDirectory: child.isDirectory)
            _ = try transfer(child, to: target, mode: mode, recordsRoot: recordsRoots)
        }
    }

    private func copyLeaf(
        _ node: TransferNode,
        to destination: URL,
        replacing: Bool,
        mode: TransferMode,
        recordsRoot: Bool
    ) throws -> Bool {
        // Replacements are copied beside the original and swapped in, so a cancelled or failed
        // copy leaves the original intact.
        let target = replacing
            ? destination.deletingLastPathComponent().appendingPathComponent(".explorer-\(UUID().uuidString).tmp")
            : destination
        let baseBytes = progress.completedBytes

        let copied = try attempt(node.source) {
            progress.completedBytes = baseBytes
            // An online-only file would download while copyfile waits, with no progress and
            // no way to cancel: download it first.
            try downloadIfOnlineOnly(node.source, reportingProvider: true)
            try FileCopier.copy(from: node.source, to: target) { [self] bytes in
                if bytes >= 0 {
                    progress.completedBytes = baseBytes + bytes
                    report()
                }
                do {
                    try checkpoint()
                    return true
                } catch {
                    return false
                }
            }
            if replacing, rename(target.path, destination.path) != 0 {
                let code = errno
                unlink(target.path)
                throw POSIXCall.error(code, destination)
            }
        }

        progress.completedBytes = baseBytes + node.totalBytes
        progress.completedItems += 1
        guard copied else { return false }

        if recordsRoot { transferRoots.append(Relocation(source: node.source, destination: destination)) }
        if mode == .move {
            _ = try attempt(node.source) { try POSIXCall.check(unlink(node.source.path), node.source) }
        }
        return true
    }

    // MARK: Helpers

    /// Counts a node as done without copying it (skipped, or moved in one rename).
    private func skip(_ node: TransferNode) {
        progress.completedItems += node.totalItems
        progress.completedBytes += node.totalBytes
    }

    private func complete(_ node: TransferNode) {
        skip(node)
    }

    private func isInside(_ destination: URL, _ source: URL) -> Bool {
        destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/")
    }

    private func device(ofNearestExisting url: URL) -> dev_t? {
        var current = url.standardizedFileURL
        while true {
            if let status = FileStatus(path: current.path) { return status.device }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}
