import SwiftUI

/// Shared icon-button styling: circular hover + press scale for first-click
/// reliability on the nonactivating notch panel.
struct NotchIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 24
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
            .frame(minWidth: diameter + 4, minHeight: diameter + 4)
            .background(
                Circle()
                    .fill(fillColor)
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                prominent
                                    ? Color.white.opacity(0.16)
                                    : (isHovering ? Color.white.opacity(0.10) : Color.clear),
                                lineWidth: 0.6
                            )
                            .frame(width: diameter, height: diameter)
                    )
                    .shadow(
                        color: prominent ? Color.black.opacity(0.25) : .clear,
                        radius: prominent ? 4 : 0,
                        y: 1
                    )
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(NotchTheme.quick, value: configuration.isPressed)
            .animation(NotchTheme.quick, value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var fillColor: Color {
        if prominent { return NotchTheme.chipFillActive }
        return isHovering ? NotchTheme.chipFillHover : Color.white.opacity(0.001)
    }
}

extension ButtonStyle where Self == NotchIconButtonStyle {
    static var notchIcon: NotchIconButtonStyle { NotchIconButtonStyle() }

    static func notchIcon(diameter: CGFloat, prominent: Bool = false) -> NotchIconButtonStyle {
        NotchIconButtonStyle(diameter: diameter, prominent: prominent)
    }
}
