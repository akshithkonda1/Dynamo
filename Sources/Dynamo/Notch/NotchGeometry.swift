import AppKit

/// Physical-notch metrics used to size the collapsed panel so it disappears
/// into the real black notch cutout at rest — the same effect Boring Notch has.
///
/// Apple publishes no official notch spec and the width varies slightly by
/// MacBook model, so the width is a tuned approximation (reference: 2026
/// MacBook Air). Height is read from the screen's `safeAreaInsets.top` when a
/// physical notch is present. **The width is meant to be eyeballed on the real
/// display** — get it visually close on your own machine; pixel-perfect across
/// every model isn't solvable from the outside.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
}

enum NotchGeometry {
    /// Approximate notch width in points. Tune this against the physical notch
    /// on your machine. Reference: 2026 MacBook Air.
    static let approximateNotchWidth: CGFloat = 200

    /// Collapsed height on displays without a physical notch (sits just under
    /// the menu bar rather than hugging a cutout that isn't there).
    static let fallbackHeight: CGFloat = 32

    static func currentMetrics(for screen: NSScreen?) -> NotchMetrics {
        guard let screen else {
            return NotchMetrics(width: approximateNotchWidth, height: fallbackHeight)
        }
        let safeTop = screen.safeAreaInsets.top
        // On a notched display `safeAreaInsets.top` is the notch height; on a
        // plain display it's 0, so fall back to a slim menu-bar-height bar.
        let height = safeTop > 0 ? safeTop : fallbackHeight
        return NotchMetrics(width: approximateNotchWidth, height: height)
    }
}
