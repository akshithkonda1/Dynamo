import SwiftUI

/// Compact "sneak peek" pill: icon + title/subtitle, shown briefly in the
/// notch when a widget has something noteworthy to report.
struct NotchSneakPeekView: View {
    let peek: NotchSneakPeek

    var body: some View {
        HStack(spacing: NotchTheme.spaceMD) {
            Image(systemName: peek.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(NotchTheme.body.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                if !peek.subtitle.isEmpty {
                    Text(peek.subtitle)
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.spaceLG)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
