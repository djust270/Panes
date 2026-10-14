import AppKit
import ServiceManagement

/// Settings › "Start Explorer when you sign in", through the system's Login Items (so it also
/// shows, and can be turned off, in System Settings › General › Login Items). Mapped drives
/// set to reconnect are reconnected at that launch. Only available from the app bundle.
@MainActor
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        isAvailable && [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    /// The user turned it off in System Settings, or hasn't approved it yet.
    static var needsApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }

    /// Turns it on or off; returns an error message on failure.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
