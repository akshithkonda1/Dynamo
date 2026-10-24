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
    /// Generous enough to match the compact hanging card, not a padded sheet.
    static let contentInset: CGFloat = 16
    /// Horizontal inset for collapsed ambient (clock / media / weather).
    static let ambientInset: CGFloat = 12
    /// Inner padding of the single widget card under the tab band.
    /// `NotchWidgetCard` (and only that view) reads this.
    static let widgetCardInset: CGFloat = 10
    /// Corner radius of the single widget card. Matches music-player tightness.
    static let widgetCardRadius: CGFloat = 16

    // MARK: Expanded chrome (must match NotchContentView measurements)
    /// Shared compact content-card height. Tray + this ≈ 200pt on a typical MacBook.
    static let expandedContentBase: CGFloat = 144
    /// Tab icons sit in the menu-bar / camera band (one row).
    static let chromeTray: CGFloat = 38
    /// Clock lives on the tray row so chrome stays one band. Kept at 0.
    static let chromeClock: CGFloat = 0
    /// Hairline under the camera band
    static let chromeDivider: CGFloat = 6
    /// Bottom padding under the content card — room for the large corner radii.
    static let chromeContentBottom: CGFloat = 12
    /// Total height added above a widget’s `expandedContentHeight`
    static var expandedChromeHeight: CGFloat {
        chromeTray + chromeClock + chromeDivider + chromeContentBottom
    }

    // MARK: Radii — Continuous curves (AppKit-friendly) with Dynamo jewel tightness
    static let radiusCollapsed: CGFloat = 12
    /// Large bottom corners so the hanging panel reads as a rounded pill.
    static let radiusExpanded: CGFloat = 28
    static let radiusCard: CGFloat = 14
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
    /// Expanded hang is a compact black panel, not a translucent sheet.
    static let panelScrimExpanded = Color.black.opacity(0.88)
    /// Fill of the single widget plate under the tab band.
    static let widgetCardFill = Color.white.opacity(0.045)
    /// Hairline on that plate — quiet, not a neon frame.
    static let widgetCardStroke = Color.white.opacity(0.10)
    /// Top-edge sheen inside the widget plate (static — no GPU pulse).
    static let widgetCardSheen = Color.white.opacity(0.10)
    /// Soft black hang depth. `NotchContentView` reads this for the expanded shadow.
    static let panelDepth = Color.black.opacity(0.46)
    static let panelDepthRadius: CGFloat = 22
    static let panelDepthY: CGFloat = 10
    /// Cool-white rim glow — crisp, not a cyan bloom.
    static let panelGlow = Color.white.opacity(0.16)
    static let panelGlowRadius: CGFloat = 10

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

    // MARK: Animation — buttery springs, short settles (cheap, no display-link)
    /// Island expand/collapse. Views and the window both read these numbers.
    static let expandResponse: Double = 0.28
    static let expandDamping: Double = 0.78
    static var expandSpring: Animation {
        .spring(response: expandResponse, dampingFraction: expandDamping, blendDuration: 0.08)
    }

    /// Content cross-fade / card swap.
    static let contentResponse: Double = 0.20
    static let contentDamping: Double = 0.84
    static var contentSpring: Animation {
        .spring(response: contentResponse, dampingFraction: contentDamping, blendDuration: 0.05)
    }

    /// Tab icon select / hover — slightly punchier than content.
    static let tabResponse: Double = 0.18
    static let tabDamping: Double = 0.72
    static var tabSpring: Animation {
        .spring(response: tabResponse, dampingFraction: tabDamping, blendDuration: 0.04)
    }

    static var snappy: Animation {
        .spring(response: 0.14, dampingFraction: 0.86)
    }

    static var quick: Animation {
        .easeOut(duration: 0.08)
    }

    /// Ambient rim pulse — slow so it costs almost no CPU.
    static var pulse: Animation {
        .easeInOut(duration: 2.6).repeatForever(autoreverses: true)
    }

    /// Match AppKit panel frame animation to the SwiftUI expand spring.
    static var panelExpandDuration: TimeInterval { expandResponse }
    /// Soft overshoot so the hang lands like an island, not a linear fade.
    static var panelExpandTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.18, 1.14, 0.24, 1.0)
    }

    // MARK: Helpers

    /// Bridge `NSColor` → SwiftUI `Color` for semantic system colors.
    static func system(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }
}
