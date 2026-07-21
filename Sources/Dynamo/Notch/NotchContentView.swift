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
            HStack(spacing: 8) {
                // Main tray icons (Shelf + Webcam are pinned next to Settings).
                ForEach(leadingTrayPlugins, id: \.id) { plugin in
                    trayButton(for: plugin)
                }
                Spacer(minLength: 0)
                // Fixed trailing cluster: Shelf · Webcam · Settings.
                if let shelf = shelfPlugin {
                    trayButton(for: shelf)
                }
                if let webcam = webcamPlugin {
                    trayButton(for: webcam)
                }
                TrayIconButton(
                    systemImage: "gearshape.fill",
                    displayName: "Settings",
                    isActive: false
                ) {
                    NotificationCenter.default.post(name: .dynamoOpenSettings, object: nil)
                }
            }
            .padding(.horizontal, NotchTheme.spaceMD)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let active = registry.activePlugin {
                active.expandedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchTheme.spaceMD)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Plugins drawn in normal order — excludes trailing-pinned Shelf + Webcam.
    private var leadingTrayPlugins: [any NotchWidgetPlugin] {
        registry.plugins.filter { $0.id != "webcam" && $0.id != "shelf" }
    }

    private var shelfPlugin: (any NotchWidgetPlugin)? {
        registry.plugins.first { $0.id == "shelf" }
    }

    private var webcamPlugin: (any NotchWidgetPlugin)? {
        registry.plugins.first { $0.id == "webcam" }
    }

    @ViewBuilder
    private func trayButton(for plugin: any NotchWidgetPlugin) -> some View {
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
}

/// Tray-row control that works inside a nonactivating notch panel.
/// Uses a real `Button` (not Image + onTapGesture, which — same as the
/// transport row in MediaControlsPlugin — often eats the first click on a
/// nonactivating panel) and the shared `.notchIcon` hover/press style.
private struct TrayIconButton: View {
    let systemImage: String
    let displayName: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
        }
        .buttonStyle(.notchIcon(diameter: 26, prominent: isActive))
        .help(displayName)
        .accessibilityLabel(displayName)
    }
}

extension Notification.Name {
    static let dynamoOpenSettings = Notification.Name("dynamoOpenSettings")
}
