import AppKit
import SwiftUI

/// Sneak-peek pill with optional cover art and urgency-aware styling.
/// Media peeks become a full-bleed aurora equalizer island.
/// No internal border stroke — host `NotchShape` is the only silhouette.
struct NotchSneakPeekView: View {
    let peek: NotchSneakPeek
    /// Live transport + cover palette for media aurora EQ.
    @ObservedObject private var mediaPulse = MediaPeekPulse.shared

    private var isMedia: Bool { peek.style == .media }
    private var isUrgent: Bool { peek.urgency >= .high }
    private var isCritical: Bool { peek.urgency == .critical }
    private var accentColor: Color {
        if isCritical { return NotchTheme.caution }
        if isUrgent { return NotchTheme.caution.opacity(0.95) }
        return NotchTheme.textPrimary
    }

    var body: some View {
        ZStack {
            if isMedia {
                // Subtle full-bleed EQ under the track row (doesn’t compete with text).
                AuroraEqualizerView(isActive: true, barCount: 32, fps: 48)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                // Clear the camera housing so content hangs below the cutout.
                Spacer(minLength: isMedia ? 10 : 8)
                HStack(alignment: .center, spacing: 12) {
                    artOrIcon

                    VStack(alignment: .leading, spacing: 2) {
                        if isUrgent {
                            Text(urgencyBadge)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(accentColor)
                                .textCase(.uppercase)
                                .tracking(0.6)
                        }
                        Text(peek.title)
                            .font(NotchTheme.body.weight(.semibold))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)
                            .shadow(color: isMedia ? .black.opacity(0.4) : .clear, radius: 1.5, y: 1)
                        if !peek.subtitle.isEmpty {
                            Text(peek.subtitle)
                                .font(NotchTheme.caption)
                                .foregroundStyle(isMedia ? Color.white.opacity(0.78) : NotchTheme.textSecondary)
                                .lineLimit(1)
                                .shadow(color: isMedia ? .black.opacity(0.35) : .clear, radius: 1.5, y: 1)
                        }
                        if !peek.detail.isEmpty {
                            Text(peek.detail)
                                .font(NotchTheme.micro)
                                .foregroundStyle(isMedia ? Color.white.opacity(0.5) : NotchTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)

                    if isMedia {
                        // Tiny accent bars — quiet companion, not a second EQ.
                        MusicBarsView(
                            isPlaying: mediaPulse.isPlaying,
                            barCount: 5,
                            maxHeight: 15,
                            color: mediaPulse.palette.primary.color.opacity(0.85)
                        )
                        .opacity(0.75)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, isMedia ? 14 : 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if isMedia {
                Color.clear // aurora layer is the background
            } else if isCritical {
                LinearGradient(
                    colors: [
                        NotchTheme.caution.opacity(0.14),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if isUrgent {
                LinearGradient(
                    colors: [
                        NotchTheme.caution.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if peek.artworkData != nil {
                LinearGradient(
                    colors: [
                        NotchTheme.mediaGlow.opacity(0.12),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private var urgencyBadge: String {
        switch peek.urgency {
        case .critical: return "Now"
        case .high: return "Soon"
        default: return ""
        }
    }

    @ViewBuilder
    private var artOrIcon: some View {
        if let data = peek.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: isMedia ? 44 : 40, height: isMedia ? 44 : 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(isMedia ? 0.22 : 0.12), lineWidth: 0.5)
                )
                .shadow(
                    color: isMedia
                        ? Color(red: 0.3, green: 0.9, blue: 0.7).opacity(0.45)
                        : Color.black.opacity(0.35),
                    radius: isMedia ? 8 : 4,
                    y: 2
                )
        } else if isMedia {
            // Aurora-tinted music glyph when art is still loading.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.25, green: 0.85, blue: 0.65).opacity(0.35),
                                Color(red: 0.45, green: 0.3, blue: 0.9).opacity(0.4)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: peek.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
            }
            .frame(width: 44, height: 44)
            .shadow(color: Color(red: 0.3, green: 0.9, blue: 0.7).opacity(0.4), radius: 6, y: 2)
        } else {
            Image(systemName: peek.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isUrgent ? NotchTheme.caution.opacity(0.16) : NotchTheme.chipFillActive)
                )
                .shadow(
                    color: isUrgent ? NotchTheme.caution.opacity(0.4) : NotchTheme.mediaGlow.opacity(0.2),
                    radius: 3
                )
        }
    }
}
