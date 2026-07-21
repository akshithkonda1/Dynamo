import AppKit
import Foundation

/// Where a Mac Health row should take the user when tapped.
/// Opens the right System Settings pane / app so they can act — Dynamo never
/// installs updates or restarts without the user’s system UI.
enum MacHealthDestination: String, Codable, Equatable {
    case none
    case softwareUpdate
    case storage
    case battery
    case aboutThisMac
    case activityMonitor
    /// Apple menu Restart path via loginwindow (shows system confirm dialog).
    case restart
    case generalSettings
}

extension MacHealthFinding {
    /// Default destination for known finding ids.
    var destination: MacHealthDestination {
        switch id {
        case "updates": return .softwareUpdate
        case "disk": return .storage
        case "uptime": return .restart
        case "thermal", "memory": return .activityMonitor
        case "lpm": return .battery
        case "os": return .aboutThisMac
        default: return .none
        }
    }

    /// Short CTA shown on interactive chips.
    var actionLabel: String? {
        switch destination {
        case .none: return nil
        case .softwareUpdate: return "Updates"
        case .storage: return "Storage"
        case .battery: return "Battery"
        case .aboutThisMac: return "About"
        case .activityMonitor: return "Monitor"
        case .restart: return "Restart…"
        case .generalSettings: return "Settings"
        }
    }
}

/// Opens System Settings panes and apps for health remediation.
enum MacHealthActions {
    @MainActor
    static func open(_ destination: MacHealthDestination) {
        switch destination {
        case .none:
            return
        case .softwareUpdate:
            openURLs([
                "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
                "x-apple.systempreferences:com.apple.preferences.softwareupdate",
                "x-apple.systempreferences:com.apple.Software-Update-Settings.extension?showUpdates=true"
            ], fallbackBundle: "com.apple.systempreferences")
        case .storage:
            openURLs([
                "x-apple.systempreferences:com.apple.settings.Storage",
                "x-apple.systempreferences:com.apple.preferences.general",
                "x-apple.systempreferences:com.apple.General-Settings.extension"
            ], fallbackBundle: "com.apple.systempreferences")
        case .battery:
            openURLs([
                "x-apple.systempreferences:com.apple.settings.Battery",
                "x-apple.systempreferences:com.apple.preference.battery",
                "x-apple.systempreferences:com.apple.Battery-Settings.extension"
            ], fallbackBundle: "com.apple.systempreferences")
        case .aboutThisMac:
            // Ventura+: System Settings → General → About
            openURLs([
                "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension",
                "x-apple.systempreferences:com.apple.General-Settings.extension?About",
                "x-apple.systempreferences:com.apple.preference.general"
            ], fallbackBundle: "com.apple.systempreferences")
        case .activityMonitor:
            openApp(bundleID: "com.apple.ActivityMonitor", path: "/System/Applications/Utilities/Activity Monitor.app")
        case .restart:
            // System restart confirmation only (user must confirm in the OS sheet).
            presentRestartDialog()
        case .generalSettings:
            openURLs([
                "x-apple.systempreferences:com.apple.General-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.general"
            ], fallbackBundle: "com.apple.systempreferences")
        }
    }

    /// When updates require restart — open Software Update (install + restart UI).
    @MainActor
    static func openInstallAndRestart() {
        open(.softwareUpdate)
    }

    /// System restart confirmation dialog (user still has to confirm).
    @MainActor
    static func presentRestartDialog() {
        // Uses AppleScript so the OS shows its own “Are you sure?” sheet.
        // Never force-restarts without that dialog.
        runAppleScript("""
        try
          tell application "loginwindow" to «event aevtrrst»
        on error
          try
            tell application "System Events" to restart
          end try
        end try
        """)
    }

    // MARK: - Helpers

    @MainActor
    private static func openURLs(_ raws: [String], fallbackBundle: String?) {
        for raw in raws {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let fallbackBundle,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fallbackBundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @MainActor
    private static func openApp(bundleID: String, path: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let file = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: file, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
    }
}
