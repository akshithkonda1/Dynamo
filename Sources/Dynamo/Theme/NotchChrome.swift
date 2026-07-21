import SwiftUI

// MARK: - Card

/// Standard content surface inside the expanded notch — soft glass plate.
struct NotchCard<Content: View>: View {
    var padding: CGFloat = NotchTheme.spaceMD
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(compact ? NotchTheme.spaceSM : padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .fill(NotchTheme.cardFill)
                    // Inner top sheen
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.07), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
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
                .tracking(0.8)
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
    var prominent: Bool = false

    var body: some View {
        VStack(spacing: prominent ? 8 : 5) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 22 : 16, weight: .medium))
                .foregroundStyle(NotchTheme.textQuaternary)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
            if let caption {
                Text(caption)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, prominent ? NotchTheme.spaceMD : NotchTheme.spaceSM)
    }
}

// MARK: - Status chip

struct NotchStatusChip: View {
    enum Kind {
        case neutral, now, soon, later, danger, success

        var fill: Color {
            switch self {
            case .neutral: return NotchTheme.chipFill
            case .now: return Color.green.opacity(0.20)
            case .soon: return Color.orange.opacity(0.20)
            case .later: return NotchTheme.chipFill
            case .danger: return Color.red.opacity(0.20)
            case .success: return Color.green.opacity(0.16)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(kind.fill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(kind.foreground.opacity(0.18), lineWidth: 0.5)
                    )
            )
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(active ? NotchTheme.chipFillActive : NotchTheme.chipFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(NotchTheme.hairline.opacity(active ? 0.9 : 0.45), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Row surface

struct NotchRowBackground: ViewModifier {
    var selected: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? NotchTheme.chipFillActive : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

extension View {
    func notchRowBackground(selected: Bool = false) -> some View {
        modifier(NotchRowBackground(selected: selected))
    }
}
