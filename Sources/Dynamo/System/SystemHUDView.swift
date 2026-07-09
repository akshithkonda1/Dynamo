import SwiftUI

/// Compact volume / brightness meter shown over the notch tray.
struct SystemHUDView: View {
    let state: SystemHUDState

    var body: some View {
        HStack(spacing: NotchTheme.spaceMD) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .frame(width: 24)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(NotchTheme.chipFill)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(state.isMuted ? 0 : 6, geo.size.width * CGFloat(state.level)))
                }
            }
            .frame(height: 6)

            Text(percentLabel)
                .font(NotchTheme.caption.monospacedDigit())
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, NotchTheme.spaceLG)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        switch state.kind {
        case .volume:
            if state.isMuted || state.level <= 0.001 { return "speaker.slash.fill" }
            if state.level < 0.33 { return "speaker.wave.1.fill" }
            if state.level < 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return "sun.max.fill"
        }
    }

    private var percentLabel: String {
        if state.kind == .volume, state.isMuted { return "Mute" }
        return "\(Int((state.level * 100).rounded()))%"
    }
}
