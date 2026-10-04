import AppKit
import SwiftUI

/// Collapsed Ambient pill: album art in the left cheek, camera gap, decorative
/// waveform in the right cheek. Menu-bar height only — no title, no clock.
struct AmbientPillView: View {
    @ObservedObject private var pulse = MediaPeekPulse.shared

    var body: some View {
        HStack(spacing: 0) {
            artThumb
                .frame(width: NotchGeometry.ambientCheekWidth)
            Color.clear
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            AmbientWaveformView(
                isPlaying: pulse.isPlaying,
                tint: AmbientWaveform.tint(
                    hasArtwork: pulse.artworkData != nil,
                    palette: pulse.palette
                )
            )
            .frame(width: NotchGeometry.ambientCheekWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Playing")
    }

    @ViewBuilder
    private var artThumb: some View {
        let side: CGFloat = 16
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Group {
            if let data = pulse.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            } else {
                shape
                    .fill(NotchTheme.chipFill)
                    .frame(width: side, height: side)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(NotchTheme.textSecondary)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
