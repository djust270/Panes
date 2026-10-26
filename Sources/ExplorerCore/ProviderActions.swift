import FileProviderBridge
import Foundation

/// A command a cloud provider adds to Finder's menu (OneDrive's Share, Copy link, View online,
/// Version history, Always keep on this device…), declared by its File Provider extension.
public struct ProviderAction: Sendable, Hashable {
    public let identifier: String
    /// In the provider's own wording and the user's language ("Always Keep on This Device").
    public let title: String
    /// The `NSPredicate` deciding which items it shows for.
    public let rule: String

    public init(identifier: String, title: String, rule: String) {
        self.identifier = identifier
        self.title = title
        self.rule = rule
    }

    public enum Role: Sendable {
        /// "Always keep on this device".
        case pin
        /// Undoes `pin`; OneDrive calls it "Free Up Space".
        case unpin
        case other
    }

    /// Told from the identifier's last part (OneDrive: `…MarkPinned`, `…MarkUnpinned`).
    public var role: Role {
        let name = identifier.split(separator: ".").last?.lowercased() ?? ""
        if name.contains("unpin") { return .unpin }
        if name.contains("pin") { return .pin }
        return .other
    }
}

/// A File Provider item's pinning and badges, as Finder shows them.
public struct ProviderItemState: Sendable, Hashable {
    /// Set to always stay on this device ("Always keep on this device", iCloud Drive's "Keep
    /// Downloaded"): `NSFileProviderContentPolicy.downloadEagerlyAndKeepDownloaded`, or a
    /// provider's pinned badge (OneDrive's `…FileProviderBadges.Pinned`, `….Pinned.Shared`).
    public let isPinned: Bool
    /// The provider's syncing badge (OneDrive's `…FileProviderBadges.Syncing`): shown, for
    /// one, while it unpins, which the public status keys don't tell.
    public let isSyncing: Bool

    init(contentPolicy: Int, decorations: [String]) {
        func hasBadge(_ name: String) -> Bool {
            decorations.contains { $0.split(separator: ".").contains { $0 == name } }
        }
        isPinned = contentPolicy == 3 || hasBadge("Pinned")
        isSyncing = hasBadge("Syncing")
    }
}

/// Runs cloud providers' own commands, as Finder's menu does: the provider's File Provider
/// extension declares them (`NSExtensionFileProviderActions`: identifier, name, activation
/// rule) and does the work. No public API exists for this, so it goes through private
/// FileProvider.framework classes (`FileProviderBridge`); if they're missing, there are simply
/// no provider actions.
public enum ProviderActions {
    /// The most items looked up for one menu (~1 ms each).
    static let maximumItems = 200

    /// The actions the provider serving `urls` offers for them, in its order; empty if they're
    /// not all in one File Provider domain. Synchronous, ~1 ms per item.
    public static func actions(for urls: [URL]) -> [ProviderAction] {
        guard !urls.isEmpty, urls.count <= maximumItems, FPBBridge.isAvailable else { return [] }
        var items: [FPBItem] = []
        for url in urls {
            guard let item = FPBBridge.item(for: url),
                  item.domainIdentifier == (items.first?.domainIdentifier ?? item.domainIdentifier)
            else { return [] }
            items.append(item)
        }
        guard let domain = FPBBridge.domain(for: urls[0]), let extensionURL = domain.extensionBundleURL else {
            return []
        }
        return declaredActions(ofExtensionAt: extensionURL).filter {
            isEligible($0, items: items.map(\.object), domainUserInfo: domain.userInfo)
        }
    }

    /// Runs `action` on `urls`. Returns once the provider has taken it; the work (a download,
    /// a share window, a browser tab) follows.
    public static func perform(_ action: ProviderAction, on urls: [URL]) async throws {
        let items = urls.compactMap(FPBBridge.item(for:))
        guard let domain = items.first?.domainIdentifier, items.count == urls.count else {
            throw CocoaError(.fileNoSuchFile)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FPBBridge.performAction(action.identifier, domainIdentifier: domain,
                                    itemIdentifiers: items.map(\.itemIdentifier)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// What the provider shows on `url` in Finder; `nil` outside File Provider domains. ~1 ms.
    public static func state(of url: URL) -> ProviderItemState? {
        FPBBridge.item(for: url).map { ProviderItemState(contentPolicy: $0.contentPolicy, decorations: $0.decorations) }
    }

    /// Whether `url` is set to always stay on this device. ~1 ms.
    public static func isPinned(_ url: URL) -> Bool {
        state(of: url)?.isPinned == true
    }

    /// Runs the provider's unpin ("Free Up Space" for OneDrive) on `url`, the only way to
    /// free up space for a pinned item. False if the provider declares none.
    public static func unpin(_ url: URL) async throws -> Bool {
        guard let action = actions(for: [url]).first(where: { $0.role == .unpin }) else { return false }
        try await perform(action, on: [url])
        return true
    }

    // MARK: Declared actions

    private static let cache = DeclaredActionCache()

    /// The actions an extension declares, cached per extension.
    static func declaredActions(ofExtensionAt url: URL) -> [ProviderAction] {
        if let cached = cache[url] { return cached }
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return [] }
        let actions = declaredActions(infoDictionary: info) { key in
            let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
            return localized != key ? localized : bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
        }
        cache[url] = actions
        return actions
    }

    /// The actions in an extension's Info.plist, debug ones left out.
    static func declaredActions(infoDictionary: [String: Any], localize: (String) -> String) -> [ProviderAction] {
        let declared = (infoDictionary["NSExtension"] as? [String: Any])?["NSExtensionFileProviderActions"]
        return (declared as? [[String: Any]] ?? []).compactMap { entry in
            guard let identifier = entry["NSExtensionFileProviderActionIdentifier"] as? String,
                  let name = entry["NSExtensionFileProviderActionName"] as? String,
                  let rule = entry["NSExtensionFileProviderActionActivationRule"] as? String,
                  !identifier.split(separator: ".").contains("Debug")
            else { return nil }
            return ProviderAction(identifier: identifier, title: localize(name), rule: rule)
        }
    }

    /// Evaluates `action`'s rule as Finder does: `fileproviderItems` are the items (anything
    /// key-value coding reaches, such as their `userInfo`), `domainUserInfo` the domain's.
    /// A rule that doesn't parse or evaluate hides the action.
    static func isEligible(_ action: ProviderAction, items: [Any], domainUserInfo: [AnyHashable: Any]?) -> Bool {
        guard let predicate = FPBBridge.predicate(withFormat: action.rule) else { return false }
        let object: NSDictionary = ["fileproviderItems": items, "domainUserInfo": domainUserInfo ?? [:]]
        return FPBBridge.evaluate(predicate, with: object)
    }
}

/// Declared actions per extension; read from menus (main thread) and status reads.
private final class DeclaredActionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [URL: [ProviderAction]] = [:]

    subscript(url: URL) -> [ProviderAction]? {
        get { lock.withLock { actions[url] } }
        set { lock.withLock { actions[url] = newValue } }
    }
}
