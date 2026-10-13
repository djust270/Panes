import Foundation

/// A computer shown under Network.
public struct NetworkComputer: Sendable, Hashable {
    /// The Bonjour name ("Dave’s NAS") or the host name.
    public let name: String
    /// `smb://host` (or `afp://host`), opened to choose a share.
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// What Network lists: computers advertising file sharing over Bonjour, plus the servers of
/// mounted network shares and mapped drives (servers that don't advertise themselves, like
/// most Windows PCs and NAS boxes, would otherwise be missing). One entry per host, SMB
/// preferred; Bonjour names win over bare host names.
public enum NetworkNeighborhood {
    public static func computers(advertised: [NetworkComputer], shares: [URL]) -> [NetworkComputer] {
        var byHost: [String: NetworkComputer] = [:]
        func key(_ url: URL) -> String {
            (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        func add(_ computer: NetworkComputer) {
            let host = key(computer.url)
            guard !host.isEmpty else { return }
            if let existing = byHost[host], existing.url.scheme == "smb" || computer.url.scheme != "smb" { return }
            byHost[host] = computer
        }
        advertised.forEach(add)
        for share in shares {
            guard let server = NetworkPath.serverURL(for: share), let host = server.host else { continue }
            add(NetworkComputer(name: host, url: server))
        }
        return byHost.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
