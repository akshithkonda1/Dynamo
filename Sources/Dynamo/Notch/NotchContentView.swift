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
        .overlay {
            if !controller.isExpanded {
                // Living rim when collapsed — Dynamic Island “awake” pulse.
                AmbientBreathingRim(accent: ambientAccent)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: controller.isExpanded ? NotchTheme.shadowExpanded : ambientAccent.opacity(0.25),
            radius: controller.isExpanded ? NotchTheme.shadowRadius : 6,
            y: controller.isExpanded ? NotchTheme.shadowY : 0
        )
        .animation(NotchTheme.expandSpring, value: controller.isExpanded)
        .animation(NotchTheme.contentSpring, value: registry.activePluginID)
        .animation(NotchTheme.contentSpring, value: hud.state)
        .animation(NotchTheme.contentSpring, value: sneakPeek.peek)
        .animation(NotchTheme.contentSpring, value: registry.ambientRevision)
    }

    private var ambientAccent: Color {
        // Higher priority ambient → cooler brand glow; idle clock → calm blue.
        if let p = registry.activeAmbientProvider() {
            if p.ambientPriority >= 90 { return NotchTheme.mediaGlow }
            if p.ambientPriority >= 70 { return NotchTheme.caution.opacity(0.7) }
            if p.ambientPriority >= 40 { return NotchTheme.calmGlow }
        }
        return NotchTheme.calmGlow.opacity(0.55)
    }

    private var glassBackground: some View {
        VibrancyBackground(material: .hudWindow, blendingMode: .behindWindow)
            .overlay(controller.isExpanded ? NotchTheme.panelScrimExpanded : NotchTheme.panelScrim)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(controller.isExpanded ? 0.08 : 0.04),
                        Color.clear,
                        NotchTheme.mediaGlow.opacity(controller.isExpanded ? 0.04 : 0)
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
                            Color.white.opacity(controller.isExpanded ? 0.22 : 0.10),
                            Color.white.opacity(controller.isExpanded ? 0.06 : 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: controller.isExpanded ? 1 : 0.5
                )
            )
    }

    @ViewBuilder
    private var collapsedBody: some View {
        if let ambient = registry.activeAmbientProvider() {
            ambient.ambientView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Always-alive Dynamic Island: elegant live clock when idle.
            AmbientClockView()
        }
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            // Top chrome: tray icons, then quick actions + clock (lower row)
            VStack(spacing: 8) {
                HStack(spacing: 5) {
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

                // Secondary row: clock only (media transport lives in the Media tab)
                HStack {
                    Spacer(minLength: 0)
                    liveClockPill
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, NotchTheme.spaceMD)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.separator, NotchTheme.separator.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, NotchTheme.spaceMD)
                .padding(.bottom, 8)

            if let active = registry.activePlugin {
                active.expandedView()
                    .id(active.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchTheme.spaceMD)
                    .padding(.bottom, 14)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var liveClockPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Text(DynamoClock.timeString(from: context.date))
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(NotchTheme.chipFill)
                    .overlay(Capsule().strokeBorder(NotchTheme.hairline.opacity(0.5), lineWidth: 0.5))
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
                    .font(.system(size: 12, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                    .symbolRenderingMode(.hierarchical)
                if isLive && !isActive {
                    Circle()
                        .fill(NotchTheme.positive)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
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
