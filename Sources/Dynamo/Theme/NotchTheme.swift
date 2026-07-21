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

    // MARK: Radii — slightly tighter for a more jewel-like island
    static let radiusCollapsed: CGFloat = 12
    static let radiusExpanded: CGFloat = 26
    static let radiusCard: CGFloat = 13
    static let radiusIcon: CGFloat = 8
    static let radiusPill: CGFloat = 10

    // MARK: Type
    static let title = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let heroDigit = Font.system(size: 32, weight: .semibold, design: .rounded)
    static let ambientTime = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12.5, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)
    static let section = Font.system(size: 9.5, weight: .semibold, design: .rounded)

    // MARK: Color roles — high-contrast glass, restrained accents
    static let textPrimary = Color.white.opacity(0.97)
    static let textSecondary = Color.white.opacity(0.74)
    static let textTertiary = Color.white.opacity(0.48)
    static let textQuaternary = Color.white.opacity(0.34)
    static let separator = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.16)
    static let chipFill = Color.white.opacity(0.08)
    static let chipFillActive = Color.white.opacity(0.20)
    static let chipFillHover = Color.white.opacity(0.13)
    static let cardFill = Color.white.opacity(0.07)
    static let panelScrim = Color.black.opacity(0.60)
    static let panelScrimExpanded = Color.black.opacity(0.68)
    static let positive = Color(red: 0.35, green: 0.92, blue: 0.55).opacity(0.95)
    static let negative = Color(red: 1.0, green: 0.38, blue: 0.40).opacity(0.95)
    static let caution = Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.95)
    static let accent = Color.white.opacity(0.95)
    static let glow = Color.white.opacity(0.06)
    /// Soft violet for media energy (kept subtle).
    static let mediaGlow = Color(red: 0.62, green: 0.48, blue: 1.0).opacity(0.50)
    static let calmGlow = Color(red: 0.40, green: 0.78, blue: 1.0).opacity(0.42)

    // MARK: Elevation
    static let shadowExpanded = Color.black.opacity(0.62)
    static let shadowRadius: CGFloat = 28
    static let shadowY: CGFloat = 14

    // MARK: Animation
    static var expandSpring: Animation {
        .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    }

    static var contentSpring: Animation {
        .spring(response: 0.30, dampingFraction: 0.92)
    }

    static var snappy: Animation {
        .spring(response: 0.20, dampingFraction: 0.88)
    }

    static var quick: Animation {
        .easeOut(duration: 0.11)
    }

    static var pulse: Animation {
        .easeInOut(duration: 2.0).repeatForever(autoreverses: true)
    }
}
