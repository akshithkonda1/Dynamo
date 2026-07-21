import AppKit
import Foundation

/// Observes and toggles macOS Low Power Mode (best-effort).
///
/// Reading uses `ProcessInfo.isLowPowerModeEnabled`. Enabling/disabling uses
/// `pmset` (works without admin on many Macs for the current power source);
/// if that fails we open System Settings → Battery.
@MainActor
final class BatteryPowerMode: ObservableObject {
    static let shared = BatteryPowerMode()

    @Published private(set) var isLowPowerModeEnabled: Bool = false
    /// Dynamo soft policy: auto-enable system Low Power Mode at/under threshold when unplugged.
    @Published var autoEnableAtPercent: Int {
        didSet { UserDefaults.standard.set(autoEnableAtPercent, forKey: Self.autoKey) }
    }
    @Published var autoEnableEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnableEnabled, forKey: Self.autoEnabledKey) }
    }

    private static let autoKey = "dynamo.battery.autoLowPowerPercent"
    private static let autoEnabledKey = "dynamo.battery.autoLowPowerEnabled"

    private var observer: NSObjectProtocol?

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoKey) == nil {
            autoEnableAtPercent = 20
        } else {
            autoEnableAtPercent = UserDefaults.standard.integer(forKey: Self.autoKey)
        }
        if UserDefaults.standard.object(forKey: Self.autoEnabledKey) == nil {
            autoEnableEnabled = true
        } else {
            autoEnableEnabled = UserDefaults.standard.bool(forKey: Self.autoEnabledKey)
        }
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Toggle system Low Power Mode. Returns true if the command appeared to succeed.
    @discardableResult
    func setLowPowerMode(_ enabled: Bool) -> Bool {
        // Prefer battery-scoped first (common for laptops), then all sources.
        let flag = enabled ? "1" : "0"
        let commands = [
            "/usr/bin/pmset -b lowpowermode \(flag)",
            "/usr/bin/pmset -a lowpowermode \(flag)"
        ]
        for cmd in commands {
            let ok = runShell(cmd)
            if ok {
                // pmset can lag a beat before ProcessInfo updates.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.refresh()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.refresh()
                }
                isLowPowerModeEnabled = enabled
                return true
            }
        }
        openBatterySettings()
        return false
    }

    func toggleLowPowerMode() {
        _ = setLowPowerMode(!isLowPowerModeEnabled)
    }

    /// Called when battery snapshot updates — applies Dynamo auto Low Power policy.
    func considerAutoEnable(snapshot: BatterySnapshot) {
        guard autoEnableEnabled, snapshot.isPresent else { return }
        guard !snapshot.isCharging, !snapshot.isPluggedIn else { return }
        guard snapshot.percent <= autoEnableAtPercent, snapshot.percent >= 0 else { return }
        guard !isLowPowerModeEnabled else { return }
        _ = setLowPowerMode(true)
    }

    func openBatterySettings() {
        // macOS Ventura+ Battery pane
        let urls = [
            "x-apple.systempreferences:com.apple.settings.Battery",
            "x-apple.systempreferences:com.apple.preference.battery",
            "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func runShell(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
