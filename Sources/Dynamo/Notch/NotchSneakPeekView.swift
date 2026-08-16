import AppKit
import SwiftUI

/// Sneak-peek content for notched MacBooks.
///
/// Layout philosophy:
/// - Top band matches the physical camera housing so black glass fills the
///   cutout continuously (not a floating toast with a big empty void).
/// - Content sits in a single compact row just under the housing.
/// - Side cheeks flare slightly wider than the cutout for icon + title —
///   enough to read, not so wide it reads as a banner.
/// - Host `NotchShape` is the only silhouette (no inner border).
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

    /// Camera-band clearance from geometry (notched vs plain displays).
    private var topInset: CGFloat {
        NotchGeometry.peekContentTopInset(for: NSScreen.main)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isMedia {
                // Soft EQ sits under the whole island, dimmed under camera band.
                AuroraEqualizerView(isActive: true, barCount: 24, fps: 30)
                    .allowsHitTesting(false)
                    .mask(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.15),
                                Color.black.opacity(0.55),
                                Color.black.opacity(0.9)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 0) {
                // Continuous black under the camera — not a padded void.
                Color.clear
                    .frame(height: topInset)

                HStack(alignment: .center, spacing: 10) {
                    artOrIcon

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if isUrgent {
                                Text(urgencyBadge)
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(accentColor)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                            }
                            Text(peek.title)
                                .font(NotchTheme.body.weight(.semibold))
                                .foregroundStyle(NotchTheme.textPrimary)
                                .lineLimit(1)
                                .shadow(color: isMedia ? .black.opacity(0.4) : .clear, radius: 1.5, y: 1)
                        }
                        if !peek.subtitle.isEmpty {
                            Text(peek.subtitle)
                                .font(NotchTheme.caption)
                                .foregroundStyle(isMedia ? Color.white.opacity(0.78) : NotchTheme.textSecondary)
                                .lineLimit(1)
                                .shadow(color: isMedia ? .black.opacity(0.35) : .clear, radius: 1.5, y: 1)
                        }
                        // Detail only when no subtitle (keeps one-line peeks tight).
                        if peek.subtitle.isEmpty, !peek.detail.isEmpty {
                            Text(peek.detail)
                                .font(NotchTheme.micro)
                                .foregroundStyle(isMedia ? Color.white.opacity(0.5) : NotchTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 4)

                    if isMedia {
                        MusicBarsView(
                            isPlaying: mediaPulse.isPlaying,
                            barCount: 4,
                            maxHeight: 13,
                            color: mediaPulse.palette.primary.color.opacity(0.85)
                        )
                        .opacity(0.7)
                    } else if !peek.detail.isEmpty, !peek.subtitle.isEmpty {
                        // Trailing detail chip when both subtitle + detail exist.
                        Text(peek.detail)
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            // Hairline accent on the bottom lip only — urgency without a badge wall.
            if isCritical || isUrgent {
                VStack {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(accentColor.opacity(isCritical ? 0.55 : 0.32))
                        .frame(width: isCritical ? 36 : 24, height: 2)
                        .padding(.bottom, 5)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if isMedia {
                Color.clear
            } else if isCritical {
                LinearGradient(
                    colors: [
                        NotchTheme.caution.opacity(0.12),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if isUrgent {
                LinearGradient(
                    colors: [
                        NotchTheme.caution.opacity(0.07),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if peek.artworkData != nil {
                LinearGradient(
                    colors: [
                        NotchTheme.mediaGlow.opacity(0.10),
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
                .frame(width: isMedia ? 36 : 32, height: isMedia ? 36 : 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(isMedia ? 0.22 : 0.12), lineWidth: 0.5)
                )
                .shadow(
                    color: isMedia
                        ? Color(red: 0.3, green: 0.9, blue: 0.7).opacity(0.4)
                        : Color.black.opacity(0.3),
                    radius: isMedia ? 6 : 3,
                    y: 1
                )
        } else if isMedia {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
            }
            .frame(width: 36, height: 36)
            .shadow(color: Color(red: 0.3, green: 0.9, blue: 0.7).opacity(0.35), radius: 5, y: 1)
        } else {
            Image(systemName: peek.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isUrgent ? NotchTheme.caution.opacity(0.16) : NotchTheme.chipFillActive)
                )
                .shadow(
                    color: isUrgent ? NotchTheme.caution.opacity(0.35) : NotchTheme.mediaGlow.opacity(0.15),
                    radius: 2.5
                )
        }
    }
}
