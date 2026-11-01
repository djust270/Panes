import Foundation

/// An SSH server remembered by "Connect to SSH Server", listed under Network.
public struct SavedRemoteConnection: Sendable, Hashable, Codable {
    public var host: RemoteHost
    /// The folder to open; empty for the home folder.
    public var startPath: String

    public init(host: RemoteHost, startPath: String = "") {
        self.host = host
        self.startPath = startPath
    }

    public var location: RemotePath {
        RemotePath(host: host, path: startPath)
    }
}

/// Saved SSH connections, in the order they were added. One per host.
public final class RemoteConnectionStore {
    private static let storageKey = "RemoteConnections.v1"
    private let defaults: UserDefaults
    public private(set) var connections: [SavedRemoteConnection]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SavedRemoteConnection].self, from: data) {
            connections = decoded
        } else {
            connections = []
        }
    }

    /// Adds `connection`, replacing a saved one for the same host (keeping its place).
    public func save(_ connection: SavedRemoteConnection) {
        if let index = connections.firstIndex(where: { $0.host.key == connection.host.key }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    public func remove(_ host: RemoteHost) {
        connections.removeAll { $0.host.key == host.key }
        persist()
    }

    public func connection(for host: RemoteHost) -> SavedRemoteConnection? {
        connections.first { $0.host.key == host.key }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
