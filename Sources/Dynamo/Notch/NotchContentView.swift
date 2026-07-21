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
            glassBackground

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
                            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
                            removal: .opacity
                        )
                    )
            } else {
                collapsedBody
                    .transition(.opacity)
            }
        }
        .clipShape(NotchShape(cornerRadius: controller.isExpanded ? NotchTheme.radiusExpanded : NotchTheme.radiusCollapsed))
        .overlay {
            if !controller.isExpanded {
                AmbientBreathingRim(accent: ambientAccent)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: controller.isExpanded ? NotchTheme.shadowExpanded : ambientAccent.opacity(0.22),
            radius: controller.isExpanded ? NotchTheme.shadowRadius : 5,
            y: controller.isExpanded ? NotchTheme.shadowY : 0
        )
        .animation(NotchTheme.expandSpring, value: controller.isExpanded)
        .animation(NotchTheme.contentSpring, value: registry.activePluginID)
        .animation(NotchTheme.contentSpring, value: hud.state)
        .animation(NotchTheme.contentSpring, value: sneakPeek.peek)
        .animation(NotchTheme.contentSpring, value: registry.ambientRevision)
    }

    private var ambientAccent: Color {
        if let p = registry.activeAmbientProvider() {
            if p.ambientPriority >= 90 { return NotchTheme.mediaGlow }
            if p.ambientPriority >= 70 { return NotchTheme.caution.opacity(0.65) }
            if p.ambientPriority >= 40 { return NotchTheme.calmGlow }
        }
        return NotchTheme.calmGlow.opacity(0.5)
    }

    private var glassBackground: some View {
        VibrancyBackground(material: .hudWindow, blendingMode: .behindWindow)
            .overlay(controller.isExpanded ? NotchTheme.panelScrimExpanded : NotchTheme.panelScrim)
            .overlay(
                // Layered sheen — top highlight + faint bottom depth
                LinearGradient(
                    colors: [
                        Color.white.opacity(controller.isExpanded ? 0.10 : 0.05),
                        Color.clear,
                        Color.black.opacity(controller.isExpanded ? 0.12 : 0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
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
                            Color.white.opacity(controller.isExpanded ? 0.26 : 0.12),
                            Color.white.opacity(controller.isExpanded ? 0.06 : 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: controller.isExpanded ? 1 : 0.6
                )
            )
    }

    @ViewBuilder
    private var collapsedBody: some View {
        if let ambient = registry.activeAmbientProvider() {
            ambient.ambientView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AmbientClockView()
        }
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            // Tray row
            HStack(spacing: 4) {
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
            .padding(.top, 11)
            .padding(.bottom, 6)

            // Clock below tray (clear of notch camera)
            liveClockPill
                .padding(.bottom, 8)

            // Refined hairline
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            NotchTheme.separator,
                            NotchTheme.separator,
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.75)
                .padding(.horizontal, NotchTheme.spaceLG)
                .padding(.bottom, 10)

            if let active = registry.activePlugin {
                active.expandedView()
                    .id(active.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchTheme.spaceMD)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var liveClockPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Text(DynamoClock.dayString(from: context.date))
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .textCase(.uppercase)
                Text(DynamoClock.timeString(from: context.date))
                    .font(NotchTheme.ambientTime.monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(DynamoClock.periodString(from: context.date))
                    .font(NotchTheme.micro.weight(.medium))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(NotchTheme.chipFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.6
                            )
                    )
            )
        }
        .help("Local time")
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
        let isAmbient = (plugin as? any NotchAmbientProviding)?.isAmbientActive == true
        TrayIconButton(
            systemImage: plugin.systemImage,
            displayName: plugin.displayName,
            isActive: isActive,
            isLive: isAmbient
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
    var isLive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 12.5, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                    .symbolRenderingMode(.hierarchical)
                if isLive && !isActive {
                    Circle()
                        .fill(NotchTheme.positive)
                        .frame(width: 5, height: 5)
                        .shadow(color: NotchTheme.positive.opacity(0.7), radius: 2)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.notchIcon(diameter: 32, prominent: isActive))
        .help(displayName)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

extension Notification.Name {
    static let dynamoOpenSettings = Notification.Name("dynamoOpenSettings")
}
