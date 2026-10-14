import AppKit
import Sparkle

/// Auto-updates through Sparkle: the appcast lists releases, each signed with the project's
/// EdDSA key (`SUPublicEDKey` in Info.plist); beta builds are appcast items on the "beta"
/// channel, offered only when Settings › "Get beta updates" is on. Off when run unbundled
/// (`swift run`) or built without a feed.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    /// Starts the updater at launch; with automatic checks on, Sparkle checks once a day.
    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleIdentifier != nil,
              (info["SUFeedURL"] as? String)?.isEmpty == false,
              (info["SUPublicEDKey"] as? String)?.isEmpty == false
        else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// After switching channels, so the next scheduled check sees the new channel soon.
    func channelDidChange() {
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Read directly: Sparkle may ask off the main thread.
        UserDefaults.standard.bool(forKey: AppSettings.betaUpdatesKey) ? ["beta"] : []
    }
}
