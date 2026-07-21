import SwiftUI

/// Compact volume / brightness meter shown over the notch tray.
/// Volume HUD reflects live Core Audio levels (keys, Control Center, or Dynamo).
struct SystemHUDView: View {
    let state: SystemHUDState
    @ObservedObject private var volume = SystemVolumeController.shared

    /// Prefer live machine volume when showing the volume HUD.
    private var displayLevel: Float {
        if state.kind == .volume {
            return volume.isMuted ? 0 : volume.level
        }
        return state.level
    }

    private var displayMuted: Bool {
        state.kind == .volume ? volume.isMuted : state.isMuted
    }

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
                        .frame(width: max(displayMuted ? 0 : 6, geo.size.width * CGFloat(displayLevel)))
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
            if displayMuted || displayLevel <= 0.001 { return "speaker.slash.fill" }
            if displayLevel < 0.33 { return "speaker.wave.1.fill" }
            if displayLevel < 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return "sun.max.fill"
        }
    }

    private var percentLabel: String {
        if state.kind == .volume {
            if displayMuted { return "Mute" }
            // Use integer percent from the controller (exact system UI value).
            return "\(volume.percent)%"
        }
        if let bright = SystemLevelReader.displayBrightnessPercent() {
            return "\(bright)%"
        }
        return "\(Int((displayLevel * 100).rounded()))%"
    }
}
