import SwiftUI

@MainActor
final class BatteryPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding {
    let id = "battery"
    let displayName = "Battery"
    let systemImage = "battery.100"

    @Published private(set) var snapshot: BatterySnapshot = .unknown

    private let provider: BatteryProvider

    init(provider: BatteryProvider? = nil) {
        let resolved = provider ?? IOKitBatteryProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] value in
            self?.snapshot = value
        }
    }

    func start() {
        provider.start()
        snapshot = provider.current
    }

    func stop() {
        provider.stop()
    }

    func expandedView() -> AnyView {
        // Pass plugin so the expanded view observes live battery updates.
        AnyView(ExpandedBatteryView(plugin: self))
    }

    var expandedContentHeight: CGFloat { 140 }

    // MARK: Ambient

    var isAmbientActive: Bool {
        // Only surface low battery in the collapsed strip — constant charging
        // ambient was noise when media/calendar weren't active.
        snapshot.isPresent && snapshot.percent <= 20
    }

    var ambientPriority: Int {
        if snapshot.isPresent, snapshot.percent <= 10 { return 90 }
        if snapshot.isPresent, snapshot.percent <= 15 { return 80 }
        if snapshot.isPresent, snapshot.percent <= 20 { return 70 }
        return 10
    }

    func ambientView() -> AnyView {
        AnyView(AmbientBatteryView(snapshot: snapshot))
    }
}

// MARK: - Ambient

private struct AmbientBatteryView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(snapshot.percent)%")
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        if snapshot.isCharging { return "bolt.fill" }
        if snapshot.percent <= 15 { return "battery.0" }
        if snapshot.percent <= 40 { return "battery.25" }
        return "battery.50"
    }

    private var tint: Color {
        if snapshot.isCharging { return NotchTheme.positive }
        if snapshot.percent <= 15 { return NotchTheme.negative }
        if snapshot.percent <= 20 { return NotchTheme.caution }
        return NotchTheme.textSecondary
    }
}

// MARK: - Expanded

private struct ExpandedBatteryView: View {
    @ObservedObject var plugin: BatteryPlugin

    private var snapshot: BatterySnapshot { plugin.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceMD) {
            NotchSectionHeader("Battery")

            if !snapshot.isPresent {
                NotchEmptyState(
                    systemImage: "laptopcomputer",
                    title: "No internal battery",
                    caption: "Desktop Mac or power source unavailable.",
                    prominent: true
                )
            } else {
                NotchCard {
                    VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
                        HStack(alignment: .firstTextBaseline, spacing: NotchTheme.spaceSM) {
                            Text("\(snapshot.percent)%")
                                .font(NotchTheme.heroDigit.monospacedDigit())
                                .foregroundStyle(barColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(statusLabel)
                                    .font(NotchTheme.body)
                                    .foregroundStyle(NotchTheme.textSecondary)
                                if let minutes = snapshot.timeRemainingMinutes {
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
                        .frame(height: 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusLabel: String {
        if snapshot.isCharging { return "Charging" }
        if snapshot.isPluggedIn { return "Plugged in" }
        return "On battery"
    }

    private func timeLabel(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if snapshot.isCharging {
            return h > 0 ? "\(h)h \(m)m to full" : "\(m)m to full"
        }
        return h > 0 ? "\(h)h \(m)m remaining" : "\(m)m remaining"
    }

    private var barColor: Color {
        if snapshot.isCharging { return NotchTheme.positive }
        if snapshot.percent <= 15 { return NotchTheme.negative }
        if snapshot.percent <= 25 { return NotchTheme.caution }
        return NotchTheme.textPrimary
    }
}
