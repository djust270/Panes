import Foundation
import Testing
@testable import ExplorerCore

@Suite struct CloudStatusTests {
    private func status(
        folder: Bool = false, onlineOnly: Bool = false, uploaded: Bool = true, transferring: Bool = false,
        problem: Bool = false
    ) -> CloudStatus? {
        CloudStatusReader.status(isFolder: folder, isOnlineOnly: onlineOnly, isUploaded: uploaded,
                                 isTransferring: transferring, hasProblem: problem)
    }

    @Test func filesAreOnlineOnlyOrOnThisDevice() {
        #expect(status(onlineOnly: true) == .onlineOnly)
        #expect(status() == .availableOnDevice)
    }

    @Test func syncingAndProblemsOutrankAvailability() {
        #expect(status(uploaded: false) == .syncing)
        #expect(status(transferring: true) == .syncing)
        #expect(status(transferring: true, problem: true) == .error)
    }

    @Test func foldersShowOnlySyncingAndProblems() {
        #expect(status(folder: true) == nil)
        #expect(status(folder: true, onlineOnly: true) == nil)
        #expect(status(folder: true, transferring: true) == .syncing)
        #expect(status(folder: true, problem: true) == .error)
    }

    @Test func quickStatusComesFromTheListing() {
        var file = FileItem(url: URL(fileURLWithPath: "/x/a.docx"), name: "a.docx", kind: .file)
        #expect(CloudStatusReader.quickStatus(of: file) == .availableOnDevice)
        #expect(CloudStatusReader.needsReading(file))
        file.isOnlineOnly = true
        #expect(CloudStatusReader.quickStatus(of: file) == .onlineOnly)
        #expect(!CloudStatusReader.needsReading(file))
        let folder = FileItem(url: URL(fileURLWithPath: "/x/f", isDirectory: true), name: "f", kind: .directory)
        #expect(CloudStatusReader.quickStatus(of: folder) == nil)
    }

    @Test func cloudFoldersAndTheirContentsAreRecognised() {
        let oneDrive = CloudStorage.fileProviderFolder.appendingPathComponent("OneDrive-Personal")
        #expect(CloudStorage.isInCloudFolder(oneDrive))
        #expect(CloudStorage.isInCloudFolder(oneDrive.appendingPathComponent("Documents/a.txt")))
        #expect(CloudStorage.isInCloudFolder(CloudStorage.iCloudDriveFolder))
        #expect(!CloudStorage.isInCloudFolder(CloudStorage.fileProviderFolder))
        #expect(!CloudStorage.isInCloudFolder(URL(fileURLWithPath: "/tmp")))
    }

    @Test func sortsByStatusWithFoldersFirstAndUnknownLast() {
        func file(_ name: String, _ status: CloudStatus?) -> FileItem {
            var item = FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, kind: .file)
            item.cloudStatus = status
            return item
        }
        let items = [file("a", .onlineOnly), file("b", nil), file("c", .availableOnDevice), file("d", .error)]
        let sorted = FileItemSort(key: .status, ascending: true).sorted(items)
        #expect(sorted.map(\.name) == ["c", "a", "d", "b"])
    }

    @Test func cloudFoldersShowStatusByDefault() {
        let defaults = TemporaryDefaults()
        let store = FolderViewSettingsStore(defaults: defaults.defaults)
        let cloud = ExplorerLocation.folder(CloudStorage.fileProviderFolder.appendingPathComponent("Dropbox/Work"))
        #expect(store.settings(for: cloud).columns == [.name, .status, .dateModified, .type, .size])
        #expect(!store.settings(for: .folder(path: "/tmp")).columns.contains(.status))

        // Removing it sticks.
        var settings = store.settings(for: cloud)
        settings.columns.removeAll { $0 == .status }
        store.save(settings, for: cloud)
        #expect(!store.settings(for: cloud).columns.contains(.status))
    }
}
