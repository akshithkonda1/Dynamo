import SwiftUI

/// Dedicated notch section for **system** output volume (Core Audio).
/// Separate from Media so transport and machine volume stay in their own homes.
/// Disable this widget in Settings to hide it from the tray entirely.
@MainActor
final class VolumePlugin: ObservableObject, NotchWidgetPlugin {
    let id = "volume"
    let displayName = "Volume"
    let systemImage = "speaker.wave.2.fill"

    private let volume = SystemVolumeController.shared

    func start() {
        volume.start()
        volume.refreshFromSystem()
    }

    func stop() {
        // Shared controller also used by the HUD — leave listeners running.
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedVolumeView())
    }
}

// MARK: - Expanded

private struct ExpandedVolumeView: View {
    @ObservedObject private var volume = SystemVolumeController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceMD) {
            HStack(spacing: 6) {
                Text("System Volume")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                if let name = volume.deviceName, !name.isEmpty {
                    Text(name)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: NotchTheme.spaceSM) {
                Text(volume.isMuted ? "Muted" : "\(percent)%")
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(volume.isMuted ? "Output silenced" : "Machine output")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
                Spacer(minLength: 0)
            }

            // Big meter — live from Core Audio.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(NotchTheme.chipFill)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(volume.isMuted || volume.level <= 0.001 ? 0 : 8,
                                          geo.size.width * CGFloat(volume.isMuted ? 0 : volume.level)))
                }
            }
            .frame(height: 10)

            // Control row: mute + system volume slider (writes to Core Audio).
            HStack(spacing: 10) {
                Button {
                    volume.toggleMute()
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(NotchTheme.chipFillActive))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(volume.isMuted ? "Unmute system output" : "Mute system output")

                Slider(
                    value: Binding(
                        get: { Double(volume.isMuted ? 0 : volume.level) },
                        set: { volume.setLevel(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.regular)
                .tint(Color.white.opacity(0.9))
                .help("Change system output volume")

                HStack(spacing: 4) {
                    Button {
                        volume.nudge(by: -0.0625) // one step (~1/16)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(NotchTheme.chipFill))
                    }
                    .buttonStyle(.plain)
                    .help("Volume down")

                    Button {
                        volume.nudge(by: 0.0625)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(NotchTheme.chipFill))
                    }
                    .buttonStyle(.plain)
                    .help("Volume up")
                }
            }

            Text("Controls the Mac’s system output — same as the volume keys and menu bar. Turn this widget off in Settings to hide it from the tray.")
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            volume.start()
            volume.refreshFromSystem()
        }
    }

    private var percent: Int {
        Int((volume.level * 100).rounded())
    }

    private var volumeIcon: String {
        if volume.isMuted || volume.level <= 0.001 { return "speaker.slash.fill" }
        if volume.level < 0.33 { return "speaker.wave.1.fill" }
        if volume.level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
