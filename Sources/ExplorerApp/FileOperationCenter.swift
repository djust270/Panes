import AppKit
import ExplorerCore

/// Runs file operations for every window: each on its own background thread, with a shared
/// progress window, Replace/Skip and error prompts, and one app-wide undo history (Windows
/// Explorer's undo is per-process, not per-window).
@MainActor
final class FileOperationCenter {
    static let shared = FileOperationCenter()

    let undoManager = UndoManager()
    private let progressWindow = ProgressWindowController()
    private let prompts = PromptQueue()
    private var tasks: [UUID: FileOperationTask] = [:]

    private init() {}

    var hasRunningOperations: Bool { !tasks.isEmpty }

    /// Runs `request` and returns once it finishes. Registers the inverse for undo unless
    /// `registersUndo` is false (undo/redo steps register their own).
    @discardableResult
    func perform(_ request: FileOperationRequest, registersUndo: Bool = true) async -> FileOperationResult {
        let task = FileOperationTask(request: request)
        tasks[task.id] = task
        progressWindow.add(task)

        let result = await Self.run(task, handlers: handlers(for: task.id))

        tasks[task.id] = nil
        progressWindow.remove(task.id)
        if registersUndo, let inverse = result.inverse {
            registerUndo(inverse, actionName: request.actionName)
        }
        return result
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    private nonisolated static func run(
        _ task: FileOperationTask,
        handlers: FileOperationHandlers
    ) async -> FileOperationResult {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: task.run(handlers: handlers))
            }
            thread.qualityOfService = .userInitiated
            thread.name = "FileOperation"
            thread.start()
        }
    }

    /// Handlers run on the task's thread; everything they touch lives on the main thread.
    private func handlers(for id: UUID) -> FileOperationHandlers {
        FileOperationHandlers(
            progress: { progress in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        FileOperationCenter.shared.progressWindow.update(id, progress: progress)
                    }
                }
            },
            conflict: { conflict, reply in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { FileOperationCenter.shared.ask(conflict, for: id, reply: reply) }
                }
            },
            failure: { failure, reply in
                // Items on volumes without a Trash are skipped quietly; the caller offers to
                // delete them permanently once the operation ends.
                if failure.reason == .trashUnavailable {
                    reply(.skip)
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { FileOperationCenter.shared.ask(failure, for: id, reply: reply) }
                }
            }
        )
    }

    // MARK: Prompts

    private func ask(_ conflict: FileConflict, for id: UUID, reply: @escaping @Sendable (ConflictDecision) -> Void) {
        guard let task = tasks[id] else { return reply(ConflictDecision(.cancel)) }
        let summary = progressWindow.summary(for: id) ?? ""
        prompts.enqueue { done in
            guard !task.isCancelled else {
                reply(ConflictDecision(.cancel))
                return done()
            }
            let dialog = ConflictWindowController(conflict: conflict, summary: summary)
            dialog.present { decision in
                reply(decision)
                done()
            }
        }
    }

    private func ask(
        _ failure: FileOperationFailure,
        for id: UUID,
        reply: @escaping @Sendable (FailureResolution) -> Void
    ) {
        guard let task = tasks[id] else { return reply(.cancel) }
        prompts.enqueue { [progressWindow] done in
            guard !task.isCancelled else {
                reply(.cancel)
                return done()
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Self.failureTitle(for: task.request, item: failure.url.lastPathComponent)
            alert.informativeText = failure.message
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do this for all current items"

            let window = progressWindow.showNow()
            alert.beginSheetModal(for: window) { response in
                let skipAll = alert.suppressionButton?.state == .on
                switch response {
                case .alertFirstButtonReturn: reply(.retry)
                case .alertSecondButtonReturn: reply(skipAll ? .skipAll : .skip)
                default: reply(.cancel)
                }
                done()
            }
        }
    }

    private static func failureTitle(for request: FileOperationRequest, item: String) -> String {
        let verb: String
        switch request {
        case .copy: verb = "copy"
        case .move, .relocate: verb = "move"
        case .trash, .delete: verb = "delete"
        case .rename: verb = "rename"
        case .createFolder, .createFile: verb = "create"
        case .download: verb = "download"
        }
        return "Couldn’t \(verb) “\(item)”"
    }

    // MARK: Undo

    private func registerUndo(_ request: FileOperationRequest, actionName: String) {
        undoManager.registerUndo(withTarget: self) { center in
            MainActor.assumeIsolated { center.runReversal(request, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    /// Runs one step of an undo/redo pair. The undo manager calls this while undoing (or
    /// redoing), so the opposite step must be registered now, even though it is only known
    /// once the operation finishes.
    private func runReversal(_ request: FileOperationRequest, actionName: String) {
        let next = PendingRequest()
        undoManager.registerUndo(withTarget: self) { center in
            MainActor.assumeIsolated {
                guard let request = next.request else {
                    NSSound.beep()
                    return
                }
                center.runReversal(request, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        Task {
            next.request = await perform(request, registersUndo: false).inverse
        }
    }
}

/// The opposite of an undo/redo step, filled in when that step's operation finishes.
@MainActor
private final class PendingRequest {
    var request: FileOperationRequest?
}

/// Shows prompts one at a time, so concurrent operations don't stack dialogs on each other.
@MainActor
final class PromptQueue {
    typealias Prompt = (_ done: @escaping () -> Void) -> Void

    private var queue: [Prompt] = []
    private var isShowing = false

    func enqueue(_ prompt: @escaping Prompt) {
        queue.append(prompt)
        showNext()
    }

    private func showNext() {
        guard !isShowing, !queue.isEmpty else { return }
        isShowing = true
        let prompt = queue.removeFirst()
        prompt { [weak self] in
            self?.isShowing = false
            self?.showNext()
        }
    }
}
