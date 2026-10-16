import Foundation
import ServiceManagement

/// Starting at login, so True Liquid Glass runs as a background service.
enum LoginItem {
    enum State {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    private static let configuredKey = "loginItemConfigured"

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }

    /// Returns false (and logs why) when macOS refused the change.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            logInfo("Login item \(enabled ? "enabled" : "disabled") (state: \(state))")
            return true
        } catch {
            logError("Could not \(enabled ? "enable" : "disable") the login item: \(error.liquidDescription)")
            return false
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The app is meant to run as a service: switch "start at login" on once, the first time
    /// it runs from Applications. Afterwards the user's choice is respected.
    static func enableOnFirstLaunchIfInstalled(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: configuredKey) else { return }
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !path.contains("/AppTranslocation/") else { return }
        defaults.set(true, forKey: configuredKey)
        if state != .enabled { setEnabled(true) }
    }
}
