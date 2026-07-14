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

    /// A few points of overhang so the panel fully covers the cutout edges.
    private static let widthPadding: CGFloat = 4

    static func currentMetrics(for screen: NSScreen?) -> NotchMetrics {
        guard let screen else {
            return NotchMetrics(width: fallbackWidth, height: fallbackHeight)
        }
        let safeTop = screen.safeAreaInsets.top
        // On a notched display `safeAreaInsets.top` is the notch height; on a
        // plain display it's 0, so fall back to a slim menu-bar-height bar.
        let height = safeTop > 0 ? safeTop : fallbackHeight
        return NotchMetrics(width: notchWidth(for: screen), height: height)
    }

    private static func notchWidth(for screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let cutout = screen.frame.width - left.width - right.width
            if cutout > 0 {
                return cutout + widthPadding
            }
        }
        return fallbackWidth
    }
}
