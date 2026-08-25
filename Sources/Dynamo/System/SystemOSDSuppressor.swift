import Foundation

/// Best-effort suppression of the stock macOS volume / brightness bezel
/// (`OSDUIHelper`). Launchd respawns it; killing it at the moment of a key
/// press usually prevents the system overlay from appearing while Dynamo’s
/// notch Peek/HUD owns the feedback.
///
/// This is the same approach used by notch HUD apps (Notchy / SlimHUD-style).
/// It does **not** require SIP off. Prefer the Preferences toggle so users can
/// restore the system HUD anytime.
enum SystemOSDSuppressor {
    private static let preferenceKey = "dynamo.system.replaceSystemOSD"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: preferenceKey) == nil {
                return true // Dynamo takes over by default
            }
            return UserDefaults.standard.bool(forKey: preferenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
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
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["-9", "OSDUIHelper"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
        }
    }
}
