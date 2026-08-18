import Combine
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
    private var powerObservers = Set<AnyCancellable>()

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
                guard let self else { return }
                self.power.refresh()
                self.recomputeInsight()
                // Force ambient + expanded tint refresh when Low Power flips.
                self.objectWillChange.send()
            }
        }
        // Also react when Dynamo toggles Low Power itself.
        power.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &powerObservers)
    }

    func stop() {
        provider.stop()
        if let powerCancellable {
            NotificationCenter.default.removeObserver(powerCancellable)
            self.powerCancellable = nil
        }
        powerObservers.removeAll()
    }

    /// Live tint for UI: red ≤20%, amber in Low Power, otherwise green.
    /// Updates automatically as percent / power mode / charge state change.
    static func tint(
        percent: Int,
        lowPower: Bool,
        charging: Bool
    ) -> Color {
        if percent <= 20 { return NotchTheme.negative }
        if lowPower { return NotchTheme.caution }
        // Healthy on battery, charging, or plugged in → green.
        _ = charging
        return NotchTheme.positive
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedBatteryView(plugin: self))
    }

    /// Match Media / Calendar / Shelf / Webcam so tab switches don’t drop taller.
    var expandedContentHeight: CGFloat { 268 }

    // MARK: - Snapshot pipeline

    /// Stages already announced (e.g. "p20", "p10", "p5") so we don't spam.
    private var notifiedBatteryStages: Set<String> = []
    /// Last known AC / charge state — drives plug / unplug Peeks.
    private var lastPluggedIn: Bool?
    private var lastCharging: Bool?
    private var lastFullyChargedPeekAt: Date = .distantPast
    private var hasSeededPowerState = false

    private func handleSnapshot(_ value: BatterySnapshot) {
        let previous = snapshot
        snapshot = value
        power.refresh()
        history.record(snapshot: value, isLowPowerMode: power.isLowPowerModeEnabled)
        power.considerAutoEnable(snapshot: value)
        recomputeInsight()
        announcePowerTransitionPeeks(previous: previous)
        announceBatteryIfNeeded()
    }

    /// Peek when the Mac is plugged in or unplugged — with remaining / to-full time.
    private func announcePowerTransitionPeeks(previous: BatterySnapshot) {
        guard snapshot.isPresent else { return }

        // First reading only seeds state — avoid a Peek on every launch.
        guard hasSeededPowerState else {
            lastPluggedIn = snapshot.isPluggedIn
            lastCharging = snapshot.isCharging
            hasSeededPowerState = true
            return
        }

        let wasPlugged = lastPluggedIn ?? snapshot.isPluggedIn
        let wasCharging = lastCharging ?? snapshot.isCharging
        let nowPlugged = snapshot.isPluggedIn
        let nowCharging = snapshot.isCharging
        lastPluggedIn = nowPlugged
        lastCharging = nowCharging

        let p = snapshot.percent

        // Unplugged from AC → critical Peek with time remaining.
        if wasPlugged, !nowPlugged {
            let remaining = minutesRemainingText()
            let subtitle: String
            if let remaining {
                subtitle = "\(p)% · \(remaining) left"
            } else {
                subtitle = "\(p)% · estimating runtime…"
            }
            let detail = power.isLowPowerModeEnabled
                ? "On battery · Low Power on"
                : "On battery"
            DynamoNotificationRouter.shared.route(
                title: p <= 20 ? "Unplugged · battery low" : "Unplugged",
                subtitle: subtitle,
                detail: detail,
                systemImage: p <= 20 ? "battery.25" : "battery.100",
                urgency: p <= 15 ? .critical : .high,
                source: .widget,
                category: "battery",
                id: "battery|unplug|\(Int(Date().timeIntervalSince1970 / 30))"
            )
            return
        }

        // Plugged into AC / started charging → Peek with time to full.
        if (!wasPlugged && nowPlugged) || (!wasCharging && nowCharging) {
            if p >= 99, nowPlugged {
                peekFullyChargedIfNeeded(force: true)
                return
            }
            let toFull = minutesToFullText()
            let subtitle: String
            if let toFull {
                subtitle = "\(p)% · \(toFull) to full"
            } else if nowCharging {
                subtitle = "\(p)% · calculating time to full…"
            } else {
                subtitle = "\(p)% · holding on AC"
            }
            DynamoNotificationRouter.shared.route(
                title: nowCharging ? "Charging" : "Plugged in",
                subtitle: subtitle,
                detail: nowCharging ? "Power connected · charging" : "Power connected",
                systemImage: "bolt.fill",
                urgency: .high,
                source: .widget,
                category: "battery",
                id: "battery|plug|\(Int(Date().timeIntervalSince1970 / 30))"
            )
            return
        }

        // Reached full while on AC.
        if nowPlugged, p >= 99, (previous.percent < 99 || (!wasCharging && !nowCharging)) {
            peekFullyChargedIfNeeded(force: previous.percent < 99)
        }
    }

    private func peekFullyChargedIfNeeded(force: Bool) {
        guard force || Date().timeIntervalSince(lastFullyChargedPeekAt) > 120 else { return }
        lastFullyChargedPeekAt = Date()
        DynamoNotificationRouter.shared.route(
            title: "Fully charged",
            subtitle: "\(max(snapshot.percent, 100))% · ready to unplug",
            detail: "Battery full",
            systemImage: "battery.100.bolt",
            urgency: .high,
            source: .widget,
            category: "battery",
            id: "battery|full|\(Int(Date().timeIntervalSince1970 / 60))"
        )
    }

    private func minutesRemainingText() -> String? {
        if let os = snapshot.timeRemainingMinutes, !snapshot.isCharging, os > 0, os < 6000 {
            return formatDuration(os)
        }
        if let pred = insight.predictedRemainingMinutes { return formatDuration(pred) }
        return nil
    }

    private func minutesToFullText() -> String? {
        if snapshot.isCharging, let os = snapshot.timeRemainingMinutes, os > 0, os < 6000 {
            return formatDuration(os)
        }
        if let pred = insight.predictedToFullMinutes { return formatDuration(pred) }
        return nil
    }

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "~\(h)h \(m)m" }
        return "~\(m)m"
    }

    private func announceBatteryIfNeeded() {
        guard snapshot.isPresent, !snapshot.isCharging, !snapshot.isPluggedIn else {
            if snapshot.isCharging || snapshot.isPluggedIn { notifiedBatteryStages.removeAll() }
            return
        }
        let p = snapshot.percent
        // Peek alerts at ≤10% (critical) and ≤5% (re-alert). Red UI starts at 20%.
        let stages: [(Int, String, NotchSneakPeekUrgency)] = [
            (5, "p5", .critical),
            (10, "p10", .critical)
        ]
        // Clear stages once charge recovers above their threshold (re-arm alerts).
        for (threshold, key, _) in stages where p > threshold {
            notifiedBatteryStages.remove(key)
        }
        // Drop legacy 15/20 stage keys if they linger from older builds.
        if p > 20 {
            notifiedBatteryStages.remove("p15")
            notifiedBatteryStages.remove("p20")
        }
        for (threshold, key, urgency) in stages {
            guard p <= threshold, !notifiedBatteryStages.contains(key) else { continue }
            notifiedBatteryStages.insert(key)
            let remaining = minutesRemainingText()
            let subtitle: String
            if let remaining {
                subtitle = "\(p)% · \(remaining) left"
                    + (power.isLowPowerModeEnabled ? " · Low Power on" : "")
            } else {
                subtitle = "\(p)% remaining"
                    + (power.isLowPowerModeEnabled ? " · Low Power on" : "")
            }
            DynamoNotificationRouter.shared.route(
                title: p <= 5 ? "Battery critically low" : "Battery at 10%",
                subtitle: subtitle,
                detail: "On battery · plug in soon",
                systemImage: "battery.0",
                urgency: urgency,
                source: .widget,
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

    /// Force a fresh IOKit read (e.g. when opening the Battery tab).
    func refreshNow() {
        if let iokit = provider as? IOKitBatteryProvider {
            iokit.refreshNow()
        }
        power.refresh()
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
        if snapshot.isPresent, snapshot.percent <= 10 { return 92 }
        if snapshot.isPresent, snapshot.percent <= 20 { return 78 }
        if power.isLowPowerModeEnabled { return 65 }
        return 10
    }

    func ambientView() -> AnyView {
        AnyView(AmbientBatteryView(plugin: self))
    }
}

// MARK: - Ambient

private struct AmbientBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared
    @State private var pulse = false

    private var snapshot: BatterySnapshot { plugin.snapshot }

    private var tint: Color {
        BatteryPlugin.tint(
            percent: snapshot.percent,
            lowPower: power.isLowPowerModeEnabled,
            charging: snapshot.isCharging
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            AmbientBatteryGlyph(percent: snapshot.percent, tint: tint, charging: snapshot.isCharging)
                .scaleEffect(snapshot.isCharging && pulse ? 1.08 : 1.0)
                .animation(
                    snapshot.isCharging
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
            Text("\(snapshot.percent)%")
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .animation(.easeInOut(duration: 0.35), value: tintDescription)
            if power.isLowPowerModeEnabled {
                Text("LPM")
                    .font(NotchTheme.micro.weight(.bold))
                    .foregroundStyle(NotchTheme.caution)
            }
            // Unplugged → time left · Charging → time to full
            if let label = ambientTimeLabel {
                Text(label)
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(snapshot.isCharging ? NotchTheme.positive.opacity(0.9) : NotchTheme.textTertiary)
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
        .animation(.easeInOut(duration: 0.4), value: snapshot.percent)
        .animation(.easeInOut(duration: 0.4), value: power.isLowPowerModeEnabled)
        .onAppear { pulse = snapshot.isCharging }
        .onChange(of: snapshot.isCharging) { charging in
            pulse = charging
        }
    }

    /// Stable identity for color animation (Color itself isn’t Equatable in all SDKs).
    private var tintDescription: String {
        if snapshot.percent <= 20 { return "red" }
        if power.isLowPowerModeEnabled { return "amber" }
        return "green"
    }

    private var ambientTimeLabel: String? {
        guard let min = snapshot.timeRemainingMinutes, min > 0, min < 6000 else { return nil }
        let h = min / 60
        let m = min % 60
        let dur = h > 0 ? "~\(h)h \(m)m" : "~\(m)m"
        if snapshot.isCharging { return "\(dur) full" }
        if !snapshot.isPluggedIn { return dur }
        return nil
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
// Time remaining when unplugged · time to full when charging.
// Animated hero bar + glyph. Metrics from firmware + local drain history.

private struct ExpandedBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared
    @ObservedObject private var history = BatteryHistoryStore.shared
    @State private var appeared = false
    @State private var chargePulse = false
    @State private var shimmerPhase: CGFloat = 0

    private var snapshot: BatterySnapshot { plugin.snapshot }
    private var insight: BatteryInsight {
        BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }

    private var hardwareHealth: Int? { snapshot.hardwareHealthPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Battery")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer(minLength: 0)
                if snapshot.isPresent {
                    if snapshot.percent <= 20, !snapshot.isCharging {
                        NotchStatusChip(text: snapshot.percent <= 10 ? "Critical" : "Low", kind: .danger)
                    } else if power.isLowPowerModeEnabled {
                        NotchStatusChip(text: "Low Power", kind: .soon)
                    } else if snapshot.isCharging {
                        NotchStatusChip(text: "Charging", kind: .success)
                    } else if snapshot.isPluggedIn {
                        NotchStatusChip(text: "Plugged in", kind: .now)
                    } else {
                        NotchStatusChip(text: "On battery", kind: .success)
                    }
                }
            }

            if !snapshot.isPresent {
                NotchEmptyState(
                    systemImage: "laptopcomputer",
                    title: "No internal battery",
                    caption: "Desktop Mac or power source unavailable.",
                    prominent: true
                )
            } else {
                heroCard
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)

                // Big time callout — remaining OR to full
                timeCallout
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)

                if hasAnyMetric {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)
                        ],
                        spacing: 6
                    ) {
                        if let cycles = snapshot.cycleCount {
                            metricCell(title: "Cycles", value: "\(cycles)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        if let hw = hardwareHealth {
                            metricCell(
                                title: "Health",
                                value: "\(hw)%",
                                systemImage: "heart.fill",
                                accent: healthColor
                            )
                        } else if let maxC = snapshot.maxCapacity, let design = snapshot.designCapacity, design > 0 {
                            metricCell(title: "Capacity", value: "\(maxC)/\(design)", systemImage: "rectangle.stack")
                        }
                        if let temp = snapshot.temperatureC {
                            metricCell(
                                title: "Temp",
                                value: String(format: "%.0f°C", temp),
                                systemImage: "thermometer.medium",
                                accent: temp > 45 ? NotchTheme.caution : nil
                            )
                        }
                        if let drain = insight.drainPercentPerHour, !snapshot.isCharging, !snapshot.isPluggedIn {
                            metricCell(
                                title: "Drain",
                                value: String(format: "%.1f%%/h", drain),
                                systemImage: "arrow.down.right",
                                accent: drain > 18 ? NotchTheme.caution : nil
                            )
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                }

                powerModeRow
                    .opacity(appeared ? 1 : 0)

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
        .animation(.easeInOut(duration: 0.4), value: snapshot.percent)
        .animation(.easeInOut(duration: 0.4), value: power.isLowPowerModeEnabled)
        .animation(.easeInOut(duration: 0.35), value: snapshot.isCharging)
        .onAppear {
            plugin.refreshNow()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                appeared = true
            }
            chargePulse = snapshot.isCharging
            if snapshot.isCharging {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
            }
        }
        .onChange(of: snapshot.isCharging) { charging in
            chargePulse = charging
            shimmerPhase = 0
            if charging {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
            }
        }
        .onChange(of: snapshot.percent) { _ in
            // Percent crossings (e.g. 21→20) auto-flip green→red.
        }
        .onChange(of: power.isLowPowerModeEnabled) { _ in
            // Low Power on/off auto-flips green↔amber.
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                // Ring + glyph — sized to match peer tabs (268pt content).
                ZStack {
                    Circle()
                        .stroke(NotchTheme.chipFill, lineWidth: 4)
                        .frame(width: 56, height: 56)
                    Circle()
                        .trim(from: 0, to: CGFloat(snapshot.percent) / 100)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    barColor.opacity(0.35),
                                    barColor,
                                    barColor.opacity(0.85),
                                    barColor.opacity(0.35)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: snapshot.percent)
                        .shadow(color: barColor.opacity(0.4), radius: snapshot.isCharging ? 6 : 2)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [barColor.opacity(0.16), Color.clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 26
                            )
                        )
                        .frame(width: 48, height: 48)
                    BatteryHeroGlyph(
                        percent: snapshot.percent,
                        tint: barColor,
                        charging: snapshot.isCharging,
                        pulse: chargePulse
                    )
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(snapshot.percent)%")
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(barColor)
                            .shadow(color: barColor.opacity(0.3), radius: 6)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: snapshot.percent)
                        if snapshot.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(NotchTheme.positive)
                                .scaleEffect(chargePulse ? 1.15 : 1.0)
                                .opacity(chargePulse ? 1.0 : 0.75)
                                .animation(
                                    .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                                    value: chargePulse
                                )
                        }
                    }
                    Text(statusLabel)
                        .font(NotchTheme.body.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                    if let hw = hardwareHealth {
                        Text("\(BatteryHealthModel.healthLabel(for: hw)) · \(hw)% health")
                            .font(NotchTheme.micro.weight(.medium))
                            .foregroundStyle(healthColor.opacity(0.95))
                    }
                }

                Spacer(minLength: 0)
            }

            // Animated charge / drain bar with glow
            GeometryReader { geo in
                let fillW = max(10, geo.size.width * CGFloat(snapshot.percent) / 100)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(NotchTheme.chipFill)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    barColor.opacity(0.75),
                                    barColor,
                                    barColor.opacity(0.85)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillW)
                        .shadow(color: barColor.opacity(0.55), radius: 6, y: 0)
                        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: snapshot.percent)
                    if snapshot.isCharging {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0),
                                        Color.white.opacity(0.45),
                                        Color.white.opacity(0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(28, fillW * 0.32))
                            .offset(x: max(0, (fillW - 28) * shimmerPhase))
                            .blendMode(.plusLighter)
                    }
                }
            }
            .frame(height: 7)
            .clipShape(Capsule())
        }
        .padding(10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                barColor.opacity(snapshot.isCharging ? 0.18 : (snapshot.percent <= 20 ? 0.16 : 0.10)),
                                Color.black.opacity(0.2),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                barColor.opacity(0.4),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            }
            .shadow(color: barColor.opacity(0.14), radius: 10, y: 3)
        }
    }

    /// Prominent remaining / to-full time.
    private var timeCallout: some View {
        let info = timeInfo
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(info.tint.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: info.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(info.tint)
                    .scaleEffect(snapshot.isCharging && chargePulse ? 1.1 : 1.0)
                    .animation(
                        snapshot.isCharging
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: chargePulse
                    )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(info.value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: info.value)
                if let sub = info.subtitle {
                    Text(sub)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                .fill(info.tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .strokeBorder(info.tint.opacity(0.18), lineWidth: 0.5)
                )
        )
    }

    private var powerModeRow: some View {
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
            }
            if let err = power.lastError {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution)
                    .lineLimit(2)
            }
        }
    }

    private var hasAnyMetric: Bool {
        snapshot.cycleCount != nil
            || hardwareHealth != nil
            || snapshot.maxCapacity != nil
            || snapshot.temperatureC != nil
            || insight.drainPercentPerHour != nil
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

    // MARK: Time remaining / to full

    private struct TimeInfo {
        var title: String
        var value: String
        var subtitle: String?
        var symbol: String
        var tint: Color
    }

    /// Unplugged → remaining · Charging → to full · Full / hold when plugged & idle.
    private var timeInfo: TimeInfo {
        if snapshot.isCharging {
            if let mins = minutesToFull {
                return TimeInfo(
                    title: "Time to full",
                    value: formatDuration(mins),
                    subtitle: snapshot.percent >= 80 ? "Almost there" : "Charging from AC",
                    symbol: "bolt.badge.clock.fill",
                    tint: NotchTheme.positive
                )
            }
            return TimeInfo(
                title: "Time to full",
                value: "Calculating…",
                subtitle: "Waiting for charge estimate",
                symbol: "bolt.fill",
                tint: NotchTheme.positive
            )
        }
        if snapshot.isPluggedIn {
            if snapshot.percent >= 99 {
                return TimeInfo(
                    title: "Charge",
                    value: "Fully charged",
                    subtitle: "Plugged in · not discharging",
                    symbol: "battery.100.bolt",
                    tint: NotchTheme.positive
                )
            }
            // Optimized Battery Charging often holds ~80%.
            if let mins = minutesToFull {
                return TimeInfo(
                    title: "Time to full",
                    value: formatDuration(mins),
                    subtitle: "Plugged in · may pause to optimize",
                    symbol: "bolt.badge.clock.fill",
                    tint: NotchTheme.calmGlow
                )
            }
            return TimeInfo(
                title: "Plugged in",
                value: "Holding charge",
                subtitle: snapshot.percent >= 75
                    ? "Optimized Battery Charging may delay 100%"
                    : "Connected to power",
                symbol: "powerplug.fill",
                tint: NotchTheme.calmGlow
            )
        }
        // On battery
        if let mins = minutesRemaining {
            return TimeInfo(
                title: "Time remaining",
                value: formatDuration(mins),
                subtitle: power.isLowPowerModeEnabled ? "Low Power Mode on" : "On battery",
                symbol: "clock.fill",
                tint: snapshot.percent <= 20
                    ? NotchTheme.negative
                    : (power.isLowPowerModeEnabled ? NotchTheme.caution : NotchTheme.positive)
            )
        }
        return TimeInfo(
            title: "Time remaining",
            value: "Calculating…",
            subtitle: "Estimating from recent drain",
            symbol: "clock",
            tint: snapshot.percent <= 20 ? NotchTheme.negative : NotchTheme.textTertiary
        )
    }

    private var minutesRemaining: Int? {
        if snapshot.isCharging || snapshot.isPluggedIn { return nil }
        if let os = snapshot.timeRemainingMinutes, os > 0, os < 6000 { return os }
        return insight.predictedRemainingMinutes
    }

    private var minutesToFull: Int? {
        guard snapshot.isCharging || (snapshot.isPluggedIn && snapshot.percent < 99) else { return nil }
        if snapshot.isCharging, let os = snapshot.timeRemainingMinutes, os > 0, os < 6000 {
            return os
        }
        return insight.predictedToFullMinutes
    }

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "~\(h)h \(m)m" }
        return "~\(m)m"
    }

    private var statusLabel: String {
        if snapshot.isCharging { return "Charging" }
        if snapshot.isPluggedIn {
            return snapshot.percent >= 99 ? "Fully charged" : "Plugged in"
        }
        switch power.activeMode {
        case .low: return "On battery · Low Power"
        case .high: return "On battery · High Power"
        case .automatic: return "On battery"
        }
    }

    private var compactTip: String? {
        if snapshot.percent <= 20, !power.isLowPowerModeEnabled, !snapshot.isCharging {
            return "Enable Low Power Mode to stretch remaining charge."
        }
        if let drain = insight.drainPercentPerHour, drain > 18, !snapshot.isPluggedIn {
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

    /// Auto tint: red ≤20% · amber Low Power · otherwise green.
    private var barColor: Color {
        BatteryPlugin.tint(
            percent: snapshot.percent,
            lowPower: power.isLowPowerModeEnabled,
            charging: snapshot.isCharging
        )
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

private struct BatteryHeroGlyph: View {
    let percent: Int
    let tint: Color
    var charging: Bool = false
    var pulse: Bool = false

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1.4)
                        .frame(width: 34, height: 18)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.72)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(3, 24 * CGFloat(min(100, max(0, percent))) / 100),
                            height: 10
                        )
                        .padding(.leading, 5)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: percent)
                }
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint.opacity(0.5))
                    .frame(width: 3, height: 8)
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .shadow(color: tint.opacity(0.8), radius: 2)
                    .offset(x: -2)
                    .scaleEffect(pulse ? 1.12 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulse
                    )
            }
        }
        .frame(width: 42, height: 24)
        .accessibilityHidden(true)
    }
}
