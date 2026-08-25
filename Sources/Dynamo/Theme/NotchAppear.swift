import SwiftUI

/// Shared appear polish for expanded widget pages — light rise + fade.
/// Honors Reduce Motion (instant / short easeOut, no spring).
struct NotchAppear: ViewModifier {
    var delay: Double = 0
    var rise: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : rise)
            .onAppear {
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.1)) { appeared = true }
                    return
                }
                withAnimation(NotchTheme.contentSpring.delay(delay)) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// Fade + slight rise when the view appears (tab content, cards, rows).
    func notchAppear(delay: Double = 0, rise: CGFloat = 6) -> some View {
        modifier(NotchAppear(delay: delay, rise: rise))
    }
}
