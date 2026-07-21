import QuartzCore
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

    /// Horizontal inset for expanded content + ambient rows (keep all widgets aligned).
    static let contentInset: CGFloat = 12
    /// Horizontal inset for collapsed ambient (clock / media / weather).
    static let ambientInset: CGFloat = 12

    // MARK: Expanded chrome (must match NotchContentView measurements)
    /// Tray row: top 11 + icon 32 + bottom 6
    static let chromeTray: CGFloat = 49
    /// Clock pill under tray: ~24 + bottom 8
    static let chromeClock: CGFloat = 32
    /// Hairline + bottom spacing
    static let chromeDivider: CGFloat = 12
    /// Bottom padding under widget content
    static let chromeContentBottom: CGFloat = 14
    /// Total height added above a widget’s `expandedContentHeight`
    static var expandedChromeHeight: CGFloat {
        chromeTray + chromeClock + chromeDivider + chromeContentBottom
    }

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

    // MARK: Animation (macOS / Boring Notch–style springs)
    /// Island expand/collapse — slightly under-damped for a soft “pop”.
    static var expandSpring: Animation {
        .spring(response: 0.48, dampingFraction: 0.78, blendDuration: 0.12)
    }

    /// Content cross-fade / tab switch.
    static var contentSpring: Animation {
        .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.08)
    }

    static var snappy: Animation {
        .spring(response: 0.22, dampingFraction: 0.82)
    }

    static var quick: Animation {
        .easeOut(duration: 0.12)
    }

    /// Ambient rim pulse — slow so it costs almost no CPU.
    static var pulse: Animation {
        .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
    }

    /// Match AppKit panel frame animation to SwiftUI expand spring feel.
    static let panelExpandDuration: TimeInterval = 0.48
    /// Ease-out with a hint of overshoot (Dynamic Island–like).
    static var panelExpandTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1.15, 0.36, 1.0)
    }
}
