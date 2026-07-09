import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Works best when running as a
/// real .app bundle (`scripts/package-app.sh`); bare SPM executables may be
/// rejected by the system login-item machinery.
@MainActor
enum LaunchAtLogin {
    private static let defaultsKey = "dynamo.launchAtLogin"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            apply(enabled: newValue)
        }
    }

    static func applyStoredPreference() {
        // Re-assert the stored preference on launch so a reinstall stays in sync.
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            apply(enabled: isEnabled)
        }
    }

    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    if service.status != .enabled {
                        try service.register()
                    }
                } else {
                    if service.status != .notRegistered {
                        try service.unregister()
                    }
                }
                return true
            } catch {
                NSLog("Dynamo: Launch at Login failed: %@", error.localizedDescription)
                return false
            }
        }
        return false
    }

    static var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "Enabled"
            case .requiresApproval: return "Requires approval in System Settings → General → Login Items"
            case .notFound: return "Not available (run the packaged .app)"
            case .notRegistered: return "Off"
            @unknown default: return "Unknown"
            }
        }
        return "Requires macOS 13+"
    }
}
