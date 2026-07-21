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
    static let radiusCollapsed: CGFloat = 11
    static let radiusExpanded: CGFloat = 24
    static let radiusCard: CGFloat = 14
    static let radiusIcon: CGFloat = 8
    static let radiusPill: CGFloat = 10

    // MARK: Type
    static let title = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let heroDigit = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let ambientTime = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12.5, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)
    static let section = Font.system(size: 10, weight: .semibold, design: .rounded)

    // MARK: Color roles
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.50)
    static let textQuaternary = Color.white.opacity(0.36)
    static let separator = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.14)
    static let chipFill = Color.white.opacity(0.09)
    static let chipFillActive = Color.white.opacity(0.22)
    static let chipFillHover = Color.white.opacity(0.15)
    static let cardFill = Color.white.opacity(0.085)
    static let panelScrim = Color.black.opacity(0.58)
    static let panelScrimExpanded = Color.black.opacity(0.64)
    static let positive = Color.green.opacity(0.92)
    static let negative = Color.red.opacity(0.92)
    static let caution = Color.orange.opacity(0.92)
    static let accent = Color.white.opacity(0.94)
    static let glow = Color.white.opacity(0.07)
    /// Soft brand accent for active media / dynamic pulses.
    static let mediaGlow = Color(red: 0.55, green: 0.42, blue: 1.0).opacity(0.55)
    static let calmGlow = Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.40)

    // MARK: Elevation
    static let shadowExpanded = Color.black.opacity(0.58)
    static let shadowRadius: CGFloat = 26
    static let shadowY: CGFloat = 12

    // MARK: Animation
    static var expandSpring: Animation {
        .spring(response: 0.40, dampingFraction: 0.84, blendDuration: 0.12)
    }

    static var contentSpring: Animation {
        .spring(response: 0.32, dampingFraction: 0.90)
    }

    static var snappy: Animation {
        .spring(response: 0.22, dampingFraction: 0.86)
    }

    static var quick: Animation {
        .easeOut(duration: 0.12)
    }

    static var pulse: Animation {
        .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }
}
