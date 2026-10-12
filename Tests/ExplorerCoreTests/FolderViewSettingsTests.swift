import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FolderViewSettingsTests {
    /// A throwaway defaults domain per test.
    private final class Defaults {
        let name = "ExplorerCoreTests-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: name) ?? .standard
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private let docs = ExplorerLocation.folder(path: "/Users/me/Documents")
    private let pics = ExplorerLocation.folder(path: "/Users/me/Pictures")

    @Test func unknownFoldersUseDefaults() {
        let domain = Defaults()
        let store = FolderViewSettingsStore(defaults: domain.defaults)
        #expect(store.settings(for: docs) == .folderDefault)
        #expect(store.settings(for: .recycleBin) == .recycleBinDefault)
        #expect(store.settings(for: .home) == .folderDefault)
    }

    @Test func remembersPerFolderAcrossInstances() {
        let domain = Defaults()
        let icons = FolderViewSettings(viewMode: .largeIcons, grouping: FileGrouping(key: .type))
        FolderViewSettingsStore(defaults: domain.defaults).save(icons, for: pics)

        let reloaded = FolderViewSettingsStore(defaults: domain.defaults)
        #expect(reloaded.settings(for: pics) == icons)
        #expect(reloaded.settings(for: docs) == .folderDefault)
    }

    @Test func applyToAllReplacesFolderViewsButNotRecycleBin() {
        let domain = Defaults()
        let store = FolderViewSettingsStore(defaults: domain.defaults)
        let binView = FolderViewSettings(viewMode: .tiles, columns: [.name, .dateDeleted])
        store.save(FolderViewSettings(viewMode: .list), for: pics)
        store.save(binView, for: .recycleBin)

        let content = FolderViewSettings(viewMode: .content, sort: FileItemSort(key: .size, ascending: false))
        store.applyToAllFolders(content)
        #expect(store.settings(for: pics) == content)
        #expect(store.settings(for: docs) == content)
        #expect(store.settings(for: .recycleBin) == binView)

        store.resetAllFolders()
        #expect(store.settings(for: pics) == .folderDefault)
        #expect(store.settings(for: .recycleBin) == .recycleBinDefault)
    }

    @Test func forgetsLeastRecentlyChangedBeyondCapacity() {
        let domain = Defaults()
        let store = FolderViewSettingsStore(defaults: domain.defaults, capacity: 2)
        let list = FolderViewSettings(viewMode: .list)
        store.save(list, for: .folder(path: "/a"), now: Date(timeIntervalSince1970: 1))
        store.save(list, for: .folder(path: "/b"), now: Date(timeIntervalSince1970: 2))
        store.save(list, for: .folder(path: "/c"), now: Date(timeIntervalSince1970: 3))
        #expect(store.settings(for: .folder(path: "/a")) == .folderDefault)
        #expect(store.settings(for: .folder(path: "/b")) == list)
        #expect(store.settings(for: .folder(path: "/c")) == list)
    }

    @Test func sanitizingRemovesRecycleBinColumnsOutsideIt() {
        let settings = FolderViewSettings(
            sort: FileItemSort(key: .dateDeleted),
            grouping: FileGrouping(key: .originalLocation),
            columns: [.size, .originalLocation, .name, .size]
        )
        let folder = settings.sanitized(inRecycleBin: false)
        #expect(folder.columns == [.name, .size])
        #expect(folder.sort == FileItemSort())
        #expect(folder.grouping == nil)
        #expect(settings.sanitized(inRecycleBin: true).columns == [.name, .size, .originalLocation])
    }

    @Test func propertiesNeededOnlyForPropertyColumnsOrSort() {
        #expect(!FolderViewSettings().needsProperties)
        #expect(FolderViewSettings(columns: [.name, .dimensions]).needsProperties)
        #expect(!FolderViewSettings(viewMode: .tiles, columns: [.name, .dimensions]).needsProperties)
        #expect(FolderViewSettings(viewMode: .tiles, sort: FileItemSort(key: .duration)).needsProperties)
    }
}
