import Combine
import SwiftUI

@MainActor
final class BatteryPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, WidgetSettingsProviding {
    let id = "battery"
    let displayName = "Battery"
    let systemImage = "battery.100"

    private static let showTipsKey = "dynamo.battery.showTips"
    private static let showSparklineKey = "dynamo.battery.showHistorySparkline"

    @Published private(set) var snapshot: BatterySnapshot = .unknown
    @Published private(set) var insight: BatteryInsight = BatteryHealthModel.insight(
        snapshot: .unknown,
        samples: []
    )

    @Published var showTips: Bool {
        didSet { UserDefaults.standard.set(showTips, forKey: Self.showTipsKey) }
    }

    @Published var showHistorySparkline: Bool {
        didSet { UserDefaults.standard.set(showHistorySparkline, forKey: Self.showSparklineKey) }
    }

    private let provider: BatteryProvider
    private let history = BatteryHistoryStore.shared
    private let power = BatteryPowerMode.shared
    private var powerCancellable: Any?
    private var powerObservers = Set<AnyCancellable>()

    init(provider: BatteryProvider? = nil) {
        if UserDefaults.standard.object(forKey: Self.showTipsKey) == nil {
            showTips = true
        } else {
            showTips = UserDefaults.standard.bool(forKey: Self.showTipsKey)
        }
        if UserDefaults.standard.object(forKey: Self.showSparklineKey) == nil {
            showHistorySparkline = true
        } else {
            showHistorySparkline = UserDefaults.standard.bool(forKey: Self.showSparklineKey)
        }
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

    /// Multi-section Battery tray (scrolls when needed).
    var expandedContentHeight: CGFloat { 360 }

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

        // Reached full while on AC (crossed into ≥99%, or finished charging at full).
        let crossedToFull = previous.percent < 99 && p >= 99
        let finishedChargingFull = wasCharging && !nowCharging && nowPlugged && p >= 99
        if nowPlugged, p >= 99, crossedToFull || finishedChargingFull {
            peekFullyChargedIfNeeded(force: true)
        }
    }

