import Foundation

/// Preference + fallback for replacing the stock macOS volume / brightness HUD.
///
/// **Primary path** (Tahoe+): `MediaKeyInterceptor` consumes the keys before
/// the OS handles them, so Control Center never draws its OSD. That needs
/// Accessibility.
///
/// **Fallback:** kill `OSDUIHelper` when we only *observe* key events (older
/// macOS, or Accessibility not yet granted). Launchd respawns it; a timely
/// kill often blanks the bezel. Prefer the Preferences toggle so users can
/// restore the system HUD anytime.
enum SystemOSDSuppressor {
    static let preferenceKey = "dynamo.system.replaceSystemOSD"
    static let didChangeNotification = Notification.Name("dynamo.system.replaceSystemOSD.didChange")

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: preferenceKey) == nil {
                return true // Dynamo takes over by default
            }
            return UserDefaults.standard.bool(forKey: preferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Fire-and-forget kill of OSDUIHelper. Safe to call often; coalesce bursts.
    private static var lastKillAt: Date = .distantPast

    static func suppressIfEnabled() {
        guard isEnabled else { return }
        let now = Date()
        // Coalesce rapid volume key repeats.
        guard now.timeIntervalSince(lastKillAt) > 0.12 else { return }
        lastKillAt = now
        DispatchQueue.global(qos: .userInitiated).async {
            func killOSD() {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                task.arguments = ["-9", "OSDUIHelper"]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()
            }
            killOSD()
            // Second shot covers a slow launchd respawn racing the first kill.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08) {
                killOSD()
            }
        }
    }
}
