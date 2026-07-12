import SwiftUI

/// Host view for the notch tray. Renders every registered plugin generically —
/// never branches on widget id/name.
struct NotchContentView: View {
    @ObservedObject var registry: WidgetRegistry
    @ObservedObject var controller: NotchWindowController
    @ObservedObject var hud: SystemHUDController

    var body: some View {
        ZStack(alignment: .top) {
            VibrancyBackground(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.28))

            if let hudState = hud.state {
                SystemHUDView(state: hudState)
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
                    let isActive = registry.activePluginID == plugin.id
                    Button {
                        registry.activePluginID = plugin.id
                    } label: {
                        Image(systemName: plugin.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(isActive ? NotchTheme.chipFillActive : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(plugin.displayName)
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