    private func peekFullyChargedIfNeeded(force: Bool) {
        guard force || Date().timeIntervalSince(lastFullyChargedPeekAt) > 180 else { return }
        lastFullyChargedPeekAt = Date()
        DynamoNotificationRouter.shared.route(
            title: "Fully charged",
            subtitle: "Battery is fully charged · ready to unplug",
            detail: "Battery full · \(max(snapshot.percent, 100))%",
            systemImage: "battery.100.bolt",
            urgency: .critical,
            source: .widget,
            category: "battery",
            id: "battery|full|\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)"
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
                urgency: .critical,
                source: .widget,
                category: "battery",
                id: "battery|\(key)"
            )
            // Sound always plays via Peek hub for battery|p10 / battery|p5.
            _ = urgency
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

    func setAutoLowPowerThreshold(_ percent: Int) {
        power.autoEnableAtPercent = min(50, max(5, percent))
    }

    var isLowPowerModeEnabled: Bool { power.isLowPowerModeEnabled }
    var autoLowPowerEnabled: Bool { power.autoEnableEnabled }
    var autoLowPowerThreshold: Int { power.autoEnableAtPercent }
    var activePowerMode: DynamoPowerMode { power.activeMode }

    func settingsView() -> AnyView {
        AnyView(BatterySettingsView(plugin: self))
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .scaleEffect(snapshot.isCharging && pulse ? 1.06 : 1.0)
            Text("\(snapshot.percent)%")
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(NotchTheme.contentSpring, value: tintDescription)
            if power.isLowPowerModeEnabled {
                Text("LPM")
                    .font(NotchTheme.micro.weight(.bold))
                    .foregroundStyle(NotchTheme.caution)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            // Unplugged → time left · Charging → time to full
            if let label = ambientTimeLabel {
                Text(label)
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(snapshot.isCharging ? NotchTheme.positive.opacity(0.9) : NotchTheme.textTertiary)
                    .contentTransition(.opacity)
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
        .animation(NotchTheme.contentSpring, value: snapshot.percent)
        .animation(NotchTheme.contentSpring, value: power.isLowPowerModeEnabled)
        .onAppear { startPulse(snapshot.isCharging) }
        .onChange(of: snapshot.isCharging) { charging in
            startPulse(charging)
        }
    }

    private func startPulse(_ charging: Bool) {
        pulse = false
        guard charging, !reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
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
// Multi-section Battery tray: hero, vitals, capacity, adapter, history, power, tips.
// Scrolls inside the island — no nested battery glyph / no bottom-clip ghosts.

private struct ExpandedBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared
    @ObservedObject private var history = BatteryHistoryStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chargePulse = false
    @State private var shimmerPhase: CGFloat = 0

    private var snapshot: BatterySnapshot { plugin.snapshot }
    private var insight: BatteryInsight {
        BatteryHealthModel.insight(snapshot: snapshot, samples: history.samples)
    }
    private var hardwareHealth: Int? { snapshot.hardwareHealthPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !snapshot.isPresent {
                NotchEmptyState(
                    systemImage: "laptopcomputer",
                    title: "No internal battery",
                    caption: "Desktop Mac or power source unavailable.",
                    prominent: true
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        heroCard
                            .notchAppear()

                        vitalsStrip
                            .notchAppear(delay: 0.04)

                        sectionCard(title: "Capacity", systemImage: "rectangle.stack.fill") {
                            capacitySection
                        }
                        .notchAppear(delay: 0.07)

                        sectionCard(title: "Power source", systemImage: "powerplug.fill") {
                            adapterSection
                        }
                        .notchAppear(delay: 0.1)

                        if plugin.showHistorySparkline {
                            sectionCard(title: "Recent charge", systemImage: "chart.xyaxis.line") {
                                historySection
                            }
                            .notchAppear(delay: 0.13)
                        }

                        sectionCard(title: "Power mode", systemImage: "leaf.fill") {
                            powerModeControls
                        }
                        .notchAppear(delay: 0.16)

                        if plugin.showTips {
                            tipsSection
                                .notchAppear(delay: 0.18)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(NotchTheme.contentSpring, value: snapshot.percent)
        .animation(NotchTheme.contentSpring, value: power.isLowPowerModeEnabled)
        .animation(NotchTheme.contentSpring, value: snapshot.isCharging)
        .onAppear {
            plugin.refreshNow()
            startChargeMotionIfNeeded(charging: snapshot.isCharging)
        }
        .onChange(of: snapshot.isCharging) { charging in
            startChargeMotionIfNeeded(charging: charging)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Battery")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.7)
            Spacer(minLength: 0)
            if snapshot.isPresent {
                NotchStatusChip(text: statusChipText, kind: statusChipKind)
            }
        }
    }

    private var statusChipText: String {
        if snapshot.percent <= 20, !snapshot.isCharging {
            return snapshot.percent <= 10 ? "Critical" : "Low"
        }
        if power.isLowPowerModeEnabled { return "Low Power" }
        if snapshot.isCharging { return "Charging" }
        if snapshot.isPluggedIn { return snapshot.percent >= 99 ? "Full" : "Plugged in" }
        return "On battery"
    }

    private var statusChipKind: NotchStatusChip.Kind {
        if snapshot.percent <= 20, !snapshot.isCharging { return .danger }
        if power.isLowPowerModeEnabled { return .soon }
        if snapshot.isCharging { return .success }
        if snapshot.isPluggedIn { return .now }
        return .success
    }

    private func startChargeMotionIfNeeded(charging: Bool) {
        shimmerPhase = 0
        chargePulse = false
        guard charging, !reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                chargePulse = true
            }
            withAnimation(.linear(duration: 1.55).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }

    // MARK: Section chrome

    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(barColor.opacity(0.85))
                Text(title)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                .fill(NotchTheme.chipFill.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    // MARK: Hero

    private var heroCard: some View {
        let info = timeInfo
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                chargeRing

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(snapshot.percent)%")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(barColor)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: snapshot.percent)

                    Text(info.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .tracking(0.6)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(info.value)
                            .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(NotchTheme.textPrimary)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let rate = rateLabel {
                            Text(rate)
                                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(info.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(info.tint.opacity(0.14)))
                        }
                    }

                    if let sub = info.subtitle {
                        Text(sub)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            chargeMeter
        }
        .padding(11)
        .background { heroBackground }
        .clipShape(RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous))
    }

    private var chargeRing: some View {
        ZStack {
            ForEach(0..<24, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i % 6 == 0 ? 0.18 : 0.06))
                    .frame(width: 1.2, height: i % 6 == 0 ? 4.5 : 2.5)
                    .offset(y: -26)
                    .rotationEffect(.degrees(Double(i) / 24 * 360))
            }
            Circle()
                .stroke(NotchTheme.chipFill, lineWidth: 3.5)
                .frame(width: 54, height: 54)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, snapshot.percent))) / 100)
                .stroke(
                    AngularGradient(
                        colors: [
                            barColor.opacity(0.25),
                            barColor,
                            barColor.opacity(0.75),
                            barColor.opacity(0.25)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .frame(width: 54, height: 54)
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: snapshot.percent)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [barColor.opacity(0.16), Color.clear],
                        center: .center,
                        startRadius: 1,
                        endRadius: 24
                    )
                )
                .frame(width: 44, height: 44)
            Image(systemName: heroCenterSymbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(barColor)
                .scaleEffect(snapshot.isCharging && chargePulse ? 1.12 : 1.0)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }

    private var heroCenterSymbol: String {
        if snapshot.isCharging { return "bolt.fill" }
        if power.isLowPowerModeEnabled { return "leaf.fill" }
        if snapshot.percent <= 20 { return "exclamationmark" }
        if snapshot.isPluggedIn { return "powerplug.fill" }
        return "clock.fill"
    }

    private var chargeMeter: some View {
        let fill = CGFloat(min(100, max(0, snapshot.percent))) / 100
        return Capsule()
            .fill(NotchTheme.chipFill)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [barColor.opacity(0.7), barColor, barColor.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(x: fill, y: 1, anchor: .leading)
                    .animation(.spring(response: 0.55, dampingFraction: 0.78), value: snapshot.percent)
            }
            .overlay(alignment: .leading) {
                if snapshot.isCharging, !reduceMotion {
                    GeometryReader { geo in
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
                            .frame(width: max(28, geo.size.width * 0.22), height: 5)
                            .offset(x: shimmerPhase * max(0, geo.size.width * fill - 28))
                            .blendMode(.plusLighter)
                    }
                    .frame(height: 5)
                    .mask(
                        Capsule()
                            .scaleEffect(x: fill, y: 1, anchor: .leading)
                    )
                }
            }
            .clipShape(Capsule())
    }

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            barColor.opacity(snapshot.isCharging ? 0.16 : (snapshot.percent <= 20 ? 0.14 : 0.08)),
                            Color.black.opacity(0.22),
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
                            Color.white.opacity(0.2),
                            barColor.opacity(0.35),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
        }
    }

    // MARK: Vitals

    private var vitalsStrip: some View {
        HStack(spacing: 5) {
            ForEach(vitalItems) { item in
                vitalPill(item)
            }
        }
    }

    private struct VitalItem: Identifiable {
        let id: String
        let title: String
        let value: String
        let systemImage: String
        let accent: Color?
    }

    private var vitalItems: [VitalItem] {
        var items: [VitalItem] = []
        if let hw = hardwareHealth {
            items.append(VitalItem(id: "health", title: "Health", value: "\(hw)%", systemImage: "heart.fill", accent: healthColor))
        }
        if let cycles = snapshot.cycleCount {
            items.append(VitalItem(id: "cycles", title: "Cycles", value: "\(cycles)", systemImage: "arrow.triangle.2.circlepath", accent: nil))
        }
        if let temp = snapshot.temperatureC {
            items.append(VitalItem(
                id: "temp",
                title: "Temp",
                value: String(format: "%.0f°", temp),
                systemImage: "thermometer.medium",
                accent: temp > 45 ? NotchTheme.caution : nil
            ))
        }
        if let rate = rateLabel {
            let isCharge = rate.hasPrefix("+")
            items.append(VitalItem(
                id: "rate",
                title: isCharge ? "Charge" : "Drain",
                value: rate,
                systemImage: isCharge ? "arrow.up.right" : "arrow.down.right",
                accent: isCharge ? NotchTheme.positive : ((insight.drainPercentPerHour ?? 0) > 18 ? NotchTheme.caution : nil)
            ))
        }
        return Array(items.prefix(4))
    }

    private func vitalPill(_ item: VitalItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 8, weight: .bold))
                Text(item.title)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            .foregroundStyle(item.accent ?? NotchTheme.textQuaternary)
            Text(item.value)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(item.accent ?? NotchTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NotchTheme.chipFill.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                )
        )
    }

    // MARK: Capacity

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                capacityStat(
                    title: "Health",
                    value: hardwareHealth.map { "\($0)%" } ?? "—",
                    detail: BatteryHealthModel.healthLabel(for: hardwareHealth ?? insight.healthScore),
                    accent: healthColor
                )
                capacityStat(
                    title: "Cycles",
                    value: snapshot.cycleCount.map(String.init) ?? "—",
                    detail: cycleWearLabel,
                    accent: nil
                )
            }
            if let maxC = snapshot.maxCapacity, let design = snapshot.designCapacity, design > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Full charge capacity")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                        Spacer(minLength: 0)
                        Text("\(maxC) / \(design)")
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textSecondary)
                    }
                    let ratio = min(1, max(0, Double(maxC) / Double(design)))
                    Capsule()
                        .fill(NotchTheme.chipFill)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(healthColor)
                                .scaleEffect(x: ratio, y: 1, anchor: .leading)
                        }
                        .clipShape(Capsule())
                    Text("Max vs design capacity from this Mac’s battery firmware.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(2)
                }
            } else {
                Text(insight.summary)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(2)
            }
        }
    }

    private func capacityStat(title: String, value: String, detail: String, accent: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(accent ?? NotchTheme.textPrimary)
            Text(detail)
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cycleWearLabel: String {
        guard let cycles = snapshot.cycleCount else { return "Not reported" }
        if cycles < 300 { return "Light wear" }
        if cycles < 700 { return "Normal wear" }
        if cycles < 1000 { return "Higher wear" }
        return "Heavy wear"
    }

    // MARK: Adapter / power source

    private var adapterSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailRow(
                systemImage: snapshot.isCharging ? "bolt.fill" : (snapshot.isPluggedIn ? "powerplug.fill" : "battery.100"),
                title: adapterTitle,
                value: adapterValue,
                accent: barColor
            )
            detailRow(
                systemImage: power.activeMode.systemImage,
                title: "System profile",
                value: power.activeMode.help.components(separatedBy: " — ").first ?? power.activeMode.title,
                accent: nil
            )
            detailRow(
                systemImage: "bolt.badge.automatic",
                title: "Auto Low Power",
                value: power.autoEnableEnabled
                    ? "On at ≤\(power.autoEnableAtPercent)% unplugged"
                    : "Off",
                accent: power.autoEnableEnabled ? NotchTheme.caution : nil
            )
            if let temp = snapshot.temperatureC {
                detailRow(
                    systemImage: "thermometer.medium",
                    title: "Battery temp",
                    value: String(format: "%.1f°C%@", temp, temp > 45 ? " · warm" : ""),
                    accent: temp > 45 ? NotchTheme.caution : nil
                )
            }
        }
    }

    private var adapterTitle: String {
        if snapshot.isCharging { return "Adapter" }
        if snapshot.isPluggedIn { return "Adapter" }
        return "Source"
    }

    private var adapterValue: String {
        if snapshot.isCharging {
            if let mins = minutesToFull {
                return "Charging · \(formatDuration(mins)) to full"
            }
            return "Charging from AC"
        }
        if snapshot.isPluggedIn {
            return snapshot.percent >= 99 ? "Plugged in · holding 100%" : "Plugged in · not charging"
        }
        if let mins = minutesRemaining {
            return "On battery · \(formatDuration(mins)) left"
        }
        return "On battery"
    }

    private func detailRow(systemImage: String, title: String, value: String, accent: Color?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent ?? NotchTheme.textQuaternary)
                .frame(width: 14)
            Text(title)
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textTertiary)
            Spacer(minLength: 6)
            Text(value)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(accent ?? NotchTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: History / sparkline / last session

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sparklinePoints.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Level · last \(sparklineHoursLabel)")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                        Spacer(minLength: 0)
                        if let first = sparklinePoints.first, let last = sparklinePoints.last {
                            let delta = last - first
                            Text(String(format: "%@%d%%", delta >= 0 ? "+" : "", delta))
                                .font(NotchTheme.micro.weight(.bold).monospacedDigit())
                                .foregroundStyle(delta >= 0 ? NotchTheme.positive : NotchTheme.caution)
                        }
                    }
                    BatterySparkline(values: sparklinePoints, tint: barColor)
                        .frame(height: 36)
                }
            } else {
                Text("Keep Dynamo open a bit longer to build a local charge history.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(2)
            }

            if let session = lastChargeSession {
                Divider().overlay(Color.white.opacity(0.06))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last charge session")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .textCase(.uppercase)
                        .tracking(0.3)
                    HStack(spacing: 8) {
                        sessionStat(title: "From", value: "\(session.startPercent)%")
                        sessionStat(title: "To", value: "\(session.endPercent)%")
                        sessionStat(title: "Gained", value: "+\(session.endPercent - session.startPercent)%")
                        sessionStat(title: "Took", value: session.durationLabel)
                    }
                    Text(session.whenLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
            }
        }
    }

    private func sessionStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sparklinePoints: [Int] {
        let cutoff = Date().addingTimeInterval(-18 * 3600)
        let recent = history.samples.filter { $0.date >= cutoff }
        let source = recent.isEmpty ? Array(history.samples.suffix(36)) : recent
        // Downsample to ≤48 points for a smooth tiny chart.
        guard source.count > 48 else { return source.map(\.percent) }
        let step = Double(source.count - 1) / 47.0
        return (0..<48).map { i in
            source[min(source.count - 1, Int((Double(i) * step).rounded()))].percent
        }
    }

    private var sparklineHoursLabel: String {
        let cutoff = Date().addingTimeInterval(-18 * 3600)
        let recent = history.samples.filter { $0.date >= cutoff }
        if recent.count >= 2, let first = recent.first {
            let hours = max(1, Int(Date().timeIntervalSince(first.date) / 3600))
            return "\(min(18, hours))h"
        }
        return "samples"
    }

    private struct ChargeSession {
        var startPercent: Int
        var endPercent: Int
        var durationLabel: String
        var whenLabel: String
    }

    /// Walk local history for the most recent contiguous charging stretch.
    private var lastChargeSession: ChargeSession? {
        let samples = history.samples
        guard samples.count >= 2 else { return nil }

        var endIndex: Int?
        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            if samples[i].isCharging {
                endIndex = i
                break
            }
        }
        guard let end = endIndex else { return nil }

        var start = end
        while start > 0, samples[start - 1].isCharging {
            start -= 1
        }
        let a = samples[start]
        let b = samples[end]
        guard b.percent >= a.percent else { return nil }

        let minutes = max(1, Int(b.date.timeIntervalSince(a.date) / 60))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return ChargeSession(
            startPercent: a.percent,
            endPercent: b.percent,
            durationLabel: formatDuration(minutes),
            whenLabel: "Ended \(formatter.localizedString(for: b.date, relativeTo: Date()))"
        )
    }

    // MARK: Power controls

    private var powerModeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
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
                Spacer(minLength: 4)
                Button {
                    plugin.setAutoLowPower(!power.autoEnableEnabled)
                } label: {
                    NotchChipLabel(
                        title: power.autoEnableEnabled ? "≤\(power.autoEnableAtPercent)%" : "Auto off",
                        systemImage: "bolt.badge.automatic",
                        active: power.autoEnableEnabled
                    )
                }
                .buttonStyle(.plain)
                .help("Auto-enable Low Power Mode at \(power.autoEnableAtPercent)% when unplugged")

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

    // MARK: Tips

    private var tipsSection: some View {
        let tips = tipList
        return Group {
            if !tips.isEmpty {
                sectionCard(title: "Tips", systemImage: "lightbulb.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(NotchTheme.caution.opacity(0.8))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 4)
                                Text(tip)
                                    .font(NotchTheme.micro)
                                    .foregroundStyle(NotchTheme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private var tipList: [String] {
        var tips: [String] = []
        if let t = compactTip { tips.append(t) }
        let modelTip = insight.tip.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelTip.isEmpty, !tips.contains(modelTip) {
            tips.append(modelTip)
        }
        if tips.isEmpty {
            tips.append("Keep charge between ~20–80% when you can to reduce long-term wear.")
        }
        return Array(tips.prefix(3))
    }

    private var availableModes: [DynamoPowerMode] {
        if power.supportsHighPowerMode || power.activeMode == .high {
            return DynamoPowerMode.allCases
        }
        return [.low, .automatic]
    }

    // MARK: Derived info

    private struct TimeInfo {
        var title: String
        var value: String
        var subtitle: String?
        var tint: Color
    }

    private var timeInfo: TimeInfo {
        if snapshot.isCharging {
            if let mins = minutesToFull {
                return TimeInfo(
                    title: "Time to full",
                    value: formatDuration(mins),
                    subtitle: snapshot.percent >= 80 ? "Almost there" : "Power adapter connected",
                    tint: NotchTheme.positive
                )
            }
            return TimeInfo(
                title: "Time to full",
                value: "Calculating…",
                subtitle: "Waiting for charge estimate",
                tint: NotchTheme.positive
            )
        }
        if snapshot.isPluggedIn {
            if snapshot.percent >= 99 {
                return TimeInfo(
                    title: "Status",
                    value: "Fully charged",
                    subtitle: "Safe to unplug",
                    tint: NotchTheme.positive
                )
            }
            if let mins = minutesToFull {
                return TimeInfo(
                    title: "Time to full",
                    value: formatDuration(mins),
                    subtitle: "May pause for Optimized Charging",
                    tint: NotchTheme.calmGlow
                )
            }
            return TimeInfo(
                title: "Status",
                value: "Holding charge",
                subtitle: snapshot.percent >= 75
                    ? "Optimized Charging may delay 100%"
                    : "Connected to power",
                tint: NotchTheme.calmGlow
            )
        }
        if let mins = minutesRemaining {
            return TimeInfo(
                title: "Time remaining",
                value: formatDuration(mins),
                subtitle: power.isLowPowerModeEnabled ? "Low Power Mode on" : "On battery",
                tint: snapshot.percent <= 20
                    ? NotchTheme.negative
                    : (power.isLowPowerModeEnabled ? NotchTheme.caution : NotchTheme.positive)
            )
        }
        return TimeInfo(
            title: "Time remaining",
            value: "Calculating…",
            subtitle: "Estimating from recent drain",
            tint: snapshot.percent <= 20 ? NotchTheme.negative : NotchTheme.textTertiary
        )
    }

    private var rateLabel: String? {
        if snapshot.isCharging, let mins = minutesToFull, mins > 0, snapshot.percent < 100 {
            let need = Double(100 - snapshot.percent)
            let rate = need / (Double(mins) / 60.0)
            if rate > 0.3, rate < 90 {
                return String(format: "+%.0f%%/h", rate)
            }
        }
        if !snapshot.isCharging, !snapshot.isPluggedIn, let drain = insight.drainPercentPerHour, drain > 0.15 {
            return String(format: "−%.1f%%/h", drain)
        }
        return nil
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

// MARK: - Sparkline

private struct BatterySparkline: View {
    let values: [Int]
    var tint: Color = NotchTheme.positive

    var body: some View {
        GeometryReader { geo in
            let pts = normalized(in: geo.size)
            ZStack {
                // Soft fill under the curve.
                Path { path in
                    guard let first = pts.first, let last = pts.last else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    path.addLine(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                if let last = pts.last {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .position(last)
                        .shadow(color: tint.opacity(0.5), radius: 2)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 1, size.height > 1 else { return [] }
        let minV = CGFloat(values.min() ?? 0)
        let maxV = CGFloat(values.max() ?? 100)
        let span = max(1, maxV - minV)
        let n = CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let x = CGFloat(i) / n * size.width
            let y = (1 - (CGFloat(v) - minV) / span) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}


// MARK: - Settings

private struct BatterySettingsView: View {
    @ObservedObject var plugin: BatteryPlugin
    @ObservedObject private var power = BatteryPowerMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Auto Low Power Mode", isOn: Binding(
                get: { power.autoEnableEnabled },
                set: { plugin.setAutoLowPower($0) }
            ))
            Text("When unplugged, turn on system Low Power Mode at or below the threshold.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Stepper(
                "Threshold: \(power.autoEnableAtPercent)%",
                value: Binding(
                    get: { power.autoEnableAtPercent },
                    set: { plugin.setAutoLowPowerThreshold($0) }
                ),
                in: 5...50,
                step: 5
            )
            .disabled(!power.autoEnableEnabled)

            Divider()

            Toggle("Show tips", isOn: $plugin.showTips)
            Toggle("Show charge history sparkline", isOn: $plugin.showHistorySparkline)
        }
    }
}
