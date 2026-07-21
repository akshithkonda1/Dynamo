import SwiftUI

/// Host view for the notch tray. Renders every registered plugin generically —
/// never branches on widget id/name.
struct NotchContentView: View {
    @ObservedObject var registry: WidgetRegistry
    @ObservedObject var controller: NotchWindowController
    @ObservedObject var hud: SystemHUDController
    @ObservedObject var sneakPeek: NotchSneakPeekController

    private var cornerRadius: CGFloat {
        controller.isExpanded ? NotchTheme.radiusExpanded : NotchTheme.radiusCollapsed
    }

    var body: some View {
        ZStack(alignment: .top) {
            glassBackground

            Group {
                if let hudState = hud.state {
                    SystemHUDView(state: hudState)
                } else if let peek = sneakPeek.peek, !controller.isExpanded {
                    NotchSneakPeekView(peek: peek)
                } else if controller.isExpanded {
                    expandedBody
                } else {
                    collapsedBody
                }
            }
            .transition(.opacity)
        }
        .clipShape(NotchShape(cornerRadius: cornerRadius))
        // Border uses the *same* shape as the clip — RoundedRectangle was misaligned.
        .overlay(
            NotchShape(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(controller.isExpanded ? 0.24 : 0.10),
                            Color.white.opacity(controller.isExpanded ? 0.06 : 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: controller.isExpanded ? 1 : 0.6
                )
                .allowsHitTesting(false)
        )
        .overlay {
            if !controller.isExpanded {
                AmbientBreathingRim(accent: ambientAccent)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: controller.isExpanded ? NotchTheme.shadowExpanded : ambientAccent.opacity(0.20),
            radius: controller.isExpanded ? NotchTheme.shadowRadius : 5,
            y: controller.isExpanded ? NotchTheme.shadowY : 0
        )
        // Only animate structural state — not ambient ticks (that caused jank).
        .animation(NotchTheme.expandSpring, value: controller.isExpanded)
        .animation(NotchTheme.contentSpring, value: registry.activePluginID)
        .animation(NotchTheme.quick, value: hud.state != nil)
        .animation(NotchTheme.quick, value: sneakPeek.peek?.title)
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
                LinearGradient(
                    colors: [
                        Color.white.opacity(controller.isExpanded ? 0.09 : 0.045),
                        Color.clear,
                        Color.black.opacity(controller.isExpanded ? 0.10 : 0.05)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
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
            // Tray
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
            .padding(.horizontal, NotchTheme.contentInset)
            .padding(.top, 11)
            .padding(.bottom, 6)
            .frame(height: NotchTheme.chromeTray)

            // Clock under tray
            liveClockPill
                .frame(height: NotchTheme.chromeClock)

            // Hairline (fixed chrome slot)
            VStack(spacing: 0) {
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
                Spacer(minLength: 0)
            }
            .frame(height: NotchTheme.chromeDivider)

            if let active = registry.activePlugin {
                active.expandedView()
                    .id(active.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, NotchTheme.contentInset)
                    .padding(.bottom, NotchTheme.chromeContentBottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var liveClockPill: some View {
        Button {
            DynamoClockApp.open()
        } label: {
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
                                .strokeBorder(NotchTheme.hairline.opacity(0.55), lineWidth: 0.5)
                        )
                )
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help("Open Clock")
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
