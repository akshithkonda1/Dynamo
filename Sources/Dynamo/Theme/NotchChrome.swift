import SwiftUI

// MARK: - Card

/// Content surface inside the expanded notch — native material + Dynamo edge.
struct NotchCard<Content: View>: View {
    var padding: CGFloat = NotchTheme.spaceMD
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Material plate owns the glass; padding keeps legacy NotchCard API.
        content()
            .padding(compact ? NotchTheme.spaceSM : padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    NotchTheme.cardFill.opacity(0.5),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                }
                .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
            }
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
                .tracking(0.7)
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
        .accessibilityAddTraits(.isHeader)
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
                .symbolVariant(.none)
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

// MARK: - Status chip (system semantic colors)

struct NotchStatusChip: View {
    enum Kind {
        case neutral, now, soon, later, danger, success

        var fill: Color {
            switch self {
            case .neutral, .later: return NotchTheme.chipFill
            case .now: return NotchTheme.positive.opacity(0.18)
            case .soon: return NotchTheme.caution.opacity(0.18)
            case .danger: return NotchTheme.negative.opacity(0.18)
            case .success: return NotchTheme.positive.opacity(0.14)
            }
        }

        var foreground: Color {
            switch self {
            case .neutral, .later: return NotchTheme.textTertiary
            case .now, .success: return NotchTheme.positive
            case .soon: return NotchTheme.caution
            case .danger: return NotchTheme.negative
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
                            .strokeBorder(kind.foreground.opacity(0.16), lineWidth: 0.5)
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
                    .symbolRenderingMode(.hierarchical)
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
                        .strokeBorder(
                            active
                                ? NotchTheme.controlAccent.opacity(0.35)
                                : NotchTheme.hairline.opacity(0.45),
                            lineWidth: 0.5
                        )
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? NotchTheme.chipFillActive : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    func notchRowBackground(selected: Bool = false) -> some View {
        modifier(NotchRowBackground(selected: selected))
    }
}
