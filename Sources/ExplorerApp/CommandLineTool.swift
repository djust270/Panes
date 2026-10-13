import Foundation

/// Runs command-line tools (`ditto`, `zip`, `tar`) off the main thread.
enum CommandLineTool {
    /// Runs `tool`; returns its error output on failure, `nil` on success. Cancelling the
    /// calling task terminates the tool.
    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try process.run()
                } catch {
                    return error.localizedDescription
                }
                let output = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return nil }
                if process.terminationReason == .uncaughtSignal { return "Cancelled." }
                return (String(data: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        } onCancel: {
            process.terminate()
        }
    }
}
