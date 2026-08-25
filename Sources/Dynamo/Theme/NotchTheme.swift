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
    /// Slightly roomier than the collapsed ambient inset so wide island content breathes.
    static let contentInset: CGFloat = 16
    /// Horizontal inset for collapsed ambient (clock / media / weather).
    static let ambientInset: CGFloat = 12

    // MARK: Expanded chrome (must match NotchContentView measurements)
    /// Tray row: top 10 + chip ~34 + bottom 6 (labeled active tabs)
    static let chromeTray: CGFloat = 50
    /// Clock pill under tray: ~24 + bottom 8
    static let chromeClock: CGFloat = 30
    /// Hairline + bottom spacing
    static let chromeDivider: CGFloat = 10
    /// Bottom padding under widget content — tight so the lip feels flush.
    static let chromeContentBottom: CGFloat = 12
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
    /// Futuristic micro-label tracking (section headers, prefs titles).
    static let sectionTracking: CGFloat = 1.1

    // MARK: Color roles
    // Text on dark glass stays high-contrast white (island is always dark chrome).
    // Status colors come from `NSColor.system*` so they track macOS accessibility
    // and appearance, then slightly lifted for glass legibility.

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.74)
    static let textTertiary = Color.white.opacity(0.50)
    static let textQuaternary = Color.white.opacity(0.36)

    static let separator = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.16)

    static let chipFill = Color.white.opacity(0.09)
    static let chipFillActive = Color.white.opacity(0.20)
    static let chipFillHover = Color.white.opacity(0.13)
    static let cardFill = Color.white.opacity(0.07)

    /// Solid glass density — full coverage edge-to-edge (no transparent bottom).
    static let panelScrim = Color.black.opacity(0.46)
    static let panelScrimExpanded = Color.black.opacity(0.56)

    /// System semantic status, slightly boosted for dark glass.
    static var positive: Color { system(.systemGreen).opacity(0.95) }
    static var negative: Color { system(.systemRed).opacity(0.95) }
    static var caution: Color { system(.systemOrange).opacity(0.95) }
    /// Control accent when we need a “macOS selected” feel without leaving Dynamo.
    static var controlAccent: Color { system(.controlAccentColor).opacity(0.95) }

    static let accent = Color.white.opacity(0.95)
    static let glow = Color.white.opacity(0.06)
    /// Dynamo media energy — soft violet (identity, not system purple alone).
    static let mediaGlow = Color(red: 0.62, green: 0.48, blue: 1.0).opacity(0.55)
    static let calmGlow = Color(red: 0.38, green: 0.82, blue: 1.0).opacity(0.48)
    /// Tasteful neon glass accents (cyan ↔ violet).
    static let neonCyan = Color(red: 0.35, green: 0.92, blue: 1.0)
    static let neonViolet = Color(red: 0.72, green: 0.48, blue: 1.0)
    static let neonEdge = LinearGradient(
        colors: [
            neonCyan.opacity(0.55),
            Color.white.opacity(0.18),
            neonViolet.opacity(0.45)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

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

    // MARK: Animation — instantaneous feel (tight springs, short settles)
    /// Island expand/collapse.
    static var expandSpring: Animation {
        .spring(response: 0.20, dampingFraction: 0.90, blendDuration: 0.04)
    }

    /// Content cross-fade / tab switch.
    static var contentSpring: Animation {
        .spring(response: 0.16, dampingFraction: 0.92, blendDuration: 0.03)
    }

    static var snappy: Animation {
        .spring(response: 0.12, dampingFraction: 0.90)
    }

    static var quick: Animation {
        .easeOut(duration: 0.07)
    }

    /// Ambient rim pulse — slow so it costs almost no CPU.
    static var pulse: Animation {
        .easeInOut(duration: 2.6).repeatForever(autoreverses: true)
    }

    /// Match AppKit panel frame animation to SwiftUI expand spring feel.
    static let panelExpandDuration: TimeInterval = 0.20
    /// Standard macOS ease with a light overshoot for island character.
    static var panelExpandTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 0.95, 0.18, 1.02)
    }

    // MARK: Helpers

    /// Bridge `NSColor` → SwiftUI `Color` for semantic system colors.
    static func system(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }
}
