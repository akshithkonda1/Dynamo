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
    var expandedContentHeight: CGFloat { 268 }

    // MARK: - Snapshot pipeline

    /// Stages already announced (e.g. "p20", "p10", "p5") so we don't spam.
    private var notifiedBatteryStages: Set<String> = []

    private func handleSnapshot(_ value: BatterySnapshot) {
        snapshot = value
        power.refresh()
        history.record(snapshot: value, isLowPowerMode: power.isLowPowerModeEnabled)
        power.considerAutoEnable(snapshot: value)
        recomputeInsight()
        announceBatteryIfNeeded()
    }

    private func announceBatteryIfNeeded() {
        guard snapshot.isPresent, !snapshot.isCharging else {
            if snapshot.isCharging { notifiedBatteryStages.removeAll() }
            return
        }
        let p = snapshot.percent
        let stages: [(Int, String, NotchSneakPeekUrgency)] = [
            (5, "p5", .critical),
            (10, "p10", .critical),
            (15, "p15", .high),
            (20, "p20", .high)
        ]
        // Clear stages once charge recovers above their threshold (re-arm alerts).
        for (threshold, key, _) in stages where p > threshold {
            notifiedBatteryStages.remove(key)
        }
        for (threshold, key, urgency) in stages {
            guard p <= threshold, !notifiedBatteryStages.contains(key) else { continue }
            notifiedBatteryStages.insert(key)
            DynamoNotificationAPI.post(
                title: p <= 10 ? "Battery critically low" : "Battery low",
                subtitle: "\(p)% remaining" + (power.isLowPowerModeEnabled ? " · Low Power on" : ""),
                systemImage: "battery.0",
                urgency: urgency,
                category: "battery",
                id: "battery|\(key)"
            )
            break
        }
    }

    private func recomputeInsight() {
        insight = BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    func toggleLowPowerMode() {
        power.toggleLowPowerMode()
        // Immediate UI; ProcessInfo may lag.
        recomputeInsight()
    }

    func setPowerMode(_ mode: DynamoPowerMode) {
        _ = power.setMode(mode)
        recomputeInsight()
    }

    func setAutoLowPower(_ enabled: Bool) {
        power.autoEnableEnabled = enabled
    }

    var isLowPowerModeEnabled: Bool { power.isLowPowerModeEnabled }
    var autoLowPowerEnabled: Bool { power.autoEnableEnabled }
    var autoLowPowerThreshold: Int { power.autoEnableAtPercent }
    var activePowerMode: DynamoPowerMode { power.activeMode }

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
        HStack(spacing: 5) {
            // Mini fill glyph — reads at a glance in the collapsed notch.
            AmbientBatteryGlyph(percent: snapshot.percent, tint: tint, charging: snapshot.isCharging)
            Text("\(snapshot.percent)%")
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            if lowPower {
                Text("LPM")
                    .font(NotchTheme.micro.weight(.bold))
                    .foregroundStyle(NotchTheme.caution)
            }
            if !snapshot.isCharging, let min = snapshot.timeRemainingMinutes {
                let h = min / 60
                let m = min % 60
                Text(h > 0 ? "~\(h)h \(m)m" : "~\(m)m")
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            if let temp = snapshot.temperatureC, temp > 45 {
                Text("\(Int(temp))°")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.caution)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tint: Color {
        if lowPower { return NotchTheme.caution }
        if snapshot.isCharging { return NotchTheme.positive }
        if snapshot.percent <= 15 { return NotchTheme.negative }
        if snapshot.percent <= 20 { return NotchTheme.caution }
        return NotchTheme.textSecondary
    }
}

/// Compact battery shell with live fill — ambient only.
private struct AmbientBatteryGlyph: View {
    let percent: Int
    let tint: Color
    var charging: Bool = false

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                    .frame(width: 14, height: 8)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint)
                    .frame(width: max(1.5, 10 * CGFloat(min(100, max(0, percent))) / 100), height: 4)
                    .padding(.leading, 2)
            }
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: 1.5, height: 4)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Expanded
// Compact peer-height layout for the expanded island (hangs below the notch).
// Metrics from this Mac’s battery firmware + ProcessInfo. Local drain history
// is secondary; nothing invents capacity.

