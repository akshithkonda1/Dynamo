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
            // Premium glass: vibrancy + strong scrim so desktop never bleeds through as UI.
            VibrancyBackground(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(controller.isExpanded ? NotchTheme.panelScrimExpanded : NotchTheme.panelScrim)
                .overlay(
                    // Soft top highlight for depth.
                    LinearGradient(
                        colors: [
                            Color.white.opacity(controller.isExpanded ? 0.07 : 0.03),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: controller.isExpanded ? NotchTheme.radiusExpanded : NotchTheme.radiusCollapsed,
                        style: .continuous
                    )
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(controller.isExpanded ? 0.18 : 0.06),
                                Color.white.opacity(controller.isExpanded ? 0.06 : 0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: controller.isExpanded ? 1 : 0
                    )
                )

            if let hudState = hud.state {
                SystemHUDView(state: hudState)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if let peek = sneakPeek.peek, !controller.isExpanded {
                NotchSneakPeekView(peek: peek)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if controller.isExpanded {
                expandedBody
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal: .opacity
                        )
                    )
            } else {
                collapsedBody
                    .transition(.opacity)
            }
        }
        .clipShape(NotchShape(cornerRadius: controller.isExpanded ? NotchTheme.radiusExpanded : NotchTheme.radiusCollapsed))
        .shadow(
            color: controller.isExpanded ? NotchTheme.shadowExpanded : .clear,
            radius: controller.isExpanded ? NotchTheme.shadowRadius : 0,
            y: controller.isExpanded ? NotchTheme.shadowY : 0
        )
        .animation(NotchTheme.expandSpring, value: controller.isExpanded)
        .animation(NotchTheme.contentSpring, value: registry.activePluginID)
        .animation(NotchTheme.contentSpring, value: hud.state)
        .animation(NotchTheme.contentSpring, value: sneakPeek.peek)
    }

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
            // Tray chrome
            HStack(spacing: 6) {
                ForEach(leadingTrayPlugins, id: \.id) { plugin in
                    trayButton(for: plugin)
                }
                Spacer(minLength: 0)
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
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Hairline under tray — separates chrome from content.
            Rectangle()
                .fill(NotchTheme.separator)
                .frame(height: 1)
                .padding(.horizontal, NotchTheme.spaceMD)
                .padding(.bottom, 8)

            if let active = registry.activePlugin {
                active.expandedView()
                    // Identity by plugin so SwiftUI doesn't morph unrelated layouts
                    // (Clipboard pins used to reflow under media geometry).
                    .id(active.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchTheme.spaceMD)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

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
        let isActive = registry.activePlugin?.id == plugin.id
        TrayIconButton(
            systemImage: plugin.systemImage,
            displayName: plugin.displayName,
            isActive: isActive
        ) {
            if isActive, let opener = plugin as? any PlayerAppOpening {
                opener.openPlayerApp()
            } else {
                registry.activePluginID = plugin.id
            }
        }
    }
}

private struct TrayIconButton: View {
    let systemImage: String
    let displayName: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: isActive ? .bold : .semibold))
                .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.notchIcon(diameter: 30, prominent: isActive))
        .help(displayName)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

extension Notification.Name {
    static let dynamoOpenSettings = Notification.Name("dynamoOpenSettings")
}
