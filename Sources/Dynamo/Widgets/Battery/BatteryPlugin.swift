import SwiftUI

@MainActor
final class BatteryPlugin: ObservableObject, NotchWidgetPlugin {
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
        AnyView(ExpandedBatteryView(snapshot: snapshot))
    }
}

// MARK: - Views

private struct ExpandedBatteryView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceMD) {
            Text("Battery")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)

            if !snapshot.isPresent {
                Text("No internal battery detected (desktop Mac or power-source unavailable).")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NotchTheme.spaceSM) {
                    Text("\(snapshot.percent)%")
                        .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
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
                        Capsule()
                            .fill(NotchTheme.chipFill)
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(8, geo.size.width * CGFloat(snapshot.percent) / 100))
                    }
                }
                .frame(height: 8)
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
        return Color.white.opacity(0.85)
    }
}
