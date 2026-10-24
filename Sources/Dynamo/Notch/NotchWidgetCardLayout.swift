import CoreGraphics
import Foundation

/// Layout math the expanded widget card actually uses.
///
/// Media transport sizes go through `mediaMetrics(width:)`. Copy under the
/// title and the remaining-time label go through `mediaSubtitle` /
/// `remainingLabel` so the music card stays one tidy plate. Full-page
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

    /// Artist · album on one line — the spec card has no extra header chips.
    static func mediaSubtitle(artist: String, album: String) -> String {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty, !album.isEmpty { return "\(artist) · \(album)" }
        if !artist.isEmpty { return artist }
        return album
    }

    /// Right-hand time on the progress row: remaining, not total duration.
    static func remainingLabel(elapsed: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0.5, duration.isFinite else { return "--:--" }
        let left = max(0, duration - max(0, elapsed))
        return "-\(formatTime(left))"
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// True when a widget source pages full-width cards beside each other.
    /// `NotchHScroll` for chips / cities / files is allowed; a second panel
    /// page (`max(geo.size.width`) inside that scroller) is not.
    static func isFullPageCarousel(_ source: String) -> Bool {
        source.contains("NotchHScroll") && source.contains("max(geo.size.width")
    }

    /// Nested `NotchCard` plates inside a widget expanded view — a second
    /// card on the host `NotchWidgetCard`.
    static func hasNestedWidgetCard(_ source: String) -> Bool {
        source.contains("NotchCard {") || source.contains("NotchCard(")
    }
}
