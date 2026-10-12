import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FileOperationTaskTests {
    // MARK: Copy

    @Test func copiesFilesAndFoldersIntoAnotherFolder() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/a.txt", contents: "alpha")
        try temp.createFile(at: "src/Folder/inner/b.txt", contents: "beta")
        try temp.createDirectory("dst")

        let progress = Recorder<FileOperationProgress>()
        let result = await perform(
            .copy([temp.path("src/a.txt"), temp.path("src/Folder")], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(progress: { progress.append($0) })
        )

        #expect(try temp.contents("dst/a.txt") == "alpha")
        #expect(try temp.contents("dst/Folder/inner/b.txt") == "beta")
        #expect(temp.exists("src/a.txt"))
        #expect(result.failures.isEmpty)
        #expect(!result.wasCancelled)
        #expect(result.resultingItems.map(\.lastPathComponent) == ["a.txt", "Folder"])
        #expect(result.inverse == .trash([temp.path("dst/a.txt"), temp.path("dst/Folder/")].map(\.standardizedFileURL)))

        let last = try #require(progress.items.last)
        #expect(last.phase == .finished)
        #expect(last.totalItems == 4) // a.txt, Folder, inner, b.txt
        #expect(last.totalBytes == 9)
        #expect(last.completedBytes == 9)
    }

    @Test func copyingIntoTheSameFolderMakesCopyNames() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt", contents: "x")
        try temp.createDirectory("Photos")

        _ = await perform(.copy([temp.path("a.txt"), temp.path("Photos")], into: temp.url), in: temp)
        _ = await perform(.copy([temp.path("a.txt")], into: temp.url), in: temp)

        #expect(temp.exists("a - Copy.txt"))
        #expect(temp.exists("a - Copy (2).txt"))
        #expect(temp.exists("Photos - Copy"))
    }

    @Test func refusesToCopyAFolderIntoItself() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "Folder/sub/a.txt")

        let result = await perform(.copy([temp.path("Folder")], into: temp.path("Folder/sub")), in: temp)

        #expect(result.failures.map(\.reason) == [.destinationInsideSource])
        #expect(!temp.exists("Folder/sub/Folder"))
    }

    @Test func preservesModificationDates() async throws {
        let temp = try TemporaryDirectory()
        let file = try temp.createFile(at: "src/Folder/a.txt", contents: "x")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: temp.path("src/Folder").path)
        try temp.createDirectory("dst")

        _ = await perform(.copy([temp.path("src/Folder")], into: temp.path("dst")), in: temp)

        for copied in ["dst/Folder", "dst/Folder/a.txt"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: temp.path(copied).path)
            #expect(attributes[.modificationDate] as? Date == old)
        }
    }

    @Test func copiesSymlinksAsLinks() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/target.txt")
        try FileManager.default.createSymbolicLink(
            atPath: temp.path("src/link").path,
            withDestinationPath: "target.txt"
        )
        try temp.createDirectory("dst")

        _ = await perform(.copy([temp.path("src/link")], into: temp.path("dst")), in: temp)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: temp.path("dst/link").path) == "target.txt")
    }

    // MARK: Conflicts

    @Test(arguments: [ConflictResolution.replace, .skip, .keepBoth])
    func resolvesFileConflicts(resolution: ConflictResolution) async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/a.txt", contents: "new")
        try temp.createFile(at: "dst/a.txt", contents: "old")

        let conflicts = Recorder<FileConflict>()
        let result = await perform(
            .copy([temp.path("src/a.txt")], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(conflict: { conflict, reply in
                conflicts.append(conflict)
                reply(ConflictDecision(resolution))
            })
        )

        let conflict = try #require(conflicts.items.first)
        #expect(conflict.canReplace)
        #expect(conflict.source.size == 3)
        #expect(conflict.destination.url.lastPathComponent == "a.txt")
        switch resolution {
        case .replace:
            #expect(try temp.contents("dst/a.txt") == "new")
            #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path("dst").path) == ["a.txt"])
        case .skip:
            #expect(try temp.contents("dst/a.txt") == "old")
            #expect(result.inverse == nil)
        case .keepBoth:
            #expect(try temp.contents("dst/a.txt") == "old")
            #expect(try temp.contents("dst/a (2).txt") == "new")
            #expect(result.resultingItems.map(\.lastPathComponent) == ["a (2).txt"])
        case .cancel:
            break
        }
    }

    @Test func mergesFoldersAndAsksOnlyAboutClashingFiles() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/Folder/same.txt", contents: "new")
        try temp.createFile(at: "src/Folder/added.txt", contents: "added")
        try temp.createFile(at: "src/Folder/sub/deep.txt", contents: "new")
        try temp.createFile(at: "dst/Folder/same.txt", contents: "old")
        try temp.createFile(at: "dst/Folder/kept.txt", contents: "kept")
        try temp.createFile(at: "dst/Folder/sub/deep.txt", contents: "old")

        let conflicts = Recorder<FileConflict>()
        let result = await perform(
            .copy([temp.path("src/Folder")], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(conflict: { conflict, reply in
                conflicts.append(conflict)
                reply(ConflictDecision(.replace))
            })
        )

        #expect(conflicts.items.map(\.remainingCount).sorted() == [0, 1])
        #expect(try temp.contents("dst/Folder/same.txt") == "new")
        #expect(try temp.contents("dst/Folder/sub/deep.txt") == "new")
        #expect(try temp.contents("dst/Folder/added.txt") == "added")
        #expect(try temp.contents("dst/Folder/kept.txt") == "kept")

        // Undo removes only what the copy added or replaced, not the merged-into folder.
        guard case .trash(let undone) = result.inverse else {
            Issue.record("Expected a trash inverse")
            return
        }
        #expect(Set(undone.map(\.lastPathComponent)) == ["same.txt", "added.txt", "deep.txt"])
    }

    @Test func applyingADecisionToRemainingConflictsAsksOnce() async throws {
        let temp = try TemporaryDirectory()
        for name in ["a", "b", "c"] {
            try temp.createFile(at: "src/\(name).txt", contents: "new")
            try temp.createFile(at: "dst/\(name).txt", contents: "old")
        }

        let conflicts = Recorder<FileConflict>()
        _ = await perform(
            .copy(["a", "b", "c"].map { temp.path("src/\($0).txt") }, into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(conflict: { conflict, reply in
                conflicts.append(conflict)
                reply(ConflictDecision(.keepBoth, appliesToRemaining: true))
            })
        )

        #expect(conflicts.items.count == 1)
        #expect(conflicts.items.first?.remainingCount == 2)
        for name in ["a", "b", "c"] {
            #expect(try temp.contents("dst/\(name) (2).txt") == "new")
        }
    }

    @Test func fileAndFolderWithTheSameNameCannotReplaceEachOther() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/thing", contents: "file")
        try temp.createDirectory("dst/thing")

        let conflicts = Recorder<FileConflict>()
        _ = await perform(
            .copy([temp.path("src/thing")], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(conflict: { conflict, reply in
                conflicts.append(conflict)
                reply(ConflictDecision(.replace))
            })
        )

        #expect(conflicts.items.first?.canReplace == false)
        #expect(FileStatus(path: temp.path("dst/thing").path)?.type == .directory)
    }

    @Test func cancellingFromAConflictStopsTheOperation() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/a.txt")
        try temp.createFile(at: "src/b.txt")
        try temp.createFile(at: "dst/a.txt")

        let result = await perform(
            .copy([temp.path("src/a.txt"), temp.path("src/b.txt")], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(conflict: { $1(ConflictDecision(.cancel)) })
        )

        #expect(result.wasCancelled)
        #expect(!temp.exists("dst/b.txt"))
    }

    // MARK: Move

    @Test(arguments: [false, true])
    func movesAndUndoes(crossVolume: Bool) async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/a.txt", contents: "alpha")
        try temp.createFile(at: "src/Folder/inner/b.txt", contents: "beta")
        try temp.createDirectory("dst")

        let result = await perform(
            .move([temp.path("src/a.txt"), temp.path("src/Folder")], into: temp.path("dst")),
            in: temp,
            crossVolume: crossVolume
        )

        #expect(try temp.contents("dst/a.txt") == "alpha")
        #expect(try temp.contents("dst/Folder/inner/b.txt") == "beta")
        #expect(!temp.exists("src/a.txt"))
        #expect(!temp.exists("src/Folder"))

        let inverse = try #require(result.inverse)
        let undo = await perform(inverse, in: temp, crossVolume: crossVolume)
        #expect(try temp.contents("src/a.txt") == "alpha")
        #expect(try temp.contents("src/Folder/inner/b.txt") == "beta")
        #expect(!temp.exists("dst/a.txt"))
        #expect(!temp.exists("dst/Folder"))

        // Redo is the undo's own inverse.
        let redo = try #require(undo.inverse)
        _ = await perform(redo, in: temp, crossVolume: crossVolume)
        #expect(temp.exists("dst/Folder/inner/b.txt"))
    }

    @Test func movingIntoTheSameFolderDoesNothing() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt")

        let result = await perform(.move([temp.path("a.txt")], into: temp.url), in: temp)

        #expect(temp.exists("a.txt"))
        #expect(result.inverse == nil)
        #expect(result.failures.isEmpty)
    }

    @Test func crossVolumeMoveKeepsSkippedItemsAtTheSource() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/Folder/clash.txt", contents: "new")
        try temp.createFile(at: "src/Folder/free.txt", contents: "free")
        try temp.createFile(at: "dst/Folder/clash.txt", contents: "old")

        _ = await perform(
            .move([temp.path("src/Folder")], into: temp.path("dst")),
            in: temp,
            crossVolume: true,
            handlers: FileOperationHandlers(conflict: { $1(ConflictDecision(.skip)) })
        )

        #expect(try temp.contents("dst/Folder/free.txt") == "free")
        #expect(try temp.contents("dst/Folder/clash.txt") == "old")
        #expect(try temp.contents("src/Folder/clash.txt") == "new")
        #expect(!temp.exists("src/Folder/free.txt"))
    }

    @Test func relocateCreatesMissingParents() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt", contents: "x")

        let destination = temp.path("deep/er/b.txt")
        let relocation = Relocation(source: temp.path("a.txt"), destination: destination)
        let result = await perform(.relocate([relocation]), in: temp)

        #expect(try temp.contents("deep/er/b.txt") == "x")
        #expect(result.inverse == .relocate([Relocation(source: destination, destination: temp.path("a.txt"))]))
    }

    // MARK: Trash and delete

    @Test func trashesAndRestores() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "src/a.txt", contents: "alpha")
        try temp.createFile(at: "src/Folder/b.txt")

        let result = await perform(.trash([temp.path("src/a.txt"), temp.path("src/Folder")]), in: temp)
        #expect(!temp.exists("src/a.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path(".trash").path).count == 2)

        let inverse = try #require(result.inverse)
        _ = await perform(inverse, in: temp)
        #expect(try temp.contents("src/a.txt") == "alpha")
        #expect(temp.exists("src/Folder/b.txt"))
    }

    @Test func deletesPermanently() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "Folder/sub/a.txt")
        try temp.createFile(at: "Folder/.hidden")
        try temp.createFile(at: "b.txt")

        let progress = Recorder<FileOperationProgress>()
        let result = await perform(
            .delete([temp.path("Folder"), temp.path("b.txt")]),
            in: temp,
            handlers: FileOperationHandlers(progress: { progress.append($0) })
        )

        #expect(!temp.exists("Folder"))
        #expect(!temp.exists("b.txt"))
        #expect(result.inverse == nil)
        #expect(progress.items.last?.totalItems == 5)
        #expect(progress.items.last?.completedItems == 5)
    }

    // MARK: Rename and create

    @Test func renamesAndUndoes() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "old.txt")

        let result = await perform(.rename(temp.path("old.txt"), to: "new.txt"), in: temp)
        #expect(temp.exists("new.txt"))
        #expect(!temp.exists("old.txt"))
        #expect(result.resultingItems == [temp.path("new.txt")])

        _ = await perform(try #require(result.inverse), in: temp)
        #expect(temp.exists("old.txt"))
    }

    @Test func renameReportsTakenAndInvalidNames() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt", contents: "a")
        try temp.createFile(at: "b.txt", contents: "b")

        let taken = await perform(.rename(temp.path("a.txt"), to: "b.txt"), in: temp)
        #expect(taken.failures.map(\.reason) == [.alreadyExists])
        #expect(try temp.contents("b.txt") == "b")

        let invalid = await perform(.rename(temp.path("a.txt"), to: "a/b"), in: temp)
        #expect(invalid.failures.map(\.reason) == [.invalidName])
    }

    @Test func renameCanChangeOnlyTheCase() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "readme.txt")

        let result = await perform(.rename(temp.path("readme.txt"), to: "README.txt"), in: temp)

        #expect(result.failures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["README.txt"])
    }

    @Test func createsNumberedFoldersAndFiles() async throws {
        let temp = try TemporaryDirectory()

        let first = await perform(.createFolder(in: temp.url, name: FileNaming.newFolderName), in: temp)
        let second = await perform(.createFolder(in: temp.url, name: FileNaming.newFolderName), in: temp)
        let file = await perform(.createFile(in: temp.url, name: FileNaming.newTextDocumentName), in: temp)
        let file2 = await perform(.createFile(in: temp.url, name: FileNaming.newTextDocumentName), in: temp)

        #expect(first.resultingItems.map(\.lastPathComponent) == ["New folder"])
        #expect(second.resultingItems.map(\.lastPathComponent) == ["New folder (2)"])
        #expect(file.resultingItems.map(\.lastPathComponent) == ["New Text Document.txt"])
        #expect(file2.resultingItems.map(\.lastPathComponent) == ["New Text Document (2).txt"])
        #expect(first.inverse == .trash(first.resultingItems))
    }

    // MARK: Control

    @Test func cancellingMidCopyLeavesAnUndoableRecord() async throws {
        let temp = try TemporaryDirectory()
        for index in 0..<10 {
            try temp.createFile(at: "src/Folder/\(index).txt", contents: "new")
        }
        try temp.createFile(at: "dst/Folder/5.txt", contents: "old")

        // Cancel while the sixth file's conflict is on screen.
        let task = makeTask(.copy([temp.path("src/Folder")], into: temp.path("dst")), in: temp)
        let result = await run(task, handlers: FileOperationHandlers(conflict: { _, reply in
            task.cancel()
            reply(ConflictDecision(.skip))
        }))

        #expect(result.wasCancelled)
        let copied = try FileManager.default.contentsOfDirectory(atPath: temp.path("dst/Folder").path)
        #expect(Set(copied) == ["0.txt", "1.txt", "2.txt", "3.txt", "4.txt", "5.txt"])
        #expect(try temp.contents("dst/Folder/5.txt") == "old")
        #expect(result.inverse == .trash((0..<5).map { temp.path("dst/Folder/\($0).txt") }))
    }

    @Test func pauseHoldsTheOperationUntilResumed() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt")
        try temp.createDirectory("dst")

        let task = makeTask(.copy([temp.path("a.txt")], into: temp.path("dst")), in: temp)
        task.pause()
        let running = Task { await run(task) }

        try await Task.sleep(for: .milliseconds(300))
        #expect(!temp.exists("dst/a.txt"))

        task.resume()
        _ = await running.value
        #expect(temp.exists("dst/a.txt"))
    }

    @Test func cancelReleasesAPausedTask() async throws {
        let temp = try TemporaryDirectory()
        try temp.createFile(at: "a.txt")

        let task = makeTask(.copy([temp.path("a.txt")], into: temp.path("dst")), in: temp)
        task.pause()
        let running = Task { await run(task) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        #expect(await running.value.wasCancelled)
    }

    @Test func failuresCanBeRetriedOrSkipped() async throws {
        let temp = try TemporaryDirectory()
        let locked = try temp.createFile(at: "src/locked.txt", contents: "secret")
        try temp.createFile(at: "src/open.txt")
        try temp.createDirectory("dst")
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o644) }

        let failures = Recorder<FileOperationFailure>()
        let skipped = await perform(
            .copy([locked, temp.path("src/open.txt")], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(failure: { failure, reply in
                failures.append(failure)
                reply(.skip)
            })
        )
        #expect(failures.items.map(\.url.lastPathComponent) == ["locked.txt"])
        #expect(skipped.failures.count == 1)
        #expect(temp.exists("dst/open.txt"))
        #expect(!temp.exists("dst/locked.txt"))

        let retried = await perform(
            .copy([locked], into: temp.path("dst")),
            in: temp,
            handlers: FileOperationHandlers(failure: { _, reply in
                chmod(locked.path, 0o644)
                reply(.retry)
            })
        )
        #expect(retried.failures.isEmpty)
        #expect(try temp.contents("dst/locked.txt") == "secret")
    }
}

