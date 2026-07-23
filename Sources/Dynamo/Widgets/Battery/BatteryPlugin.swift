import SwiftUI

@MainActor
final class BatteryPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding {
    let id = "battery"
    let displayName = "Battery"
    let systemImage = "battery.100"

    @Published private(set) var snapshot: BatterySnapshot = .unknown
    @Published private(set) var insight: BatteryInsight = BatteryHealthModel.insight(
        snapshot: .unknown,
        samples: []
    )

    private let provider: BatteryProvider
    private let history = BatteryHistoryStore.shared
    private let power = BatteryPowerMode.shared
    private var powerCancellable: Any?

    init(provider: BatteryProvider? = nil) {
        let resolved = provider ?? IOKitBatteryProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] value in
            self?.handleSnapshot(value)
        }
    }

    func start() {
        provider.start()
        handleSnapshot(provider.current)
        // Recompute insight when Low Power Mode flips system-side.
        powerCancellable = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.power.refresh()
                self?.recomputeInsight()
            }
        }
    }

    func stop() {
        provider.stop()
        if let powerCancellable {
            NotificationCenter.default.removeObserver(powerCancellable)
            self.powerCancellable = nil
        }
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedBatteryView(plugin: self))
    }

    /// Match Media / Calendar / Shelf / Webcam so tab switches don’t drop taller.
    var expandedContentHeight: CGFloat { 255 }

    // MARK: - Snapshot pipeline

    private func handleSnapshot(_ value: BatterySnapshot) {
        snapshot = value
        power.refresh()
        history.record(snapshot: value, isLowPowerMode: power.isLowPowerModeEnabled)
        power.considerAutoEnable(snapshot: value)
        recomputeInsight()
    }

    private func recomputeInsight() {
        insight = BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    func toggleLowPowerMode() {
        power.toggleLowPowerMode()
        // Immediate UI; ProcessInfo may lag.
        recomputeInsight()
    }

    func setAutoLowPower(_ enabled: Bool) {
        power.autoEnableEnabled = enabled
    }

    var isLowPowerModeEnabled: Bool { power.isLowPowerModeEnabled }
    var autoLowPowerEnabled: Bool { power.autoEnableEnabled }
    var autoLowPowerThreshold: Int { power.autoEnableAtPercent }

    // MARK: Ambient

    var isAmbientActive: Bool {
        guard snapshot.isPresent else { return false }
        if power.isLowPowerModeEnabled { return true }
        return snapshot.percent <= 20
    }

    var ambientPriority: Int {
        if power.isLowPowerModeEnabled { return 65 }
        if snapshot.isPresent, snapshot.percent <= 10 { return 90 }
        if snapshot.isPresent, snapshot.percent <= 15 { return 80 }
        if snapshot.isPresent, snapshot.percent <= 20 { return 70 }
        return 10
    }

    func ambientView() -> AnyView {
        AnyView(AmbientBatteryView(snapshot: snapshot, lowPower: power.isLowPowerModeEnabled))
    }
}

// MARK: - Ambient

private struct AmbientBatteryView: View {
    let snapshot: BatterySnapshot
    var lowPower: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(snapshot.percent)%")
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            if lowPower {
                Text("LPM")
                    .font(NotchTheme.micro.weight(.bold))
                    .foregroundStyle(NotchTheme.caution)
            } else if let mins = snapshot.timeRemainingMinutes {
                Text(timeString(mins))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timeString(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return "~\(h)h \(m)m" }
        return "~\(m)m"
    }

    private var iconName: String {
        if lowPower { return "leaf.fill" }
        if snapshot.isCharging { return "bolt.fill" }
        if snapshot.percent <= 15 { return "battery.0" }
        if snapshot.percent <= 40 { return "battery.25" }
        return "battery.50"
    }

    private var tint: Color {
        if lowPower { return NotchTheme.caution }
        if snapshot.isCharging { return NotchTheme.positive }
        if snapshot.percent <= 15 { return NotchTheme.negative }
        if snapshot.percent <= 20 { return NotchTheme.caution }
        return NotchTheme.textSecondary
    }
}

// MARK: - Expanded
// Compact, peer-height layout. Metrics are read-only from IOKit / ProcessInfo
// (charge %, cycles, design/max capacity, OS time remaining). Local drain
// history is secondary; nothing here invents battery capacity.

