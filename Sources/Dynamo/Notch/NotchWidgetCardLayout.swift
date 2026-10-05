import CoreGraphics

/// Layout math the expanded widget card actually uses.
///
/// Media transport sizes go through `mediaMetrics(width:)`. Full-page
/// carousels (a second card beside the first, each as wide as the panel)
/// are forbidden — one tab, one card.
enum NotchWidgetCardLayout {
    struct MediaMetrics: Equatable {
        var artSize: CGFloat
        var playDiameter: CGFloat
        var sideDiameter: CGFloat
        var auxDiameter: CGFloat
        var titleSize: CGFloat
    }

    /// Art + transport scale with the hanging card, not a second page.
    static func mediaMetrics(width: CGFloat) -> MediaMetrics {
        let wide = width >= NotchGeometry.expandedWidthFallback
        return MediaMetrics(
            artSize: wide ? 80 : 68,
            playDiameter: wide ? 42 : 38,
            sideDiameter: 32,
            auxDiameter: 28,
            titleSize: wide ? 17 : 16
        )
    }

    /// True when a widget source pages full-width cards beside each other.
    /// `NotchHScroll` for chips / cities / files is allowed; a second panel
    /// page (`max(geo.size.width`) inside that scroller) is not.
    static func isFullPageCarousel(_ source: String) -> Bool {
        source.contains("NotchHScroll") && source.contains("max(geo.size.width")
    }
}