private struct ExpandedBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared
    @ObservedObject private var history = BatteryHistoryStore.shared

    private var snapshot: BatterySnapshot { plugin.snapshot }
    private var insight: BatteryInsight {
        BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    /// Prefer firmware max/design capacity when the Mac reports it.
    private var hardwareHealth: Int? { snapshot.hardwareHealthPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            NotchSectionHeader(
                "Battery",
                trailing: snapshot.isPresent
                    ? AnyView(
                        HStack(spacing: 6) {
                            if power.isLowPowerModeEnabled {
                                NotchStatusChip(text: "Low Power", kind: .soon)
                            } else if snapshot.isCharging {
                                NotchStatusChip(text: "Charging", kind: .success)
                            }
                            Text(headerHealthLabel)
                                .font(NotchTheme.micro.weight(.semibold))
                                .foregroundStyle(healthColor)
                        }
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
                // Hero: glyph + % + status + fill bar
                NotchCard(compact: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 12) {
                            BatteryHeroGlyph(
                                percent: snapshot.percent,
                                tint: barColor,
                                charging: snapshot.isCharging
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(snapshot.percent)%")
                                        .font(NotchTheme.heroDigit.monospacedDigit())
                                        .foregroundStyle(barColor)
                                    if snapshot.isCharging {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(NotchTheme.positive)
                                            .offset(y: -2)
                                    }
                                }
                                Text(statusLabel)
                                    .font(NotchTheme.body)
                                    .foregroundStyle(NotchTheme.textSecondary)
                                    .lineLimit(1)
                                if let minutes = displayMinutes {
                                    Text(timeLabel(minutes))
                                        .font(NotchTheme.caption)
                                        .foregroundStyle(NotchTheme.textTertiary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 0)

                            if let hw = hardwareHealth {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Health")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(NotchTheme.textQuaternary)
                                    Text("\(hw)%")
                                        .font(NotchTheme.body.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(healthColor)
                                    Text(BatteryHealthModel.healthLabel(for: hw))
                                        .font(NotchTheme.micro)
                                        .foregroundStyle(NotchTheme.textQuaternary)
                                        .lineLimit(1)
                                }
                            }
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NotchTheme.chipFill)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [barColor, barColor.opacity(0.72)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(8, geo.size.width * CGFloat(snapshot.percent) / 100))
                            }
                        }
                        .frame(height: 5)
                    }
                }

                // Metrics 2×2 — scannable vitals without a long chip row
                if hasAnyMetric {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 6
                    ) {
                        if let cycles = snapshot.cycleCount {
                            metricCell(title: "Cycles", value: "\(cycles)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        if let maxC = snapshot.maxCapacity, let design = snapshot.designCapacity, design > 0 {
                            metricCell(title: "Capacity", value: "\(maxC)/\(design)", systemImage: "rectangle.stack")
                        } else if let maxC = snapshot.maxCapacity {
                            metricCell(title: "Max cap", value: "\(maxC)", systemImage: "rectangle.stack")
                        }
                        if let temp = snapshot.temperatureC {
                            metricCell(
                                title: "Temp",
                                value: String(format: "%.0f°C", temp),
                                systemImage: "thermometer.medium",
                                accent: temp > 45 ? NotchTheme.caution : nil
                            )
                        }
                        if let drain = insight.drainPercentPerHour, !snapshot.isCharging {
                            metricCell(
                                title: "Drain",
                                value: String(format: "%.1f%%/h", drain),
                                systemImage: "arrow.down.right",
                                accent: drain > 18 ? NotchTheme.caution : nil
                            )
                        } else if snapshot.isCharging, let toFull = insight.predictedToFullMinutes {
                            metricCell(
                                title: "To full",
                                value: shortDuration(toFull),
                                systemImage: "bolt.badge.clock"
                            )
                        }
                    }
                }

                // Power modes — Low / Auto / High
                VStack(alignment: .leading, spacing: 6) {
                    Text("Power Mode")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                    HStack(spacing: 6) {
                        ForEach(availableModes) { mode in
                            Button {
                                plugin.setPowerMode(mode)
                            } label: {
                                NotchChipLabel(
                                    title: mode.title,
                                    systemImage: mode.systemImage,
                                    active: power.activeMode == mode
                                )
                            }
                            .buttonStyle(.plain)
                            .help(mode.help)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Button {
                            plugin.setAutoLowPower(!power.autoEnableEnabled)
                        } label: {
                            NotchChipLabel(
                                title: power.autoEnableEnabled
                                    ? "Auto Low ≤\(power.autoEnableAtPercent)%"
                                    : "Auto Low off",
                                systemImage: "bolt.badge.automatic",
                                active: power.autoEnableEnabled
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Automatically enable Low Power Mode when battery is low and unplugged")

                        Button {
                            power.openBatterySettings()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(NotchTheme.textTertiary)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(NotchTheme.chipFill))
                        }
                        .buttonStyle(.plain)
                        .help("Open Battery settings")
                        Spacer(minLength: 0)
                    }
                    if let err = power.lastError {
                        Text(err)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.caution)
                            .lineLimit(2)
                    }
                }

                // Contextual tip — only when actionable
                if let tip = compactTip {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotchTheme.caution.opacity(0.85))
                            .padding(.top, 1)
                        Text(tip)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            power.refresh()
        }
    }

    private var hasAnyMetric: Bool {
        snapshot.cycleCount != nil
            || snapshot.maxCapacity != nil
            || snapshot.temperatureC != nil
            || insight.drainPercentPerHour != nil
            || (snapshot.isCharging && insight.predictedToFullMinutes != nil)
    }

    private var availableModes: [DynamoPowerMode] {
        if power.supportsHighPowerMode || power.activeMode == .high {
            return DynamoPowerMode.allCases
        }
        return [.low, .automatic]
    }

    private func metricCell(
        title: String,
        value: String,
        systemImage: String,
        accent: Color? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent ?? NotchTheme.textQuaternary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Text(value)
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent ?? NotchTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NotchTheme.chipFill.opacity(0.65))
        )
    }

    private func shortDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "~\(h)h \(m)m" : "~\(m)m"
    }

    /// Prefer macOS time remaining; fall back to local rate estimate.
    private var displayMinutes: Int? {
        if let os = snapshot.timeRemainingMinutes { return os }
        if snapshot.isCharging {
            return insight.predictedToFullMinutes
        }
        return insight.predictedRemainingMinutes
    }

    private var statusLabel: String {
        switch power.activeMode {
        case .low: return "Low Power Mode"
        case .high: return "High Power Mode"
        case .automatic:
            if snapshot.isCharging { return "Charging" }
            if snapshot.isPluggedIn { return "Plugged in" }
            return "On battery"
        }
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
        if let temp = snapshot.temperatureC, temp > 45 {
            return "Battery is warm — ease load or unplug once charged."
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

// MARK: - Hero battery glyph

/// Larger battery shell with live fill for the expanded card.
private struct BatteryHeroGlyph: View {
    let percent: Int
    let tint: Color
    var charging: Bool = false

    var body: some View {
        ZStack {
            // Body
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(tint.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 36, height: 20)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.75)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(3, 28 * CGFloat(min(100, max(0, percent))) / 100),
                            height: 12
                        )
                        .padding(.leading, 4)
                }
                // Terminal nub
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint.opacity(0.45))
                    .frame(width: 3, height: 8)
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .offset(x: -2)
            }
        }
        .frame(width: 44, height: 28)
        .accessibilityHidden(true)
    }
}
