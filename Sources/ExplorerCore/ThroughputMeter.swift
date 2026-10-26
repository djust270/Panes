import Foundation

/// Transfer speed over a sliding window, for the progress dialog's "Speed" and
/// "Time remaining".
public struct ThroughputMeter: Sendable {
    private struct Sample: Sendable {
        let time: TimeInterval
        let bytes: Int64
    }

    public let window: TimeInterval
    private var samples: [Sample] = []

    public init(window: TimeInterval = 3) {
        self.window = window
    }

    /// Records the running total of bytes copied at `time` (any monotonic clock, in seconds).
    public mutating func record(bytes: Int64, at time: TimeInterval) {
        if let last = samples.last, bytes < last.bytes {
            samples.removeAll()
        }
        samples.append(Sample(time: time, bytes: bytes))
        // Drop samples older than the window, keeping at least two to measure between.
        while samples.count > 2, samples[0].time < time - window {
            samples.removeFirst()
        }
    }

    /// Forget history, e.g. after a pause, so the idle time doesn't drag the rate down.
    public mutating func reset() {
        samples.removeAll()
    }

    /// Bytes per second, or `nil` until at least half a second has been observed.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let elapsed = last.time - first.time
        guard elapsed >= 0.5 else { return nil }
        return Double(last.bytes - first.bytes) / elapsed
    }

    public func secondsRemaining(totalBytes: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0, let last = samples.last else { return nil }
        return Double(max(0, totalBytes - last.bytes)) / rate
    }
}

/// Text for the progress dialog.
public enum FileOperationText {
    /// "About 5 seconds", "About 2 minutes", "About 1 hour and 5 minutes".
    public static func timeRemaining(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "Calculating…" }
        let total = Int(seconds.rounded(.up))
        if total < 60 {
            let rounded = total <= 10 ? max(1, total) : (total + 4) / 5 * 5
            return "About \(plural(rounded, "second"))"
        }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "About \(plural(minutes, "minute"))" }
        let hours = minutes / 60
        let rest = minutes % 60
        guard rest > 0 else { return "About \(plural(hours, "hour"))" }
        return "About \(plural(hours, "hour")) and \(plural(rest, "minute"))"
    }

    /// "Speed: 12.5 MB/s".
    public static func speed(_ bytesPerSecond: Double) -> String {
        "\(FileSizeFormat.string(for: Int64(bytesPerSecond)))/s"
    }

    /// The dialog's headline, e.g. "Copying 12 items from Downloads to Documents".
    public static func summary(of request: FileOperationRequest, itemCount: Int) -> String {
        let items = plural(itemCount, "item")
        func name(_ url: URL) -> String { ExplorerLocation.folder(url).displayName }
        let sourceFolder = request.sourceURLs.first.map { name($0.deletingLastPathComponent()) }

        switch request {
        case .copy(_, let folder):
            return "Copying \(items) from \(sourceFolder ?? "") to \(name(folder))"
        case .move(_, let folder):
            return "Moving \(items) from \(sourceFolder ?? "") to \(name(folder))"
        case .relocate(let relocations):
            let destination = relocations.first.map { name($0.destination.deletingLastPathComponent()) } ?? ""
            return "Moving \(items) to \(destination)"
        case .trash, .delete:
            return "Deleting \(items) from \(sourceFolder ?? "")"
        case .rename:
            return "Renaming \(items)"
        case .createFolder(let folder, _), .createFile(let folder, _):
            return "Creating \(items) in \(name(folder))"
        case .download(let urls):
            let provider = urls.first.flatMap(CloudSync.providerName(for:)) ?? sourceFolder ?? ""
            return "Downloading \(items) from \(provider)"
        }
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}
