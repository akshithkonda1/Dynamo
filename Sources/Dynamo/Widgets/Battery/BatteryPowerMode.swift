import AppKit
import Foundation

/// System power-mode profile Dynamo can set (best-effort via `pmset`).
///
/// - **Low Power** — macOS Low Power Mode (battery thrift)
/// - **Automatic** — neither forced low nor high (system default)
/// - **High Power** — High Power Mode when the Mac supports it (typically AC)
enum DynamoPowerMode: String, CaseIterable, Identifiable {
    case low
    case automatic
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .automatic: return "Auto"
        case .high: return "High"
        }
    }

    var systemImage: String {
        switch self {
        case .low: return "leaf.fill"
        case .automatic: return "circle.lefthalf.filled"
        case .high: return "bolt.fill"
        }
    }

    var help: String {
        switch self {
        case .low: return "Low Power Mode — stretch battery"
        case .automatic: return "Automatic — system default power profile"
        case .high: return "High Power Mode — max performance when available"
        }
    }
}

/// Observes and sets macOS power modes (Low Power / Automatic / High Power).
///
/// Reading uses `ProcessInfo` + `pmset -g custom`. Writes use `pmset`
/// (works without admin on many Macs for the current power source).
/// If a write fails we open System Settings → Battery.
@MainActor
final class BatteryPowerMode: ObservableObject {
    static let shared = BatteryPowerMode()

    @Published private(set) var isLowPowerModeEnabled: Bool = false
    @Published private(set) var isHighPowerModeEnabled: Bool = false
    /// Whether this Mac reports highpowermode support via pmset.
    @Published private(set) var supportsHighPowerMode: Bool = false
    @Published private(set) var activeMode: DynamoPowerMode = .automatic
    @Published private(set) var lastError: String?

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
        let pm = Self.readPmsetCustom()
        supportsHighPowerMode = pm.mentionsHighPower
        isHighPowerModeEnabled = pm.highPowerOn
        // ProcessInfo is authoritative for LPM; pmset fills High Power.
        if isLowPowerModeEnabled {
            activeMode = .low
        } else if isHighPowerModeEnabled {
            activeMode = .high
        } else {
            activeMode = .automatic
        }
    }

    /// Apply a power mode profile. Returns true if the command appeared to succeed.
    @discardableResult
    func setMode(_ mode: DynamoPowerMode) -> Bool {
        lastError = nil
        switch mode {
        case .low:
            return setLowPowerMode(true)
        case .automatic:
            // Clear both extremes.
            let lowOff = setLowPowerMode(false, openSettingsOnFail: false)
            let highOff = setHighPowerMode(false, openSettingsOnFail: false)
            if lowOff || highOff {
                activeMode = .automatic
                scheduleRefresh()
                return true
            }
            lastError = "Couldn’t reset power mode — open Battery settings"
            openBatterySettings()
            return false
        case .high:
            // High Power is typically AC-only; turn LPM off first.
            _ = setLowPowerMode(false, openSettingsOnFail: false)
            return setHighPowerMode(true)
        }
    }

    /// Toggle system Low Power Mode. Returns true if the command appeared to succeed.
    @discardableResult
    func setLowPowerMode(_ enabled: Bool, openSettingsOnFail: Bool = true) -> Bool {
        let flag = enabled ? "1" : "0"
        // Battery-scoped first (laptops), then all sources.
        let commands = [
            "/usr/bin/pmset -b lowpowermode \(flag)",
            "/usr/bin/pmset -a lowpowermode \(flag)"
        ]
        for cmd in commands {
            if runShell(cmd) {
                isLowPowerModeEnabled = enabled
                if enabled {
                    isHighPowerModeEnabled = false
                    activeMode = .low
                } else if !isHighPowerModeEnabled {
                    activeMode = .automatic
                }
                scheduleRefresh()
                return true
            }
        }
        if openSettingsOnFail {
            lastError = "Low Power Mode needs Battery settings"
            openBatterySettings()
        }
        return false
    }

    @discardableResult
    func setHighPowerMode(_ enabled: Bool, openSettingsOnFail: Bool = true) -> Bool {
        let flag = enabled ? "1" : "0"
        // High Power is usually AC-scoped (`-c`); try all sources as fallback.
        let commands = [
            "/usr/bin/pmset -c highpowermode \(flag)",
            "/usr/bin/pmset -a highpowermode \(flag)"
        ]
        for cmd in commands {
            if runShell(cmd) {
                isHighPowerModeEnabled = enabled
                supportsHighPowerMode = true
                if enabled {
                    isLowPowerModeEnabled = false
                    activeMode = .high
                } else if !isLowPowerModeEnabled {
                    activeMode = .automatic
                }
                scheduleRefresh()
                return true
            }
        }
        // Probe once so UI can hide High if unsupported.
        let pm = Self.readPmsetCustom()
        supportsHighPowerMode = pm.mentionsHighPower
        if openSettingsOnFail {
            lastError = supportsHighPowerMode
                ? "High Power Mode needs AC power or Battery settings"
                : "This Mac doesn’t expose High Power Mode"
            if supportsHighPowerMode {
                openBatterySettings()
            }
        }
        return false
    }

    func toggleLowPowerMode() {
        if isLowPowerModeEnabled {
            _ = setMode(.automatic)
        } else {
            _ = setMode(.low)
        }
    }

    /// Called when battery snapshot updates — applies Dynamo auto Low Power policy.
    func considerAutoEnable(snapshot: BatterySnapshot) {
        guard autoEnableEnabled, snapshot.isPresent else { return }
        guard !snapshot.isCharging, !snapshot.isPluggedIn else { return }
        guard snapshot.percent <= autoEnableAtPercent, snapshot.percent >= 0 else { return }
        guard !isLowPowerModeEnabled else { return }
        // Don’t fight user High Power on AC (we already guard unplugged).
        _ = setLowPowerMode(true)
    }

    func openBatterySettings() {
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

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refresh()
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

    private struct PmsetSnapshot {
        var lowPowerOn: Bool = false
        var highPowerOn: Bool = false
        var mentionsHighPower: Bool = false
    }

    private static func readPmsetCustom() -> PmsetSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            var snap = PmsetSnapshot()
            for line in text.lowercased().split(separator: "\n") {
                let s = String(line)
                if s.contains("lowpowermode") {
                    snap.lowPowerOn = s.contains("1")
                }
                if s.contains("highpowermode") {
                    snap.mentionsHighPower = true
                    snap.highPowerOn = s.contains("1")
                }
            }
            return snap
        } catch {
            return PmsetSnapshot()
        }
    }
}
