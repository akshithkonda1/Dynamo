import SwiftUI

/// Host view for the notch tray. Renders every registered plugin generically —
/// never branches on widget id/name.
struct NotchContentView: View {
    @ObservedObject var registry: WidgetRegistry
    @ObservedObject var controller: NotchWindowController
    @ObservedObject var hud: SystemHUDController
    @ObservedObject var sneakPeek: NotchSneakPeekController

    var body: some View {
        ZStack(alignment: .top) {
            VibrancyBackground(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.28))

            if let hudState = hud.state {
                SystemHUDView(state: hudState)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if let peek = sneakPeek.peek, !controller.isExpanded {
                // Only peek while collapsed — if the panel's already expanded
                // the user is already looking at it, no need for a pill.
                NotchSneakPeekView(peek: peek)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if controller.isExpanded {
                expandedBody
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity
                        )
                    )
            } else {
                collapsedBody
                    .transition(.opacity)
            }
        }
        .clipShape(NotchShape(cornerRadius: controller.isExpanded ? NotchTheme.radiusExpanded : NotchTheme.radiusCollapsed))
        .animation(NotchTheme.expandSpring, value: controller.isExpanded)
        .animation(NotchTheme.contentSpring, value: registry.activePluginID)
        .animation(NotchTheme.contentSpring, value: hud.state)
        .animation(NotchTheme.contentSpring, value: sneakPeek.peek)
    }

    // The collapsed panel is sized to the physical notch (see `NotchGeometry`).
    // When a widget has ambient content to show (e.g. media playing → album art
    // + visualizer either side of the camera), render it; otherwise stay empty
    // so the shape disappears into the real black cutout. The widget tray lives
    // in the expanded state, revealed on hover.
    @ViewBuilder
    private var collapsedBody: some View {
        if let ambient = registry.activeAmbientProvider() {
            ambient.ambientView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: NotchTheme.spaceMD) {
                ForEach(registry.plugins, id: \.id) { plugin in
                    TrayIconButton(
                        systemImage: plugin.systemImage,
                        displayName: plugin.displayName,
                        isActive: registry.activePluginID == plugin.id
                    ) {
                        registry.activePluginID = plugin.id
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NotchTheme.spaceLG)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let active = registry.activePlugin {
                active.expandedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchTheme.spaceLG)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A tray-row widget selector icon. Filled while active (selected); on top of
/// that, a hover highlight previews the icon before you click it, so the row
/// feels responsive rather than only reacting after the fact.
private struct TrayIconButton: View {
    let systemImage: String
    let displayName: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(fillColor))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(displayName)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fillColor: Color {
        if isActive { return NotchTheme.chipFillActive }
        return isHovering ? NotchTheme.chipFill : .clear
    }
}
