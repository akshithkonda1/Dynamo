import SwiftUI

/// Shared visual tokens for the notch tray and every widget expanded view.
/// Prefer these over hardcoded spacing / type / color values.
enum NotchTheme {
    // MARK: Spacing
    static let spaceXS: CGFloat = 4
    static let spaceSM: CGFloat = 8
    static let spaceMD: CGFloat = 12
    static let spaceLG: CGFloat = 16
    static let spaceXL: CGFloat = 20

    // MARK: Radii
    static let radiusCollapsed: CGFloat = 10
    static let radiusExpanded: CGFloat = 20
    static let radiusCard: CGFloat = 12
    static let radiusIcon: CGFloat = 8
    static let radiusPill: CGFloat = 9

    // MARK: Type
    static let title = Font.system(size: 14, weight: .semibold)
    static let heroDigit = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)
    static let section = Font.system(size: 10, weight: .semibold)

    // MARK: Color roles (tuned for vibrancy / dark material)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.70)
    static let textTertiary = Color.white.opacity(0.48)
    static let textQuaternary = Color.white.opacity(0.34)
    static let separator = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.08)
    static let chipFill = Color.white.opacity(0.10)
    static let chipFillActive = Color.white.opacity(0.18)
    static let chipFillHover = Color.white.opacity(0.14)
    static let cardFill = Color.white.opacity(0.07)
    static let panelScrim = Color.black.opacity(0.32)
    static let positive = Color.green.opacity(0.90)
    static let negative = Color.red.opacity(0.90)
    static let caution = Color.orange.opacity(0.90)
    static let accent = Color.white.opacity(0.88)

    // MARK: Animation
    static var expandSpring: Animation {
        .spring(response: 0.36, dampingFraction: 0.84, blendDuration: 0.08)
    }

    static var contentSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.88)
    }

    static var quick: Animation {
        .easeOut(duration: 0.14)
    }
}
