import AppKit

/// Physical-notch metrics used to size the collapsed panel so it disappears
/// into the real black notch cutout at rest — the same effect Boring Notch has.
///
/// The width is derived from the two menu-bar regions AppKit exposes on either
/// side of the camera housing (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`):
/// the cutout is whatever screen width those two regions don't cover. That's
/// far more accurate than a hardcoded per-model guess, and falls back to a
/// reasonable approximation on displays that don't report a notch.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
}

enum NotchGeometry {
    /// Fallback notch width when the display doesn't expose auxiliary top areas
    /// (e.g. no physical notch). ~185pt matches current MacBook cutouts.
    static let fallbackWidth: CGFloat = 185

    /// Collapsed height on displays without a physical notch (sits just under
    /// the menu bar rather than hugging a cutout that isn't there).
    static let fallbackHeight: CGFloat = 32

    /// Slight overhang so the panel covers the cutout edges without looking wide.
    private static let widthPadding: CGFloat = 2

    /// Minimal extra height for hover reliability without a bulky “bar” look.
    private static let interactionPadding: CGFloat = 4

    /// Scale the physical cutout width slightly so the collapsed notch reads tighter.
    private static let widthScale: CGFloat = 0.92

    /// Fallback cutout width after the same scale `currentMetrics` applies.
    static var fallbackNotchWidth: CGFloat { fallbackWidth * widthScale }

    /// Each Ambient cheek (album art / waveform). ~one menu-bar icon.
    static let ambientCheekWidth: CGFloat = 24

    /// Menu-bar height when no screen is available (tests + headless).
    static let menuBarHeightFallback: CGFloat = 24

    /// Pill size from independent notch + bar inputs: width = notch + 2 cheeks.
    static func ambientPillSize(notchWidth: CGFloat, menuBarHeight: CGFloat) -> NSSize {
        NSSize(width: notchWidth + (2 * ambientCheekWidth), height: menuBarHeight)
    }

    /// Testable pill size for typical MacBook aspects. The physical notch and
    /// menu bar do not scale with aspect, so 16:10 and 3:2 share the fallback.
    static func ambientPillSize(screenWidth _: CGFloat, screenHeight _: CGFloat) -> NSSize {
        ambientPillSize(notchWidth: fallbackNotchWidth, menuBarHeight: menuBarHeightFallback)
    }

    static func ambientPillSize(for screen: NSScreen?) -> NSSize {
        guard let screen else {
            return ambientPillSize(notchWidth: fallbackNotchWidth, menuBarHeight: menuBarHeightFallback)
        }
        let reported = screen.frame.maxY - screen.visibleFrame.maxY
        let safe = screen.safeAreaInsets.top
        let menuBar: CGFloat
        if reported > 0 {
            menuBar = reported
        } else if safe > 0 {
            menuBar = safe
        } else {
            menuBar = menuBarHeightFallback
        }
        return ambientPillSize(notchWidth: notchWidth(for: screen), menuBarHeight: menuBar)
    }

    /// Collapsed island size. Ambient pill only when the setting is on **and**
    /// media is playing; otherwise the normal closed notch (no layout jump when
    /// Ambient is on but nothing is playing).
    static func collapsedSize(ambientEnabled: Bool, isPlaying: Bool, screen: NSScreen?) -> NSSize {
        if AmbientMode.showsPill(ambientEnabled: ambientEnabled, isPlaying: isPlaying) {
            return ambientPillSize(for: screen)
        }
        let metrics = currentMetrics(for: screen)
        return NSSize(width: metrics.width, height: metrics.height)
    }

    static func currentMetrics(for screen: NSScreen?) -> NotchMetrics {
        guard let screen else {
            return NotchMetrics(
                width: fallbackWidth * widthScale,
                height: fallbackHeight + interactionPadding
            )
        }
        let safeTop = screen.safeAreaInsets.top
        // On a notched display `safeAreaInsets.top` is the notch height; on a
        // plain display it's 0, so fall back to a slim menu-bar-height bar.
        let base = safeTop > 0 ? safeTop : fallbackHeight
        let height = base + interactionPadding
        return NotchMetrics(width: notchWidth(for: screen), height: height)
    }

