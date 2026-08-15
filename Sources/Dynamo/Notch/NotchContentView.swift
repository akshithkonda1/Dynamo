import SwiftUI

/// Host view for the notch tray. Renders every registered plugin generically —
/// never branches on widget id/name.
struct NotchContentView: View {
    @ObservedObject var registry: WidgetRegistry
    @ObservedObject var controller: NotchWindowController
    @ObservedObject var hud: SystemHUDController
    @ObservedObject var sneakPeek: NotchSneakPeekController

    private var isShowingPeek: Bool {
        sneakPeek.peek != nil && !controller.isExpanded && hud.state == nil
    }

    private var isShowingOverlay: Bool {
        hud.state != nil || isShowingPeek
    }

    private var cornerRadius: CGFloat {
        if controller.isExpanded { return NotchTheme.radiusExpanded }
        // Peeks hang lower/wider — use expanded radius so the clip matches the drop.
        if isShowingOverlay { return NotchTheme.radiusExpanded }
        return NotchTheme.radiusCollapsed
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
        // Solid island: hard clip only — no soft-fade mask (that made the bottom ghosty).
        .compositingGroup()
        .clipShape(NotchShape(cornerRadius: cornerRadius))
        // No stroke. No expanded silhouette shadow. Clean continuous bottom lip.
        .overlay {
            if !controller.isExpanded && !isShowingOverlay {
                AmbientBreathingRim(accent: ambientAccent)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: controller.isExpanded
                ? Color.black.opacity(0.22)
                : (isShowingOverlay ? Color.black.opacity(0.22) : ambientAccent.opacity(0.08)),
            // Wide soft bloom — depth without a hard outlined bottom rim.
            radius: controller.isExpanded ? 20 : (isShowingOverlay ? 10 : 2),
            y: controller.isExpanded ? 6 : (isShowingOverlay ? 2 : 0)
        )
        .animation(NotchTheme.expandSpring, value: controller.isExpanded)
        .animation(NotchTheme.contentSpring, value: registry.activePluginID)
        .animation(NotchTheme.snappy, value: hud.state != nil)
        .animation(NotchTheme.snappy, value: sneakPeek.peek?.title)
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
        VibrancyBackground(
            material: glassMaterial,
            blendingMode: .behindWindow,
            forceDark: true
        )
        // Full solid scrim top → bottom (no fade-to-clear; that left a hollow lip).
        .overlay(controller.isExpanded ? NotchTheme.panelScrimExpanded : NotchTheme.panelScrim)
        .overlay(
            // Soft top sheen only — bottom stays solid glass.
            LinearGradient(
                colors: [
                    Color.white.opacity(controller.isExpanded ? 0.06 : 0.035),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        )
    }

    private var glassMaterial: NSVisualEffectView.Material {
        if isShowingOverlay { return NotchTheme.materialOverlay }
        if controller.isExpanded { return NotchTheme.materialExpanded }
        return NotchTheme.materialCollapsed
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
            // Tray — primary widgets left; Focus / Sports / utilities + Settings right.
            HStack(spacing: 3) {
                ForEach(leadingTrayPlugins, id: \.id) { plugin in
                    trayButton(for: plugin)
                }
                Spacer(minLength: 8)
                // Soft cluster divider: “daily widgets | focus & tools”
                Capsule()
                    .fill(NotchTheme.hairline.opacity(0.55))
                    .frame(width: 1, height: 18)
                    .accessibilityHidden(true)
                ForEach(trailingTrayPlugins, id: \.id) { plugin in
                    trayButton(for: plugin)
                }
                TrayIconButton(
                    systemImage: "gearshape.fill",
                    displayName: "Preferences",
                    shortLabel: nil,
                    isActive: false
                ) {
                    NotificationCenter.default.post(name: .dynamoOpenSettings, object: nil)
                }
            }
            .padding(.horizontal, NotchTheme.contentInset)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(height: NotchTheme.chromeTray)

            // Active widget name + live clock — makes the open tab obvious at a glance.
            HStack(spacing: 10) {
                if let active = registry.activePlugin {
                    Text(active.displayName)
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                liveClockPill
            }
            .padding(.horizontal, NotchTheme.contentInset)
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var liveClockPill: some View {
        Button {
            DynamoClockApp.open()
        } label: {
            // Minute-level refresh only (display is h:mm).
            TimelineView(.periodic(from: .now, by: 15)) { context in
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
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
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
        .help("Open Clock")
    }

    /// Right-side tray cluster (before Settings): Focus, Sports, Health, Shelf, Webcam.
    private static let trailingTrayIDs = ["focus", "sports", "system-health", "shelf", "webcam"]

    /// Compact tray labels — full `displayName` still used for help + a11y.
    private static let shortTrayLabels: [String: String] = [
        "media": "Media",
        "calendar": "Cal",
        "checklist": "Tasks",
        "clipboard": "Clip",
        "world-clock": "Clocks",
        "focus": "Focus",
        "sports": "Sports",
        "system-health": "Health",
        "shelf": "Shelf",
        "webcam": "Cam"
    ]

    private var leadingTrayPlugins: [any NotchWidgetPlugin] {
        let trailing = Set(Self.trailingTrayIDs)
        return registry.plugins.filter { !trailing.contains($0.id) }
    }

    private var trailingTrayPlugins: [any NotchWidgetPlugin] {
        Self.trailingTrayIDs.compactMap { id in
            registry.plugins.first { $0.id == id }
        }
    }

    @ViewBuilder
    private func trayButton(for plugin: any NotchWidgetPlugin) -> some View {
        let isActive = registry.activePlugin?.id == plugin.id
        let isAmbient = (plugin as? any NotchAmbientProviding)?.isAmbientActive == true
        TrayIconButton(
            systemImage: plugin.systemImage,
            displayName: plugin.displayName,
            shortLabel: isActive ? (Self.shortTrayLabels[plugin.id] ?? plugin.displayName) : nil,
            isActive: isActive,
            isLive: isAmbient
        ) {
            if isActive, let opener = plugin as? any PlayerAppOpening {
                opener.openPlayerApp()
            } else {
                withAnimation(NotchTheme.contentSpring) {
                    registry.activePluginID = plugin.id
                }
            }
        }
    }
}

/// Tray control: icon-only when idle; expands to icon + short label when selected
/// so the open tab is obvious without reading tooltips.
private struct TrayIconButton: View {
    let systemImage: String
    let displayName: String
    var shortLabel: String? = nil
    let isActive: Bool
    var isLive: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12.5, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive || isHovering ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                        .symbolRenderingMode(.hierarchical)
                    if isLive && !isActive {
                        Circle()
                            .fill(NotchTheme.positive)
                            .frame(width: 5, height: 5)
                            .shadow(color: NotchTheme.positive.opacity(0.7), radius: 2)
                            .offset(x: 2, y: -2)
                    }
                }
                if let shortLabel {
                    Text(shortLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.horizontal, shortLabel == nil ? 0 : 10)
            .frame(width: shortLabel == nil ? 32 : nil, height: 32)
            .frame(minWidth: 32, minHeight: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(strokeColor, lineWidth: 0.6)
                    )
                    .shadow(
                        color: isActive ? Color.black.opacity(0.22) : .clear,
                        radius: isActive ? 3 : 0,
                        y: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(NotchTheme.quick, value: isHovering)
        .animation(NotchTheme.snappy, value: isActive)
        .animation(NotchTheme.snappy, value: shortLabel)
        .help(displayName)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var fillColor: Color {
        if isActive { return NotchTheme.chipFillActive }
        return isHovering ? NotchTheme.chipFillHover : Color.white.opacity(0.001)
    }

    private var strokeColor: Color {
        if isActive { return NotchTheme.controlAccent.opacity(0.32) }
        return isHovering ? Color.white.opacity(0.12) : Color.clear
    }
}

extension Notification.Name {
    static let dynamoOpenSettings = Notification.Name("dynamoOpenSettings")
    /// Active Focus mode (or similar) changed preferred content height — resize expanded panel.
    static let dynamoFocusLayoutDidChange = Notification.Name("dynamoFocusLayoutDidChange")
}
