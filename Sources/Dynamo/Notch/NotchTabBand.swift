import CoreGraphics

/// Top-band metrics for the expanded hang: tab icons split around the camera.
///
/// `NotchContentView.expandedBody` calls `cameraGapWidth(panelWidth:)` for the
/// empty housing spacer. Tests hit the same function so the gap cannot drift
/// from the view.
enum NotchTabBand {
    static let cameraGapMin: CGFloat = 72
    static let cameraGapIdeal: CGFloat = 96
    static let cameraGapMax: CGFloat = 120

    /// Empty width reserved for the camera housing. Tracks the owner-target
    /// hang so the gap stays near the physical camera, then clamps so icons
    /// still have cheek room on narrower or wider panels.
    static func cameraGapWidth(panelWidth: CGFloat) -> CGFloat {
        let scale = cameraGapIdeal / NotchGeometry.expandedWidthFallback
        let raw = panelWidth * scale
        return min(cameraGapMax, max(cameraGapMin, raw.rounded()))
    }
}
