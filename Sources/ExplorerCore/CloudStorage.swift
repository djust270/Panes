import Foundation

/// A sync client's folder (OneDrive, iCloud Drive, Google Drive, Dropbox, Box…), shown as a
/// root of the navigation pane and the top of its breadcrumb, as Windows shows OneDrive.
public struct CloudRoot: Sendable, Hashable {
    public enum Provider: String, Sendable, Hashable {
        case iCloudDrive
        case oneDrive
        /// SharePoint libraries synced by OneDrive, under the organisation's name.
        case sharePoint
        case googleDrive
        case dropbox
        case box
        case other
    }

    /// Standardized.
    public let url: URL
    public let provider: Provider
    /// "OneDrive - Personal", "Google Drive (me@example.com)" etc.
    public let title: String

    public init(url: URL, provider: Provider, title: String) {
        self.url = url.standardizedFileURL
        self.provider = provider
        self.title = title
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch provider {
        case .iCloudDrive: return "icloud"
        case .sharePoint: return "building.2"
        default: return "cloud"
        }
    }
}

/// Finds the sync clients' folders. File Provider clients keep one folder per account in
/// `~/Library/CloudStorage`, named `<Provider>-<Account>`; iCloud Drive lives in
/// `~/Library/Mobile Documents/com~apple~CloudDocs`. Everything here goes by path, so it's
/// cheap enough to call while building breadcrumbs.
public enum CloudStorage {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    /// `~/Library/CloudStorage`.
    public static let fileProviderFolder = fileProviderFolder(home: home)
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`.
    public static let iCloudDriveFolder = iCloudDriveFolder(home: home)

    static func fileProviderFolder(home: URL) -> URL {
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true).standardizedFileURL
    }

    static func iCloudDriveFolder(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .standardizedFileURL
    }

    /// The cloud folders present, iCloud Drive first, then by title.
    public static func roots(
        fileProviderFolder: URL = fileProviderFolder,
        iCloudDriveFolder: URL = iCloudDriveFolder
    ) -> [CloudRoot] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: fileProviderFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let providerRoots = folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { root(named: $0.lastPathComponent, at: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: iCloudDriveFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return providerRoots }
        return [iCloudDrive(at: iCloudDriveFolder)] + providerRoots
    }

    /// The cloud root at exactly `url`, if it is one (whether or not it exists).
    public static func root(at url: URL) -> CloudRoot? {
        root(at: url, fileProviderFolder: fileProviderFolder, iCloudDriveFolder: iCloudDriveFolder)
    }

    static func root(at url: URL, fileProviderFolder: URL, iCloudDriveFolder: URL) -> CloudRoot? {
        let url = url.standardizedFileURL
        if url.path == iCloudDriveFolder.path { return iCloudDrive(at: url) }
        guard url.deletingLastPathComponent().standardizedFileURL.path == fileProviderFolder.path,
              !url.lastPathComponent.hasPrefix(".") else { return nil }
        return root(named: url.lastPathComponent, at: url)
    }

    /// The cloud root `url` is in (or is).
    public static func root(containing url: URL) -> CloudRoot? {
        root(containing: url, fileProviderFolder: fileProviderFolder, iCloudDriveFolder: iCloudDriveFolder)
    }

    static func root(containing url: URL, fileProviderFolder: URL, iCloudDriveFolder: URL) -> CloudRoot? {
        let path = url.standardizedFileURL.path
        if path == iCloudDriveFolder.path || path.hasPrefix(iCloudDriveFolder.path + "/") {
            return iCloudDrive(at: iCloudDriveFolder)
        }
        let prefix = fileProviderFolder.path + "/"
        guard path.hasPrefix(prefix),
              let name = path.dropFirst(prefix.count).split(separator: "/").first,
              !name.hasPrefix(".") else { return nil }
        return root(named: String(name), at: fileProviderFolder.appendingPathComponent(String(name), isDirectory: true))
    }

    /// Whether `url` is a cloud folder or inside one.
    public static func isInCloudFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == iCloudDriveFolder.path
            || [fileProviderFolder, iCloudDriveFolder].contains { path.hasPrefix($0.path + "/") }
    }

    /// Whether `path` is inside a cloud folder of the user whose home folder is `home`.
    public static func contains(_ path: String, home: String) -> Bool {
        let home = URL(fileURLWithPath: home, isDirectory: true)
        return [fileProviderFolder(home: home), iCloudDriveFolder(home: home)]
            .contains { path.hasPrefix($0.path + "/") }
    }

    private static func iCloudDrive(at url: URL) -> CloudRoot {
        CloudRoot(url: url, provider: .iCloudDrive, title: "iCloud Drive")
    }

    /// Provider and title from a `~/Library/CloudStorage` folder name, styled as Windows names
    /// them: "OneDrive - Personal", "OneDrive - Contoso", a SharePoint organisation's own name.
    static func root(named name: String, at url: URL) -> CloudRoot {
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let prefix = parts[0]
        let account = parts.count > 1 ? parts[1] : nil

        func titled(_ provider: CloudRoot.Provider, _ title: String) -> CloudRoot {
            CloudRoot(url: url, provider: provider, title: title)
        }

        switch prefix.lowercased() {
        case "onedrive":
            guard let account else { return titled(.oneDrive, "OneDrive") }
            let sharedLibraries = "SharedLibraries-"
            if account.hasPrefix(sharedLibraries), account.count > sharedLibraries.count {
                return titled(.sharePoint, String(account.dropFirst(sharedLibraries.count)))
            }
            return titled(.oneDrive, "OneDrive - \(account)")
        case "googledrive":
            return titled(.googleDrive, account.map { "Google Drive (\($0))" } ?? "Google Drive")
        case "dropbox":
            return titled(.dropbox, account.map { "Dropbox (\($0))" } ?? "Dropbox")
        case "box":
            // Box's folder is "Box-Box".
            guard let account, account.lowercased() != "box" else { return titled(.box, "Box") }
            return titled(.box, "Box (\(account))")
        default:
            return titled(.other, FileManager.default.displayName(atPath: url.path))
        }
    }
}
