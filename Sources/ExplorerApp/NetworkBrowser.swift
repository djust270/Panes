import AppKit
import ExplorerCore

/// Finds computers sharing files on the local network (Bonjour: SMB and AFP) for Network,
/// and adds the servers of mounted shares and mapped drives. Starts the first time Network is
/// shown and keeps browsing, posting `didChangeNotification` as computers come and go.
@MainActor
final class NetworkBrowser: NSObject {
    static let shared = NetworkBrowser()
    static let didChangeNotification = Notification.Name("NetworkBrowserDidChange")

    private static let serviceTypes = ["_smb._tcp.": "smb", "_afpovertcp._tcp.": "afp"]

    private var browsers: [NetServiceBrowser] = []
    /// Services found, kept while they resolve (and so they stay alive).
    private var services: [NetService] = []
    /// Resolved computers, by service name and type.
    private var advertised: [String: NetworkComputer] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        for type in Self.serviceTypes.keys {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    /// Everything Network shows, by name.
    func computers() -> [NetworkComputer] {
        let mounted = VolumeLister.mountedVolumes().compactMap(\.remountURL)
        let shares = mounted + DriveCenter.store.mappedDrives.map(\.shareURL)
        return NetworkNeighborhood.computers(advertised: Array(advertised.values), shares: shares)
    }

    /// Calls `body` after every change, until the returned token is released.
    static func observe(_ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    private static func key(_ service: NetService) -> String {
        service.name + "|" + service.type
    }

    private func found(_ service: NetService) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 10)
    }

    private func removed(_ service: NetService) {
        services.removeAll { Self.key($0) == Self.key(service) }
        if advertised.removeValue(forKey: Self.key(service)) != nil {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private func resolved(_ service: NetService) {
        services.removeAll { $0 === service }
        guard let hostName = service.hostName, let scheme = Self.serviceTypes[service.type] else { return }
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        guard let url = URL(string: "\(scheme)://\(host)") else { return }
        advertised[Self.key(service)] = NetworkComputer(name: service.name, url: url)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

extension NetworkBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    // Browsers and services are scheduled on the main run loop, so callbacks arrive on main.
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated { found(service) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated { removed(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        nonisolated(unsafe) let service = sender
        MainActor.assumeIsolated { resolved(service) }
    }
}
