import SwiftUI

/// Compact "sneak peek" pill: icon + title/subtitle, shown briefly in the
/// notch when a widget has something noteworthy to report.
struct NotchSneakPeekView: View {
    let peek: NotchSneakPeek

    private var isCritical: Bool { peek.emphasis == .critical }
    private var accentColor: Color { isCritical ? NotchTheme.caution : NotchTheme.textPrimary }

    var body: some View {
        HStack(spacing: NotchTheme.spaceMD) {
            Image(systemName: peek.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 20)
                .shadow(color: isCritical ? NotchTheme.caution.opacity(0.85) : .clear, radius: isCritical ? 6 : 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(NotchTheme.body.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                if !peek.subtitle.isEmpty {
                    Text(peek.subtitle)
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(isCritical ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.spaceLG)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(glowBackground)
        .overlay(glowBorder)
    }

    // A soft warning-colored wash + border behind critical peeks — the
    // "glow" — layered on top of the routine peek's plain vibrancy background.
    @ViewBuilder
    private var glowBackground: some View {
        if isCritical {
            RoundedRectangle(cornerRadius: NotchTheme.radiusExpanded, style: .continuous)
                .fill(NotchTheme.caution.opacity(0.16))
        }
    }

    @ViewBuilder
    private var glowBorder: some View {
        if isCritical {
            RoundedRectangle(cornerRadius: NotchTheme.radiusExpanded, style: .continuous)
                .stroke(NotchTheme.caution.opacity(0.55), lineWidth: 1)
        }
    }
}
