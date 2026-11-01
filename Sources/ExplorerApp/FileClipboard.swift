import AppKit
import ExplorerCore

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
    /// Items copied in a folder on an SSH server, as JSON `[RemotePath]`.
    private static let remoteItems = NSPasteboard.PasteboardType(
        (Bundle.main.bundleIdentifier ?? "com.example.explorer") + ".remote-items"
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

    /// Copies items on an SSH server: Paste in a local folder downloads them. Other apps get
    /// their addresses as text.
    func writeRemote(_ paths: [RemotePath]) {
        pasteboard.clearContents()
        pasteboard.declareTypes([Self.remoteItems, .string], owner: nil)
        if let data = try? JSONEncoder().encode(paths) {
            pasteboard.setData(data, forType: Self.remoteItems)
        }
        pasteboard.setString(paths.map(\.addressString).joined(separator: "\n"), forType: .string)
        cutURLs = []
        lastChangeCount = pasteboard.changeCount
        postChange()
    }

    /// Remote items copied in this app, if that's what the pasteboard holds.
    func readRemote() -> [RemotePath]? {
        guard let data = pasteboard.data(forType: Self.remoteItems),
              let paths = try? JSONDecoder().decode([RemotePath].self, from: data), !paths.isEmpty else { return nil }
        return paths
    }

    var canPasteRemote: Bool {
        pasteboard.types?.contains(Self.remoteItems) ?? false
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
