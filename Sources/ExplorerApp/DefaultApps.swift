import AppKit
import UniformTypeIdentifiers

/// Choosing an app to open files with, and making it the default for their type ("Always use
/// this app to open .txt files", or "Change…" in Properties).
@MainActor
enum DefaultApps {
    /// Asks for an app to open `files`. With `offerAlways`, adds Windows' "Always use this app
    /// to open .ext files" checkbox and returns its state.
    static func chooseApp(
        for files: [URL],
        in window: NSWindow,
        offerAlways: Bool = false
    ) async -> (app: URL, always: Bool)? {
        guard let first = files.first else { return nil }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open “\(first.lastPathComponent)”"
        let always = NSButton(checkboxWithTitle: alwaysTitle(for: files), target: nil, action: nil)
        if offerAlways, sharedExtension(of: files) != nil {
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 36))
            always.frame = NSRect(x: 12, y: 8, width: 340, height: 20)
            accessory.addSubview(always)
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }
        guard await panel.beginSheetModal(for: window) == .OK, let app = panel.url else { return nil }
        return (app, always.state == .on)
    }

    /// The app only, for "Change…" (where choosing always sets the default).
    static func chooseApp(for files: [URL], in window: NSWindow) async -> URL? {
        await chooseApp(for: files, in: window, offerAlways: false)?.app
    }

    /// Makes `app` open every file of `file`'s type. Returns an error message on failure.
    static func setDefault(_ app: URL, for file: URL) async -> String? {
        guard let type = contentType(of: file) else { return "The file’s type isn’t known." }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func contentType(of file: URL) -> UTType? {
        if let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        return UTType(filenameExtension: file.pathExtension)
    }

    /// The extension all `files` share, if any.
    private static func sharedExtension(of files: [URL]) -> String? {
        let extensions = Set(files.map { $0.pathExtension.lowercased() })
        guard extensions.count == 1, let ext = extensions.first, !ext.isEmpty else { return nil }
        return ext
    }

    private static func alwaysTitle(for files: [URL]) -> String {
        "Always use this app to open .\(sharedExtension(of: files) ?? "") files"
    }
}
