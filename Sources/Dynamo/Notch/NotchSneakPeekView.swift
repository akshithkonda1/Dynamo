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

    /// Palette sampled from contact photo / artwork — drives chrome when present.
    private var photoPalette: CoverArtPalette? {
        guard let data = peek.artworkData, !data.isEmpty else { return nil }
        return CoverArtPalette.extract(from: data)
    }

    /// Contact-style peeks (calls/texts) prefer a circular crop for the photo.
    private var isContactStyle: Bool {
        let d = peek.detail.lowercased()
        return d.hasPrefix("call") || d.hasPrefix("text") || d.hasPrefix("mail")
            || peek.systemImage.contains("phone")
            || peek.systemImage.contains("message")
            || peek.systemImage.contains("person")
    }

    private var accentColor: Color {
        // Contact / artwork color wins so the island matches the photo.
        if let p = photoPalette {
            return p.primary.color
        }
        if isMedia {
            return mediaPulse.palette.primary.color
        }
        if isCritical { return NotchTheme.caution }
        if isUrgent { return NotchTheme.caution.opacity(0.95) }
        return NotchTheme.textPrimary
    }

    private var secondaryAccent: Color {
        if let p = photoPalette { return p.accent.color }
        if isMedia { return mediaPulse.palette.accent.color }
        return accentColor
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
                                .shadow(color: isMedia || photoPalette != nil ? .black.opacity(0.4) : .clear, radius: 1.5, y: 1)
                        }
                        if !peek.subtitle.isEmpty {
                            Text(peek.subtitle)
                                .font(NotchTheme.caption)
                                .foregroundStyle(
                                    isMedia || photoPalette != nil
                                        ? Color.white.opacity(0.78)
                                        : NotchTheme.textSecondary
                                )
                                .lineLimit(1)
                                .shadow(color: isMedia || photoPalette != nil ? .black.opacity(0.35) : .clear, radius: 1.5, y: 1)
                        }
                        // Detail only when no subtitle (keeps one-line peeks tight).
                        if peek.subtitle.isEmpty, !peek.detail.isEmpty {
                            Text(peek.detail)
                                .font(NotchTheme.micro)
                                .foregroundStyle(
                                    isMedia || photoPalette != nil
                                        ? Color.white.opacity(0.5)
                                        : NotchTheme.textTertiary
                                )
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
                            .foregroundStyle(
                                photoPalette != nil
                                    ? accentColor.opacity(0.75)
                                    : NotchTheme.textTertiary
                            )
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            // Hairline accent on the bottom lip — photo color when available.
            if isCritical || isUrgent || photoPalette != nil {
                VStack {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(isCritical ? 0.7 : 0.45),
                                    secondaryAccent.opacity(isCritical ? 0.55 : 0.28)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: isCritical ? 40 : (photoPalette != nil ? 32 : 24), height: 2)
                        .padding(.bottom, 5)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { peekBackground }
    }

    @ViewBuilder
    private var peekBackground: some View {
        if isMedia {
            Color.clear
        } else if let p = photoPalette {
            // Match contact / artwork palette — soft wash, not a solid block.
            LinearGradient(
                colors: [
                    p.primary.color.opacity(0.28),
                    p.accent.color.opacity(0.14),
                    p.deep.color.opacity(0.10),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
            let side: CGFloat = isMedia ? 36 : 32
            let glow = photoPalette?.primary.color.opacity(0.55)
                ?? (isMedia
                    ? Color(red: 0.3, green: 0.9, blue: 0.7).opacity(0.4)
                    : Color.black.opacity(0.3))
            Group {
                if isContactStyle && !isMedia {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            accentColor.opacity(0.85),
                                            secondaryAccent.opacity(0.45)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.25
                                )
                        )
                        .shadow(color: glow, radius: 6, y: 1)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    (photoPalette?.primary.color ?? Color.white)
                                        .opacity(isMedia ? 0.28 : 0.22),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: glow, radius: isMedia ? 6 : 4, y: 1)
                }
            }
        } else if isMedia {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                mediaPulse.palette.primary.color.opacity(0.4),
                                mediaPulse.palette.accent.color.opacity(0.4)
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
            .shadow(color: mediaPulse.palette.primary.color.opacity(0.4), radius: 5, y: 1)
        } else {
            Image(systemName: peek.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isUrgent
                                ? accentColor.opacity(0.18)
                                : NotchTheme.chipFillActive
                        )
                )
                .shadow(
                    color: accentColor.opacity(0.35),
                    radius: 2.5
                )
        }
    }
}
