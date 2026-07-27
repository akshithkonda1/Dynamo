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

    /// Expanded island width from screen size + aspect ratio (not a fixed 660pt).
    /// Ultrawide: narrower fraction so the island stays island-like.
    /// Compact / more-square: wider fraction for usability.
    static func expandedWidth(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 660 }
        let w = screen.frame.width
        let h = max(screen.frame.height, 1)
        let aspect = w / h
        let fraction: CGFloat
        if aspect >= 2.0 {          // ultrawide
            fraction = 0.26
        } else if aspect >= 1.7 {   // 16:9–16:10 laptop
            fraction = 0.34
        } else if aspect >= 1.45 {  // 3:2
            fraction = 0.40
        } else {                    // nearer square / portrait external
            fraction = 0.48
        }
        let raw = w * fraction
        return min(820, max(440, raw.rounded()))
    }

    /// Scale widget content height with display height so tall screens get more room.
    static func expandedContentHeight(base: CGFloat, for screen: NSScreen?) -> CGFloat {
        guard let screen else { return base }
        let h = screen.frame.height
        // ~900pt tall MBP is baseline 1.0; clamp so small displays don't crush UI.
        let scale = min(1.28, max(0.92, h / 900))
        return (base * scale).rounded()
    }

    /// Peek / HUD overlay width tracks expanded width lightly.
    static func peekOverlaySize(for screen: NSScreen?) -> NSSize {
        let w = min(520, max(360, expandedWidth(for: screen) * 0.64))
        return NSSize(width: w.rounded(), height: 98)
    }

    static func hudOverlaySize(for screen: NSScreen?) -> NSSize {
        let w = min(380, max(280, expandedWidth(for: screen) * 0.48))
        return NSSize(width: w.rounded(), height: 48)
    }
}
