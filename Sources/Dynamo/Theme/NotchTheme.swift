import AppKit
import QuartzCore
import SwiftUI

/// Dynamo’s visual system sits on **native macOS foundations** with a
/// deliberate island design language layered on top.
///
/// | Layer | Source |
/// |-------|--------|
/// | Glass / blur | `NSVisualEffectView` materials |
/// | Semantics | `NSColor` label / system status colors |
/// | Motion | AppKit-compatible springs + CAMediaTiming |
/// | Identity | Rounded display type, jewel radii, media/calm glows |
///
/// Prefer these tokens over hardcoded values so widgets stay consistent and
/// continue to feel like macOS even as Dynamo stays distinctive.
enum NotchTheme {
    // MARK: Spacing (8pt grid — native HIG rhythm)
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
    /// Bottom padding under widget content — tight so the lip feels flush.
    static let chromeContentBottom: CGFloat = 10
    /// Total height added above a widget’s `expandedContentHeight`
    static var expandedChromeHeight: CGFloat {
        chromeTray + chromeClock + chromeDivider + chromeContentBottom
    }

    // MARK: Radii — Continuous curves (AppKit-friendly) with Dynamo jewel tightness
    static let radiusCollapsed: CGFloat = 12
    static let radiusExpanded: CGFloat = 26
    static let radiusCard: CGFloat = 12
    static let radiusIcon: CGFloat = 8
    static let radiusPill: CGFloat = 10

    // MARK: Type
    /// Display / hero — Dynamo signature (rounded SF).
    static let title = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let heroDigit = Font.system(size: 32, weight: .semibold, design: .rounded)
    static let ambientTime = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let section = Font.system(size: 9.5, weight: .semibold, design: .rounded)
    /// Body copy — default SF for native readability on glass.
    static let body = Font.system(size: 12.5, weight: .medium, design: .default)
    static let caption = Font.system(size: 11, weight: .medium, design: .default)
    static let micro = Font.system(size: 10, weight: .medium, design: .default)

    // MARK: Color roles
    // Text on dark glass stays high-contrast white (island is always dark chrome).
    // Status colors come from `NSColor.system*` so they track macOS accessibility
    // and appearance, then slightly lifted for glass legibility.

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.48)
    static let textQuaternary = Color.white.opacity(0.34)

    static let separator = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.14)

    static let chipFill = Color.white.opacity(0.08)
    static let chipFillActive = Color.white.opacity(0.18)
    static let chipFillHover = Color.white.opacity(0.12)
    static let cardFill = Color.white.opacity(0.06)

    /// Solid glass density — full coverage edge-to-edge (no transparent bottom).
    static let panelScrim = Color.black.opacity(0.42)
    static let panelScrimExpanded = Color.black.opacity(0.52)

    /// System semantic status, slightly boosted for dark glass.
    static var positive: Color { system(.systemGreen).opacity(0.95) }
    static var negative: Color { system(.systemRed).opacity(0.95) }
    static var caution: Color { system(.systemOrange).opacity(0.95) }
    /// Control accent when we need a “macOS selected” feel without leaving Dynamo.
    static var controlAccent: Color { system(.controlAccentColor).opacity(0.95) }

    static let accent = Color.white.opacity(0.95)
    static let glow = Color.white.opacity(0.05)
    /// Dynamo media energy — soft violet (identity, not system purple alone).
    static let mediaGlow = Color(red: 0.62, green: 0.48, blue: 1.0).opacity(0.48)
    static let calmGlow = Color(red: 0.40, green: 0.78, blue: 1.0).opacity(0.40)

    // MARK: Materials (NSVisualEffectView)
    /// Collapsed notch / HUD — matches menu bar / HUD chrome.
    static let materialCollapsed: NSVisualEffectView.Material = .hudWindow
    /// Expanded island — richer popover glass (still native).
    static let materialExpanded: NSVisualEffectView.Material = .popover
    /// Peek / overlay — menu-like material.
    static let materialOverlay: NSVisualEffectView.Material = .menu

    // MARK: Elevation
    static let shadowExpanded = Color.black.opacity(0.55)
    static let shadowRadius: CGFloat = 24
    static let shadowY: CGFloat = 12

    // MARK: Animation — AppKit-compatible springs (feels like system sheets / Dock)
    /// Island expand/collapse.
    static var expandSpring: Animation {
        .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.10)
    }

    /// Content cross-fade / tab switch.
    static var contentSpring: Animation {
        .spring(response: 0.32, dampingFraction: 0.90, blendDuration: 0.06)
    }

    static var snappy: Animation {
        .spring(response: 0.22, dampingFraction: 0.88)
    }

    static var quick: Animation {
        .easeOut(duration: 0.14)
    }

    /// Ambient rim pulse — slow so it costs almost no CPU.
    static var pulse: Animation {
        .easeInOut(duration: 2.6).repeatForever(autoreverses: true)
    }

    /// Match AppKit panel frame animation to SwiftUI expand spring feel.
    static let panelExpandDuration: TimeInterval = 0.42
    /// Standard macOS ease with a light overshoot for island character.
    static var panelExpandTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
    }

    // MARK: Helpers

    /// Bridge `NSColor` → SwiftUI `Color` for semantic system colors.
    static func system(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }
}
