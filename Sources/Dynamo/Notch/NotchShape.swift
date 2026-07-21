import SwiftUI

/// MacBook-style island silhouette used as the panel mask **and** border.
/// Animatable corner radius keeps expand/collapse from “snapping” the outline.
struct NotchShape: InsettableShape {
    var cornerRadius: CGFloat = 12
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        // Continuous bottom corners (not sharp quad “kinks”) so the lower lip
        // sits flush with the glass instead of reading as a separate border.
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        return Path(
            roundedRect: rect,
            // Top is flush with the menu bar / camera housing — square top.
            // Bottom is fully rounded (Dynamic Island hang).
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: r,
                bottomTrailing: r,
                topTrailing: 0
            ),
            style: .continuous
        )
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
