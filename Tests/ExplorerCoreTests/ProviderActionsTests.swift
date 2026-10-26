import FileProvider
import Foundation
import Testing
@testable import ExplorerCore

@Suite struct ProviderActionsTests {
    /// OneDrive's declarations, trimmed.
    private static var info: [String: Any] { ["NSExtension": ["NSExtensionFileProviderActions": [
        action("MarkPinned", "ContextMenuAction_Pin",
               "SUBQUERY ( fileproviderItems, $item, $item.userInfo.showPinUnpin == NO ).@count == 0"),
        action("MarkUnpinned", "ContextMenuAction_Unpin",
               "SUBQUERY ( fileproviderItems, $item, $item.userInfo.showPinUnpin == NO ).@count == 0"),
        action("ShareLink", "ContextMenuAction_Share",
               "SUBQUERY ( fileproviderItems, $item, $item.userInfo.showShare != YES ).@count == 0"),
        action("VersionHistory", "ContextMenuAction_VersionHistory",
               "SUBQUERY ( fileproviderItems, $item, $item.userInfo.showVersionHistory == YES ).@count == 1"),
        action("PrioritizeSync", "ContextMenuAction_PrioritizeSync",
               "domainUserInfo.showPrioritizeSync == YES AND SUBQUERY ( fileproviderItems, $item, "
                   + "$item.userInfo.showVersionHistory == YES ).@count == 1"),
        action("Debug.Crash", "DEBUG: Crash extension",
               "SUBQUERY ( fileproviderItems, $item, $item.userInfo.showDebugActions != YES ).@count == 0"),
        ["NSExtensionFileProviderActionIdentifier": "com.example.Incomplete"],
    ]]] }

    private static let names = [
        "ContextMenuAction_Pin": "Always Keep on This Device",
        "ContextMenuAction_Unpin": "Free Up Space",
        "ContextMenuAction_Share": "Share",
        "ContextMenuAction_VersionHistory": "Version History",
        "ContextMenuAction_PrioritizeSync": "Prioritize Sync",
    ]

    private static func action(_ name: String, _ title: String, _ rule: String) -> [String: Any] {
        [
            "NSExtensionFileProviderActionIdentifier": "com.microsoft.OneDrive.FileProviderActions.\(name)",
            "NSExtensionFileProviderActionName": title,
            "NSExtensionFileProviderActionActivationRule": rule,
        ]
    }

    private static func declared() -> [ProviderAction] {
        ProviderActions.declaredActions(infoDictionary: info) { names[$0] ?? $0 }
    }

    private static func item(share: Bool = true, versions: Bool = true, pin: Bool = true) -> [String: Any] {
        ["userInfo": ["showShare": share, "showVersionHistory": versions, "showPinUnpin": pin]]
    }

    private static func eligible(_ items: [[String: Any]], domain: [String: Any]? = nil) -> [String] {
        declared()
            .filter { ProviderActions.isEligible($0, items: items, domainUserInfo: domain) }
            .map { String($0.identifier.split(separator: ".").last ?? "") }
    }

    @Test func readsDeclaredActionsInOrderWithoutDebugOnes() {
        let actions = Self.declared()
        #expect(actions.map(\.title) == [
            "Always Keep on This Device", "Free Up Space", "Share", "Version History", "Prioritize Sync",
        ])
        #expect(actions.map(\.role) == [.pin, .unpin, .other, .other, .other])
    }

    @Test func rulesSeeEachItemsUserInfo() {
        #expect(Self.eligible([Self.item()]) == ["MarkPinned", "MarkUnpinned", "ShareLink", "VersionHistory"])
        #expect(Self.eligible([Self.item(share: false, pin: false)]) == ["VersionHistory"])
    }

    @Test func rulesSeeTheWholeSelection() {
        // Share needs every item shareable; Version history exactly one item.
        #expect(Self.eligible([Self.item(), Self.item()]) == ["MarkPinned", "MarkUnpinned", "ShareLink"])
        #expect(Self.eligible([Self.item(), Self.item(share: false)]) == ["MarkPinned", "MarkUnpinned"])
    }

    @Test func rulesSeeTheDomainsUserInfo() {
        #expect(Self.eligible([Self.item()], domain: ["showPrioritizeSync": true]).last == "PrioritizeSync")
        #expect(!Self.eligible([Self.item()], domain: ["showPrioritizeSync": false]).contains("PrioritizeSync"))
    }

    @Test func brokenRulesHideTheActionWithoutThrowing() {
        let broken = ProviderAction(identifier: "x", title: "X", rule: "SUBQUERY ( fileproviderItems,")
        #expect(!ProviderActions.isEligible(broken, items: [Self.item()], domainUserInfo: nil))
        let wrongType = ProviderAction(identifier: "x", title: "X", rule: "fileproviderItems.@sum.userInfo > 1")
        #expect(!ProviderActions.isEligible(wrongType, items: [Self.item()], domainUserInfo: nil))
    }

    @Test func readsAndLocalizesAnExtensionBundle() throws {
        let dir = try TemporaryDirectory()
        let contents = try dir.createDirectory("Provider.appex/Contents")
        let plist = Self.info.merging(["CFBundleIdentifier": "com.example.provider.\(UUID().uuidString)"]) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let english = contents.appendingPathComponent("Resources/en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: Self.names, format: .xml, options: 0)
            .write(to: english.appendingPathComponent("Localizable.strings"))

        let actions = ProviderActions.declaredActions(ofExtensionAt: dir.path("Provider.appex"))
        #expect(actions.map(\.title).first == "Always Keep on This Device")
        #expect(actions.count == 5)
    }

    @Test func pinnedFromContentPolicyOrBadge() {
        let badges = "com.microsoft.OneDrive.FileProviderBadges"
        #expect(ProviderItemState(contentPolicy: 3, decorations: []).isPinned)
        #expect(ProviderItemState(contentPolicy: 1, decorations: ["\(badges).Pinned.Shared"]).isPinned)
        let unpinning = ProviderItemState(contentPolicy: 1, decorations: ["\(badges).Syncing"])
        #expect(!unpinning.isPinned)
        #expect(unpinning.isSyncing)
        #expect(!ProviderItemState(contentPolicy: 1, decorations: ["\(badges).SyncingSoon"]).isSyncing)
    }

    @Test func pinnedItemsFailEvictionAsNonEvictable() {
        let fileProvider = NSError(domain: NSFileProviderErrorDomain,
                                   code: NSFileProviderError.Code.nonEvictable.rawValue)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: fileProvider])
        #expect(CloudSync.isNonEvictable(wrapped))
        #expect(CloudSync.isNonEvictable(fileProvider))
        #expect(!CloudSync.isNonEvictable(CocoaError(.fileNoSuchFile)))
    }

    @Test func nothingOutsideFileProviderDomains() throws {
        let dir = try TemporaryDirectory()
        let file = try dir.createFile("a.txt")
        #expect(ProviderActions.actions(for: [file]).isEmpty)
        #expect(!ProviderActions.isPinned(file))
    }
}
