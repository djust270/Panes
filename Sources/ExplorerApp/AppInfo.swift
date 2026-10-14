import AppKit

/// The running app's version and where it's developed (issues, releases).
@MainActor
enum AppInfo {
    /// "Panes": the bundle's name (scripts/bundle.sh `APP_NAME`), also when run unbundled.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Panes"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var osVersion: String {
        "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Set by scripts/bundle.sh (`REPO_URL`).
    static var repositoryURL: URL {
        (Bundle.main.object(forInfoDictionaryKey: "ExplorerRepositoryURL") as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/djust270/osx-explorer")!
    }

    /// GitHub's "New issue" page, prefilled. GitHub refuses very long URLs, so `body` is
    /// expected to be short (a few KB).
    static func newIssueURL(title: String, body: String, labels: [String] = []) -> URL {
        var components = URLComponents(url: repositoryURL.appendingPathComponent("issues/new"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        if !labels.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "labels", value: labels.joined(separator: ",")))
        }
        return components.url!
    }
}
