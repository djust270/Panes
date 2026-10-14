import AppKit
import ExplorerCore
import UniformTypeIdentifiers

/// How other apps reach Explorer: opening folders (it's a registered folder viewer), the
/// "Open in Explorer" and "Reveal in Explorer" services, the "reveal" Apple event sent by
/// "Show in Finder" when Explorer is the default file viewer, and the setting that makes it
/// the default.
@MainActor
enum SystemIntegration {
    private static let provider = ServicesProvider()

    /// Registers the services and the reveal handler. Called at launch.
    static func start() {
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        // 'misc'/'mvis' ("make objects visible"): how "Show in Finder" reaches the file viewer.
        NSAppleEventManager.shared().setEventHandler(
            provider,
            andSelector: #selector(ServicesProvider.handleReveal(_:replyEvent:)),
            forEventClass: AEEventClass(kAEMiscStandards),
            andEventID: AEEventID(kAEMakeObjectsVisible)
        )
    }

    /// Opens folders (each in a tab) and reveals files (their folder, with them selected).
    static func open(_ urls: [URL]) {
        let urls = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        var files: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                AppDelegate.shared.showTab(at: .folder(url), selecting: [])
            } else {
                files.append(url)
            }
        }
        reveal(files)
    }

    /// Shows each item's folder with the items selected, one tab per folder.
    static func reveal(_ urls: [URL]) {
        let byFolder = Dictionary(grouping: urls.map(\.standardizedFileURL)) { $0.deletingLastPathComponent() }
        for (folder, items) in byFolder.sorted(by: { $0.key.path < $1.key.path }) {
            AppDelegate.shared.showTab(at: .folder(folder), selecting: items)
        }
    }

    // MARK: Default file browser

    /// Whether this copy of the app can be made the default (only when run as a bundle).
    static var canBeDefault: Bool { Bundle.main.bundleIdentifier != nil }

    /// Explorer opens folders and handles "Show in Finder" for every app.
    static var isDefaultFileBrowser: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return global?["NSFileViewer"] as? String == identifier
    }

    /// Makes Explorer (or, turning it off, Finder) the default for folders and the file
    /// viewer. Returns an error message on failure.
    static func setDefaultFileBrowser(_ enabled: Bool) async -> String? {
        guard let identifier = Bundle.main.bundleIdentifier else {
            return "Run \(AppInfo.name) from its app bundle first."
        }
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let app = enabled ? Bundle.main.bundleURL : finder
        var global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        if enabled {
            global["NSFileViewer"] = identifier
        } else {
            global.removeValue(forKey: "NSFileViewer")
        }
        UserDefaults.standard.setPersistentDomain(global, forName: UserDefaults.globalDomain)
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The Services menu entries and the reveal Apple event.
final class ServicesProvider: NSObject {
    /// "Open in Explorer" (folders).
    @objc func openInExplorer(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(pasteboard)
        MainActor.assumeIsolated { SystemIntegration.open(urls) }
    }

    /// "Reveal in Explorer" (any item).
    @objc func revealInExplorer(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(pasteboard)
        MainActor.assumeIsolated { SystemIntegration.reveal(urls) }
    }

    @objc func handleReveal(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        var urls: [URL] = []
        if let list = event.paramDescriptor(forKeyword: keyDirectObject) {
            let items = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap(list.atIndex) : [list]
            urls = items.compactMap { $0.coerce(toDescriptorType: typeFileURL)?.fileURLValue }
        }
        MainActor.assumeIsolated {
            SystemIntegration.reveal(urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