    private static func notchWidth(for screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let cutout = screen.frame.width - left.width - right.width
            if cutout > 0 {
                return (cutout + widthPadding) * widthScale
            }
        }
        return fallbackWidth * widthScale
    }

    // MARK: - Aspect-adaptive expanded panel

    /// Nil-screen fallback — owner target ~555pt hanging card.
    static let expandedWidthFallback: CGFloat = 555
    /// Floor covers 13″ laptops.
    static let expandedWidthFloor: CGFloat = 480
    /// Cap keeps large externals from growing a banner.
    static let expandedWidthCap: CGFloat = 680
    /// Chrome + content must stay a compact hanging card (NotchDock density).
    static let expandedPanelHeightCap: CGFloat = 230
    /// Owner target: tray + one widget card ≈ 200pt.
    static let expandedPanelHeightTarget: CGFloat = 200

    /// Compact hanging panel: ~38% of a typical MacBook width (~555pt on a
    /// 1470pt display) and short — a tidy card under the camera, not a wide
    /// wing bar and not a tall tray.
    static func expandedWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return expandedWidthFallback }
        return expandedWidth(screenWidth: screen.frame.width, screenHeight: screen.frame.height)
    }

    /// Full expanded panel size. `NotchWindowController.expandedSize` calls this
    /// — do not re-derive width/height at the window.
    static func expandedPanelSize(contentBase: CGFloat, for screen: NSScreen?) -> NSSize {
        guard let screen else {
            return NSSize(
                width: expandedWidthFallback,
                height: contentBase + NotchTheme.expandedChromeHeight
            )
        }
        return expandedPanelSize(
            contentBase: contentBase,
            screenWidth: screen.frame.width,
            screenHeight: screen.frame.height
        )
    }

    /// Testable panel size from display points (no `NSScreen` required).
    static func expandedPanelSize(contentBase: CGFloat, screenWidth: CGFloat, screenHeight: CGFloat) -> NSSize {
        NSSize(
            width: expandedWidth(screenWidth: screenWidth, screenHeight: screenHeight),
            height: expandedPanelHeight(contentBase: contentBase, screenHeight: screenHeight)
        )
    }

    /// Testable width from display points (no `NSScreen` required).
    static func expandedWidth(screenWidth w: CGFloat, screenHeight h: CGFloat) -> CGFloat {
        let aspect = w / max(h, 1)
        let fraction: CGFloat
        if aspect >= 2.0 {          // ultrawide — keep the card compact
            fraction = 0.22
        } else if aspect >= 1.6 {   // 16:10 and 16:9
            fraction = 0.38
        } else if aspect >= 1.45 {  // 3:2 MacBook
            fraction = 0.38
        } else {                    // nearer square / portrait external
            fraction = 0.42
        }
        let raw = w * fraction
        return min(expandedWidthCap, max(expandedWidthFloor, raw.rounded()))
    }

    /// Keep the content card short. Never grow taller than the plugin’s
    /// compact base — extra display size is unused, not extra height.
    static func expandedContentHeight(base: CGFloat, for screen: NSScreen?) -> CGFloat {
        guard let screen else { return base }
        return expandedContentHeight(base: base, screenHeight: screen.frame.height)
    }

    /// Testable content height from display points (no `NSScreen` required).
    static func expandedContentHeight(base: CGFloat, screenHeight h: CGFloat) -> CGFloat {
        let scale = min(1.0, max(0.90, h / 980))
        return (base * scale).rounded()
    }

    /// Full expanded panel height: widget card + tray chrome.
    static func expandedPanelHeight(contentBase: CGFloat, screenHeight: CGFloat) -> CGFloat {
        expandedContentHeight(base: contentBase, screenHeight: screenHeight)
            + NotchTheme.expandedChromeHeight
    }

    /// Peek silhouette grows modestly from the physical cutout — Dynamic Island
    /// style, not a wide notification toast. Width flares just enough for
    /// icon + title; height is camera band + one compact content row.
    static func peekOverlaySize(for screen: NSScreen?) -> NSSize {
        let metrics = currentMetrics(for: screen)
        // ~1.85× cutout + small padding → readable without looking banner-wide.
        let width = min(440, max(metrics.width * 1.85 + 32, 276)).rounded()
        let top = peekContentTopInset(for: screen)
        // Content row ~48pt (icon 32 + padding) + soft bottom lip.
        let height = max(72, (top + 48).rounded())
        return NSSize(width: width, height: height)
    }

    /// Vertical inset so peek text/icons clear the camera housing.
    /// Matches the physical notch band closely so the black glass fills the
    /// cutout continuously — useful space without a large empty void.
    static func peekContentTopInset(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 12 }
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            // Sit just under the housing (1–3pt tuck keeps island joined to cutout).
            return max(16, min(34, safeTop - 2))
        }
        // Non-notched displays: slim menu-bar clearance.
        return 10
    }

    static func hudOverlaySize(for screen: NSScreen?) -> NSSize {
        // HUD stays tighter than peeks — volume/brightness only need a slim bar
        // under the camera band.
        let metrics = currentMetrics(for: screen)
        let w = min(340, max(metrics.width * 1.55 + 24, 240)).rounded()
        let top = peekContentTopInset(for: screen)
        // Camera band + meter row (~24pt) + bottom lip.
        let h = max(50, (top + 26).rounded())
        return NSSize(width: w, height: h)
    }
}
