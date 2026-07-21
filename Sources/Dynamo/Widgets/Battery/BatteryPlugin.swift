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

    var expandedContentHeight: CGFloat { 280 }

    // MARK: - Snapshot pipeline

    private func handleSnapshot(_ value: BatterySnapshot) {
        snapshot = value
        power.refresh()
        history.record(snapshot: value, isLowPowerMode: power.isLowPowerModeEnabled)
        power.considerAutoEnable(snapshot: value)
        recomputeInsight()
        objectWillChange.send()
    }

    private func recomputeInsight() {
        insight = BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    func toggleLowPowerMode() {
        power.toggleLowPowerMode()
        // Immediate UI; ProcessInfo may lag.
        recomputeInsight()
        objectWillChange.send()
    }

    func setAutoLowPower(_ enabled: Bool) {
        power.autoEnableEnabled = enabled
        objectWillChange.send()
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
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct ExpandedBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared
    @ObservedObject private var history = BatteryHistoryStore.shared

    private var snapshot: BatterySnapshot { plugin.snapshot }
    private var insight: BatteryInsight {
        // Live recompute so UI tracks history without stale plugin cache edge cases.
        BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            NotchSectionHeader(
                "Battery",
                trailing: snapshot.isPresent
                    ? AnyView(
                        Text(insight.healthLabel)
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
                // Charge level
                NotchCard(compact: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: NotchTheme.spaceSM) {
                            Text("\(snapshot.percent)%")
                                .font(NotchTheme.heroDigit.monospacedDigit())
                                .foregroundStyle(barColor)
                            VStack(alignment: .leading, spacing: 2) {
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
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NotchTheme.chipFill)
                                Capsule()
                                    .fill(barColor)
                                    .frame(width: max(8, geo.size.width * CGFloat(snapshot.percent) / 100))
                            }
                        }
                        .frame(height: 7)
                    }
                }

                // Health model
                NotchCard(compact: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Health")
                                .font(NotchTheme.micro.weight(.semibold))
                                .foregroundStyle(NotchTheme.textTertiary)
                                .textCase(.uppercase)
                            Spacer()
                            Text("\(insight.healthScore)%")
                                .font(NotchTheme.body.weight(.semibold).monospacedDigit())
                                .foregroundStyle(healthColor)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NotchTheme.chipFill)
                                Capsule()
                                    .fill(healthColor.opacity(0.9))
                                    .frame(width: max(6, geo.size.width * CGFloat(insight.healthScore) / 100))
                            }
                        }
                        .frame(height: 5)

                        HStack(spacing: 10) {
                            if let cycles = snapshot.cycleCount {
                                metricChip("Cycles", "\(cycles)")
                            }
                            if let drain = insight.drainPercentPerHour {
                                metricChip("Drain", String(format: "%.1f%%/h", drain))
                            }
                            metricChip("Samples", "\(insight.samplesUsed)")
                        }

                        Text(insight.summary)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(insight.tip)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Power saving controls
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

    private var displayMinutes: Int? {
        if snapshot.isCharging {
            return insight.predictedToFullMinutes ?? snapshot.timeRemainingMinutes
        }
        return insight.predictedRemainingMinutes ?? snapshot.timeRemainingMinutes
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

    private var barColor: Color {
        if power.isLowPowerModeEnabled { return NotchTheme.caution }
        if snapshot.isCharging { return NotchTheme.positive }
        if snapshot.percent <= 15 { return NotchTheme.negative }
        if snapshot.percent <= 25 { return NotchTheme.caution }
        return NotchTheme.textPrimary
    }

    private var healthColor: Color {
        let s = insight.healthScore
        if s >= 85 { return NotchTheme.positive }
        if s >= 70 { return NotchTheme.caution }
        return NotchTheme.negative
    }
}
