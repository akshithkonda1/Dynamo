import SwiftUI

/// Tray icon button — native hover/press response with Dynamo circular chrome.
/// Sized for reliable first-click on a nonactivating `NSPanel`.
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
                            .strokeBorder(strokeColor, lineWidth: 0.6)
                            .frame(width: diameter, height: diameter)
                    )
                    .shadow(
                        color: prominent ? Color.black.opacity(0.22) : .clear,
                        radius: prominent ? 3 : 0,
                        y: 1
                    )
            )
            .contentShape(Rectangle())
            // Subtle press — closer to AppKit toolbar buttons than a hard scale.
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(NotchTheme.quick, value: configuration.isPressed)
            .animation(NotchTheme.quick, value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var fillColor: Color {
        if prominent { return NotchTheme.chipFillActive }
        return isHovering ? NotchTheme.chipFillHover : Color.white.opacity(0.001)
    }

    private var strokeColor: Color {
        if prominent {
            return NotchTheme.controlAccent.opacity(0.28)
        }
        return isHovering ? Color.white.opacity(0.12) : Color.clear
    }
}

extension ButtonStyle where Self == NotchIconButtonStyle {
    static var notchIcon: NotchIconButtonStyle { NotchIconButtonStyle() }

    static func notchIcon(diameter: CGFloat, prominent: Bool = false) -> NotchIconButtonStyle {
        NotchIconButtonStyle(diameter: diameter, prominent: prominent)
    }
}
