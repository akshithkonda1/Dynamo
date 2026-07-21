import SwiftUI

// MARK: - Card

/// Standard content surface inside the expanded notch.
struct NotchCard<Content: View>: View {
    var padding: CGFloat = NotchTheme.spaceMD
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                    .fill(NotchTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                            .strokeBorder(NotchTheme.hairline, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Section header

struct NotchSectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: NotchTheme.spaceSM) {
            Text(title)
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
    }
}

// MARK: - Empty state

struct NotchEmptyState: View {
    var systemImage: String
    var title: String
    var caption: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(NotchTheme.textQuaternary)
            Text(title)
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
            if let caption {
                Text(caption)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NotchTheme.spaceMD)
    }
}

// MARK: - Status chip

struct NotchStatusChip: View {
    enum Kind {
        case neutral, now, soon, later, danger, success

        var fill: Color {
            switch self {
            case .neutral: return NotchTheme.chipFill
            case .now: return Color.green.opacity(0.22)
            case .soon: return Color.orange.opacity(0.22)
            case .later: return NotchTheme.chipFill
            case .danger: return Color.red.opacity(0.22)
            case .success: return Color.green.opacity(0.18)
            }
        }

        var foreground: Color {
            switch self {
            case .neutral, .later: return NotchTheme.textTertiary
            case .now: return Color.green.opacity(0.95)
            case .soon: return Color.orange.opacity(0.95)
            case .danger: return Color.red.opacity(0.95)
            case .success: return Color.green.opacity(0.9)
            }
        }
    }

    let text: String
    var kind: Kind = .neutral

    var body: some View {
        Text(text)
            .font(NotchTheme.micro.weight(.semibold))
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(kind.fill))
    }
}

// MARK: - Capsule chip label

struct NotchChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var active: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(NotchTheme.micro.weight(.semibold))
        }
        .foregroundStyle(active ? NotchTheme.textPrimary : NotchTheme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(active ? NotchTheme.chipFillActive : NotchTheme.chipFill))
    }
}