// MARK: Helpers

/// Thread-safe collector for values reported by handler callbacks.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.withLock { values.append(value) }
    }

    var items: [Value] {
        lock.withLock { values }
    }
}

/// An environment whose "Trash" is `<temp>/.trash`, so tests don't touch the real one.
func fakeTrash(_ temp: TemporaryDirectory, crossVolume: Bool = false) -> FileOperationEnvironment {
    let trash = temp.path(".trash")
    var environment = FileOperationEnvironment { url in
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
    environment.forcesCrossVolumeMoves = crossVolume
    return environment
}

/// Runs a task on its own thread, as the app does.
func makeTask(
    _ request: FileOperationRequest,
    in temp: TemporaryDirectory,
    crossVolume: Bool = false
) -> FileOperationTask {
    FileOperationTask(request: request, environment: fakeTrash(temp, crossVolume: crossVolume))
}

func run(
    _ task: FileOperationTask,
    handlers: FileOperationHandlers = FileOperationHandlers()
) async -> FileOperationResult {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: task.run(handlers: handlers))
        }
    }
}

func perform(
    _ request: FileOperationRequest,
    in temp: TemporaryDirectory,
    crossVolume: Bool = false,
    handlers: FileOperationHandlers = FileOperationHandlers()
) async -> FileOperationResult {
    await run(makeTask(request, in: temp, crossVolume: crossVolume), handlers: handlers)
}