private struct ExpandedBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared
    @ObservedObject private var history = BatteryHistoryStore.shared

    private var snapshot: BatterySnapshot { plugin.snapshot }
    private var insight: BatteryInsight {
        BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    /// Prefer firmware max/design capacity when IOKit reports it.
    private var hardwareHealth: Int? { snapshot.hardwareHealthPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            NotchSectionHeader(
                "Battery",
                trailing: snapshot.isPresent
                    ? AnyView(
                        Text(headerHealthLabel)
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(healthColor)
                    )
                    : nil
            )

            if !snapshot.isPresent {
                NotchEmptyState(
                    systemImage: "laptopcomputer",
                    title: "No internal battery",
                    caption: "Desktop Mac or power source unavailable.",
                    prominent: true
                )
            } else {
                // Charge + status — system IOKit values only
                NotchCard(compact: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: NotchTheme.spaceSM) {
                            Text("\(snapshot.percent)%")
                                .font(NotchTheme.heroDigit.monospacedDigit())
                                .foregroundStyle(barColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(statusLabel)
                                    .font(NotchTheme.body)
                                    .foregroundStyle(NotchTheme.textSecondary)
                                if let minutes = displayMinutes {
                                    Text(timeLabel(minutes))
                                        .font(NotchTheme.caption)
                                        .foregroundStyle(NotchTheme.textTertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            if let hw = hardwareHealth {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("Health")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(NotchTheme.textQuaternary)
                                    Text("\(hw)%")
                                        .font(NotchTheme.body.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(healthColor)
                                }
                            }
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NotchTheme.chipFill)
                                Capsule()
                                    .fill(barColor)
                                    .frame(width: max(8, geo.size.width * CGFloat(snapshot.percent) / 100))
                            }
                        }
                        .frame(height: 6)

                        // Read-only system metrics row
                        HStack(spacing: 12) {
                            if let cycles = snapshot.cycleCount {
                                metricChip("Cycles", "\(cycles)")
                            }
                            if let maxC = snapshot.maxCapacity, let design = snapshot.designCapacity, design > 0 {
                                metricChip("Capacity", "\(maxC)/\(design)")
                            } else if let maxC = snapshot.maxCapacity {
                                metricChip("Max cap", "\(maxC)")
                            }
                            if let temp = snapshot.temperatureC {
                                metricChip("Temp", String(format: "%.0f°C", temp))
                            }
                            if let drain = insight.drainPercentPerHour {
                                metricChip("Drain", String(format: "%.1f%%/h", drain))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                // Low Power Mode (writes only on explicit user toggle)
                HStack(spacing: 8) {
                    Button {
                        plugin.toggleLowPowerMode()
                    } label: {
                        NotchChipLabel(
                            title: power.isLowPowerModeEnabled ? "Low Power On" : "Low Power",
                            systemImage: "leaf.fill",
                            active: power.isLowPowerModeEnabled
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Toggle macOS Low Power Mode")

                    Button {
                        plugin.setAutoLowPower(!power.autoEnableEnabled)
                    } label: {
                        NotchChipLabel(
                            title: power.autoEnableEnabled
                                ? "Auto ≤\(power.autoEnableAtPercent)%"
                                : "Auto off",
                            systemImage: "bolt.badge.automatic",
                            active: power.autoEnableEnabled
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Automatically enable Low Power Mode when battery is low and unplugged")

                    Spacer(minLength: 0)
                }

                Text(footerNote)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            power.refresh()
        }
    }

    private func metricChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
            Text(value)
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    /// Prefer macOS IOKit time remaining; fall back to local rate estimate.
    private var displayMinutes: Int? {
        if let os = snapshot.timeRemainingMinutes { return os }
        if snapshot.isCharging {
            return insight.predictedToFullMinutes
        }
        return insight.predictedRemainingMinutes
    }

    private var statusLabel: String {
        if power.isLowPowerModeEnabled { return "Low Power Mode" }
        if snapshot.isCharging { return "Charging" }
        if snapshot.isPluggedIn { return "Plugged in" }
        return "On battery"
    }

    private func timeLabel(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if snapshot.isCharging {
            return h > 0 ? "~\(h)h \(m)m to full" : "~\(m)m to full"
        }
        return h > 0 ? "~\(h)h \(m)m remaining" : "~\(m)m remaining"
    }

    private var headerHealthLabel: String {
        if let hw = hardwareHealth {
            return BatteryHealthModel.healthLabel(for: hw)
        }
        if let cycles = snapshot.cycleCount {
            return "\(cycles) cycles"
        }
        return "System"
    }

    private var footerNote: String {
        if let tip = compactTip { return tip }
        return "Read-only from this Mac’s battery (IOKit)."
    }

    private var compactTip: String? {
        if snapshot.percent <= 20, !power.isLowPowerModeEnabled, !snapshot.isCharging {
            return "Enable Low Power Mode to stretch remaining charge."
        }
        if let drain = insight.drainPercentPerHour, drain > 18 {
            return "High drain — bright display and heavy apps shorten runtime."
        }
        if let hw = hardwareHealth, hw < 80 {
            return "Capacity reduced — keep charge between ~20–80% when you can."
        }
        return nil
    }

    private var barColor: Color {
        if power.isLowPowerModeEnabled { return NotchTheme.caution }
        if snapshot.isCharging { return NotchTheme.positive }
        if snapshot.percent <= 15 { return NotchTheme.negative }
        if snapshot.percent <= 25 { return NotchTheme.caution }
        return NotchTheme.textPrimary
    }

    private var healthColor: Color {
        let s = hardwareHealth ?? insight.healthScore
        if s >= 85 { return NotchTheme.positive }
        if s >= 70 { return NotchTheme.caution }
        if hardwareHealth == nil, insight.healthScore == 0 { return NotchTheme.textTertiary }
        return NotchTheme.negative
    }
}
