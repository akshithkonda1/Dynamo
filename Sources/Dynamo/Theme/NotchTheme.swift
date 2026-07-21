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
    static let radiusExpanded: CGFloat = 22
    static let radiusCard: CGFloat = 14
    static let radiusIcon: CGFloat = 8
    static let radiusPill: CGFloat = 10

    // MARK: Type
    static let title = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let heroDigit = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12.5, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)
    static let section = Font.system(size: 10, weight: .semibold, design: .rounded)

    // MARK: Color roles (tuned for dark glass — opaque enough that desktop never reads as UI)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.50)
    static let textQuaternary = Color.white.opacity(0.36)
    static let separator = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.12)
    static let chipFill = Color.white.opacity(0.09)
    static let chipFillActive = Color.white.opacity(0.20)
    static let chipFillHover = Color.white.opacity(0.14)
    static let cardFill = Color.white.opacity(0.08)
    /// Strong scrim so behind-window desktop/content never looks like in-panel UI.
    static let panelScrim = Color.black.opacity(0.58)
    static let panelScrimExpanded = Color.black.opacity(0.62)
    static let positive = Color.green.opacity(0.92)
    static let negative = Color.red.opacity(0.92)
    static let caution = Color.orange.opacity(0.92)
    static let accent = Color.white.opacity(0.92)
    static let glow = Color.white.opacity(0.06)

    // MARK: Elevation
    static let shadowExpanded = Color.black.opacity(0.55)
    static let shadowRadius: CGFloat = 22
    static let shadowY: CGFloat = 10

    // MARK: Animation
    static var expandSpring: Animation {
        .spring(response: 0.38, dampingFraction: 0.86, blendDuration: 0.1)
    }

    static var contentSpring: Animation {
        .spring(response: 0.30, dampingFraction: 0.90)
    }

    static var quick: Animation {
        .easeOut(duration: 0.12)
    }
}
