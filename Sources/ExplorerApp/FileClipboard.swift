import AppKit

/// Cut/Copy/Paste of files through the general pasteboard, with Windows "cut" semantics:
/// cut items stay in place (dimmed) until pasted, and are then moved.
///
/// File URLs are written as ordinary `NSURL`s, so Finder and other apps can paste them as
/// copies; a private marker type records that they were cut.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()
    static let didChangeNotification = Notification.Name("FileClipboardDidChange")

    private static let cutMarker = NSPasteboard.PasteboardType(
        (Bundle.main.bundleIdentifier ?? "com.example.explorer") + ".cut"
    )

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int

    /// Items cut and still waiting to be pasted, for dimming.
    private(set) var cutURLs: Set<URL> = []

    private init() {
        lastChangeCount = pasteboard.changeCount
    }

    func write(_ urls: [URL], cut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        if cut {
            pasteboard.setData(Data(), forType: Self.cutMarker)
        }
        cutURLs = cut ? Set(urls.map(\.standardizedFileURL)) : []
        lastChangeCount = pasteboard.changeCount
        postChange()
    }

    /// File URLs on the pasteboard, and whether they were cut (in this app).
    func read() -> (urls: [URL], isCut: Bool)? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard let urls = objects as? [URL], !urls.isEmpty else { return nil }
        let isCut = pasteboard.types?.contains(Self.cutMarker) ?? false
        return (urls.map(\.standardizedFileURL), isCut)
    }

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// After a cut-and-paste the pasteboard is emptied, as on Windows: the originals are gone.
    func clearAfterMove() {
        pasteboard.clearContents()
        cutURLs = []
        lastChangeCount = pasteboard.changeCount
        postChange()
    }

    /// Picks up changes made by other apps (which end any pending cut).
    func refresh() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        if !cutURLs.isEmpty {
            cutURLs = []
            postChange()
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
