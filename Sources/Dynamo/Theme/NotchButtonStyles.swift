import SwiftUI

/// Shared icon-button styling: a circular hover highlight + a small press
/// scale, so every widget's small utility buttons (delete, pin, reveal,
/// clear, copy, transport controls) feel and behave the same way instead of
/// each widget hand-rolling its own hover/press treatment — or, more often,
/// having none at all.
struct NotchIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 24
    /// A prominent button (e.g. the main play/pause) keeps a filled circle
    /// even when not hovered, rather than only appearing on hover.
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        NotchIconButtonBody(configuration: configuration, diameter: diameter, prominent: prominent)
    }
}

private struct NotchIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let prominent: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            // Slightly larger than the visual circle so first-clicks land.
            .frame(minWidth: diameter + 4, minHeight: diameter + 4)
            .background(Circle().fill(fillColor).frame(width: diameter, height: diameter))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var fillColor: Color {
        if prominent { return NotchTheme.chipFillActive }
        return isHovering ? NotchTheme.chipFillHover : .clear
    }
}

extension ButtonStyle where Self == NotchIconButtonStyle {
    static var notchIcon: NotchIconButtonStyle { NotchIconButtonStyle() }

    static func notchIcon(diameter: CGFloat, prominent: Bool = false) -> NotchIconButtonStyle {
        NotchIconButtonStyle(diameter: diameter, prominent: prominent)
    }
}
