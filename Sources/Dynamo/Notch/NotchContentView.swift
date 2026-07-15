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
            // Tray can overflow when many widgets are enabled — horizontal scroll bar.
            NotchScrollView(axes: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(registry.plugins, id: \.id) { plugin in
                        TrayIconButton(
                            systemImage: plugin.systemImage,
                            displayName: plugin.displayName,
                            isActive: registry.activePluginID == plugin.id
                        ) {
                            // Re-tap an already-active player widget → open Music/Spotify.
                            if registry.activePluginID == plugin.id,
                               let opener = plugin as? any PlayerAppOpening {
                                opener.openPlayerApp()
                            } else {
                                registry.activePluginID = plugin.id
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    TrayIconButton(
                        systemImage: "gearshape.fill",
                        displayName: "Settings",
                        isActive: false
                    ) {
                        NotificationCenter.default.post(name: .dynamoOpenSettings, object: nil)
                    }
                }
                .padding(.horizontal, NotchTheme.spaceMD)
            }
            .frame(height: 38)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if let active = registry.activePlugin {
                // Vertical scroll bar for widget content that exceeds the short expanded panel.
                NotchScrollView(axes: .vertical) {
                    active.expandedView()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, NotchTheme.spaceMD)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Tray-row control that works inside a nonactivating notch panel.
/// Uses an explicit tap gesture + large hit target so the first click fires.
private struct TrayIconButton: View {
    let systemImage: String
    let displayName: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(fillColor))
            .scaleEffect(isPressed ? 0.9 : 1.0)
            .contentShape(Rectangle().size(CGSize(width: 32, height: 32)))
            .onHover { isHovering = $0 }
            .onTapGesture {
                action()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
            .help(displayName)
            .animation(.easeOut(duration: 0.1), value: isHovering)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .accessibilityLabel(displayName)
            .accessibilityAddTraits(.isButton)
    }

    private var fillColor: Color {
        if isActive { return NotchTheme.chipFillActive }
        return isHovering ? NotchTheme.chipFill : .clear
    }
}

extension Notification.Name {
    static let dynamoOpenSettings = Notification.Name("dynamoOpenSettings")
}
