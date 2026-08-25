import AppKit
import SwiftUI

/// Compact volume / brightness Peek shown in the notch — Dynamo’s replacement
/// for the stock macOS OSD when takeover is enabled.
struct SystemHUDView: View {
    let state: SystemHUDState
    @ObservedObject private var volume = SystemVolumeController.shared

    private var displayLevel: Float {
        if state.kind == .volume {
            return volume.isMuted ? 0 : volume.level
        }
        return state.level
    }

    private var displayMuted: Bool {
        state.kind == .volume ? volume.isMuted : state.isMuted
    }

    private var accent: Color {
        switch state.kind {
        case .volume: return NotchTheme.neonCyan
        case .brightness: return Color(red: 1.0, green: 0.84, blue: 0.35)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: NotchGeometry.peekContentTopInset(for: NSScreen.main))

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleLabel)
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(NotchTheme.chipFill)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            accent.opacity(0.95),
                                            accent.opacity(0.65)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(displayMuted ? 0 : 8, geo.size.width * CGFloat(displayLevel)))
                                .shadow(color: accent.opacity(0.35), radius: 4, y: 0)
                        }
                    }
                    .frame(height: 7)
                }

                Text(percentLabel)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                    .frame(width: 48, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var titleLabel: String {
        switch state.kind {
        case .volume: return displayMuted ? "Muted" : "Volume"
        case .brightness: return "Brightness"
        }
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
            return "\(volume.percent)%"
        }
        if let bright = SystemLevelReader.displayBrightnessPercent() {
            return "\(bright)%"
        }
        return "\(Int((displayLevel * 100).rounded()))%"
    }
}
