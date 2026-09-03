import AppKit
import SwiftUI

/// Preferences window (NSWindow, not a notch panel), opened from the menu bar.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let registry: WidgetRegistry
    private let notch: NotchWindowController

    init(registry: WidgetRegistry, notch: NotchWindowController) {
        self.registry = registry
        self.notch = notch
        super.init()
    }

    func show() {
        if window == nil {
            let root = SettingsView(registry: registry, notch: notch)
            let hosting = NSHostingController(rootView: root)
            // Standard macOS preferences window — titled, translucent titlebar.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Preferences"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            // Dark glass prefs — matches notch neon identity.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DynamoPreferencesWindow")
            window.setContentSize(NSSize(width: 800, height: 840))
            window.minSize = NSSize(width: 700, height: 580)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI

struct SettingsView: View {
    @ObservedObject var registry: WidgetRegistry
    @ObservedObject var notch: NotchWindowController
    @ObservedObject private var permissions = PermissionsStore.shared
    @ObservedObject private var units = MeasurementUnitsStore.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchStatus = LaunchAtLogin.statusDescription
    @AppStorage("peekDwellMultiplier") private var peekDwellMultiplier: Double = 1.0
    @ObservedObject private var amplify = MediaAmplifyController.shared
    @ObservedObject private var mirror = SystemNotificationMirror.shared
    @State private var selectedPane: SettingsPane = .general

    private enum SettingsPane: Hashable, Identifiable {
        case general, widgets, notifications, permissions, about
        case widget(String)

        var id: String {
            switch self {
            case .general: return "general"
            case .widgets: return "widgets"
            case .notifications: return "notifications"
            case .permissions: return "permissions"
            case .about: return "about"
            case .widget(let id): return "widget:\(id)"
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .widgets: return "Widgets"
            case .notifications: return "Notifications"
            case .permissions: return "Permissions"
            case .about: return "About"
            case .widget: return "Widget"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .widgets: return "square.grid.2x2"
            case .notifications: return "bell.badge"
            case .permissions: return "lock.shield"
            case .about: return "info.circle"
            case .widget: return "slider.horizontal.3"
            }
        }
    }

    private var widgetPanes: [(id: String, name: String, view: AnyView)] {
        registry.settingsSections()
    }

    var body: some View {
        // Custom split (not NavigationSplitView) so sidebar + detail share one dark glass system.
        ZStack {
            PreferencesGlassBackground(intensity: 1.0)
            HStack(spacing: 0) {
                prefsSidebar
                    .frame(width: 220)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                NotchTheme.neonCyan.opacity(0.25),
                                Color.white.opacity(0.06),
                                NotchTheme.neonViolet.opacity(0.18)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        prefsDetailHero
                        detailContent
                            .id(selectedPane.id)
                            .notchAppear(delay: 0.03, rise: 6)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 580)
        .preferredColorScheme(.dark)
        .tint(NotchTheme.neonCyan)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchStatus = LaunchAtLogin.statusDescription
            PermissionsStore.shared.refreshFromSystem()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dynamoWidgetConfigurationDidChange)) { _ in
            WidgetSettingsStore.shared.persist(from: registry)
        }
    }

    private var prefsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [NotchTheme.neonCyan, NotchTheme.neonViolet],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 10, height: 10)
                    .shadow(color: NotchTheme.neonCyan.opacity(0.5), radius: 4, y: 0)
                Text("DYNAMO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    prefsSidebarGroup("Start here") {
                        prefsSidebarButton("General", systemImage: "gearshape", pane: .general)
                        prefsSidebarButton("Tray widgets", systemImage: "square.grid.2x2", pane: .widgets)
                        prefsSidebarButton("Peek & Hub", systemImage: "bell.badge", pane: .notifications)
                    }
                    prefsSidebarGroup("Customize") {
                        ForEach(widgetPanes, id: \.id) { section in
                            prefsSidebarButton(
                                section.name,
                                systemImage: iconForWidget(id: section.id),
                                pane: .widget(section.id)
                            )
                        }
                    }
                    prefsSidebarGroup("Mac access") {
                        prefsSidebarButton("Permissions", systemImage: "lock.shield", pane: .permissions)
                        prefsSidebarButton("About", systemImage: "info.circle", pane: .about)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(Color.black.opacity(0.18))
    }

    private func prefsSidebarGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(NotchTheme.neonCyan.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            content()
        }
    }

    private func prefsSidebarButton(_ title: String, systemImage: String, pane: SettingsPane) -> some View {
        let selected = selectedPane == pane
        return Button {
            withAnimation(NotchTheme.snappy) { selectedPane = pane }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? NotchTheme.neonCyan : .white.opacity(0.45))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(selected ? .white.opacity(0.95) : .white.opacity(0.62))
                Spacer(minLength: 0)
                if selected {
                    Circle()
                        .fill(NotchTheme.neonCyan)
                        .frame(width: 5, height: 5)
                        .shadow(color: NotchTheme.neonCyan.opacity(0.6), radius: 3, y: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.08) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                selected
                                    ? NotchTheme.neonCyan.opacity(0.35)
                                    : Color.clear,
                                lineWidth: 0.8
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var prefsDetailHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                NotchTheme.neonCyan.opacity(0.35),
                                NotchTheme.neonViolet.opacity(0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: detailHeroSymbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NotchTheme.neonCyan)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(NotchTheme.neonEdge, lineWidth: 0.8)
                    )
                    .shadow(color: NotchTheme.neonCyan.opacity(0.25), radius: 8, y: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(detailTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(detailSubtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            NotchTheme.neonCyan.opacity(0.55),
                            NotchTheme.neonViolet.opacity(0.25),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1.5)
        }
    }

    private var detailSubtitle: String {
        switch selectedPane {
        case .general: return "Startup, notch feel, display, and measurement units."
        case .widgets: return "Turn tray widgets on or off, then drag to reorder."
        case .notifications: return "How alerts reach the notch Hub — and when banners stay silent."
        case .permissions: return "Grant only what you need; Core items unlock the basics."
        case .about: return "Version, shortcuts, and quick ways to show the notch."
        case .widget: return "Tweaks for this widget. Changes apply immediately."
        }
    }

    private var detailHeroSymbol: String {
        switch selectedPane {
        case .widget(let id): return iconForWidget(id: id)
        default: return selectedPane.systemImage
        }
    }

    private var detailTitle: String {
        switch selectedPane {
        case .general: return "General"
        case .widgets: return "Tray widgets"
        case .notifications: return "Peek & Hub"
        case .permissions: return "Permissions"
        case .about: return "About"
        case .widget(let id):
            return widgetPanes.first(where: { $0.id == id })?.name ?? "Widget"
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedPane {
        case .general:
            generalSection
            feelTimingSection
            appearanceSection
            keyboardShortcutsSection
            unitsSection
        case .widgets:
            widgetsSection
            Text("Tip: pick a widget under Customize in the sidebar for deeper options (Battery, Music, Calendar…).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notifications:
            notificationsSection
        case .permissions:
            permissionsSection
        case .about:
            aboutSection
        case .widget(let id):
            if let section = widgetPanes.first(where: { $0.id == id }) {
                SettingsSection(title: section.name) {
                    section.view
                }
            } else {
                Text("This widget has no adjustable settings yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func iconForWidget(id: String) -> String {
        switch id {
        case "media", "media-controls": return "music.note"
        case "calendar": return "calendar"
        case "world-clock", "clocks": return "globe"
        case "battery": return "battery.100"
        case "checklist": return "checklist"
        case "clipboard": return "doc.on.clipboard"
        case "focus": return "moon.fill"
        case "notifications", "peek-hub": return "bell.badge"
        case "sports": return "sportscourt"
        case "system-health": return "heart.text.square"
        case "shelf": return "tray.full"
        case "webcam": return "web.camera"
        case "weather": return "cloud.sun"
        default: return "slider.horizontal.3"
        }
    }

    private var unitsSection: some View {
        SettingsSection(title: "Measurements") {
            Text("Used by World Clock distances and the conversion table. Weather can follow the same preference.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("System", selection: $units.system) {
                ForEach(MeasurementUnitsStore.System.allCases) { sys in
                    Text(sys.title).tag(sys)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("Show conversion table by default", isOn: $units.showConversionTable)
            MeasurementConvertPanel()
        }
    }

    private var generalSection: some View {
        SettingsSection(title: "General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    LaunchAtLogin.isEnabled = newValue
                    launchStatus = LaunchAtLogin.statusDescription
                }
            Text(launchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Hidden Mode (peek from the top edge)", isOn: Binding(
                get: { notch.isHiddenModeEnabled },
                set: { notch.setHiddenMode($0) }
            ))
            Text("When on, the notch stays hidden until you move the cursor to the top of the screen, then retreats when you move away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    private var feelTimingSection: some View {
        SettingsSection(title: "Notch feel") {
            Text("Notch responsiveness")
                .font(.subheadline.weight(.semibold))
            Picker("Collapse delay", selection: Binding(
                get: { Int(notch.collapseDelaySeconds) },
                set: { notch.setCollapseDelay(TimeInterval($0)) }
            )) {
                Text("Hover only (instant)").tag(0)
                Text("1 second").tag(1)
                Text("3 seconds (default)").tag(3)
                Text("5 seconds").tag(5)
                Text("7 seconds").tag(7)
                Text("10 seconds").tag(10)
                Text("30 seconds").tag(30)
            }
            .labelsHidden()
            Text("How long the tray stays open after the cursor leaves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Peek duration")
                .font(.subheadline.weight(.semibold))
            Picker("Peek duration", selection: $peekDwellMultiplier) {
                Text("Shorter").tag(0.5)
                Text("Normal").tag(1.0)
                Text("Longer").tag(1.5)
                Text("Extra long").tag(2.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("How long each Peek stays up. Normal is ~3–7.5s depending on urgency.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Meeting Mode")
                .font(.subheadline.weight(.semibold))
            Toggle("Meeting Mode", isOn: Binding(
                get: { MeetingMode.shared.isEnabled },
                set: { MeetingMode.shared.isEnabled = $0 }
            ))
            Toggle("Dim music ambient during meetings", isOn: Binding(
                get: { MeetingMode.shared.dimMediaAmbient },
                set: { MeetingMode.shared.dimMediaAmbient = $0 }
            ))
            Toggle("Also quiet peeks when Low Power / Focus proxy is on", isOn: Binding(
                get: { MeetingMode.shared.quietOnFocus },
                set: { MeetingMode.shared.quietOnFocus = $0 }
            ))
        }
    }

    /// Notifications pane — Peek hub, router, Amplify bridge tests.
    private var notificationsSection: some View {
        SettingsSection(title: "Notifications & Peek") {
            Text("Notifications through Peek (not banners)")
                .font(.subheadline.weight(.semibold))
            Text("Dynamo delivers alerts as notch Peeks — the way you want them — not as typical top-right system banners. Calendar, battery, media, Focus, and Messages/FaceTime (when routed) all use Peek.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Deliver through Peek only", isOn: Binding(
                get: { DynamoNotificationRouter.shared.peekOnlyDelivery },
                set: { DynamoNotificationRouter.shared.peekOnlyDelivery = $0 }
            ))
            Toggle("Dynamo is the router", isOn: Binding(
                get: { DynamoNotificationRouter.shared.isEnabled },
                set: { DynamoNotificationRouter.shared.isEnabled = $0 }
            ))
            Toggle("Route system apps into Peek (Messages, FaceTime…)", isOn: Binding(
                get: { DynamoNotificationRouter.shared.routeSystemApps },
                set: { DynamoNotificationRouter.shared.routeSystemApps = $0 }
            ))
            Toggle("Route widgets", isOn: Binding(
                get: { DynamoNotificationRouter.shared.routeWidgets },
                set: { DynamoNotificationRouter.shared.routeWidgets = $0 }
            ))
            Toggle("Route Focus", isOn: Binding(
                get: { DynamoNotificationRouter.shared.routeFocus },
                set: { DynamoNotificationRouter.shared.routeFocus = $0 }
            ))
            Toggle("Route external API / Shortcuts", isOn: Binding(
                get: { DynamoNotificationRouter.shared.routeExternal },
                set: { DynamoNotificationRouter.shared.routeExternal = $0 }
            ))
            Toggle("Prioritize calls & texts", isOn: Binding(
                get: { mirror.prioritizeCallsAndTexts },
                set: { mirror.prioritizeCallsAndTexts = $0 }
            ))
            .disabled(!DynamoNotificationRouter.shared.routeSystemApps)
            Toggle("Peek haptics", isOn: Binding(
                get: { PeekNotificationCenter.shared.hapticsEnabled },
                set: { PeekNotificationCenter.shared.hapticsEnabled = $0 }
            ))
            Toggle("Critical alert sound", isOn: Binding(
                get: { PeekNotificationCenter.shared.criticalSoundEnabled },
                set: { PeekNotificationCenter.shared.criticalSoundEnabled = $0 }
            ))

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stop the usual corner banners")
                        .font(.caption.weight(.semibold))
                    Text("Apple does not let Dynamo turn off Messages/FaceTime banners for you. Keep “Allow Notifications” ON (so Dynamo can still see them), but set Alert style to None for each app:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Messages · FaceTime · Mail · Slack… → Notifications → Alert style → None")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Open Notifications settings") {
                            DynamoNotificationRouter.shared.openNotificationSettingsForPeekOnly()
                        }
                        .controlSize(.small)
                        Button("Open Focus") {
                            DynamoNotificationRouter.shared.openFocusForPeekOnly()
                        }
                        .controlSize(.small)
                    }
                    Text("Also needs Full Disk Access so Dynamo can route those apps into Peek.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(DynamoNotificationRouter.shared.lastStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(mirror.lastStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(mirror.accessDenied ? Color.orange : Color.secondary)
                .lineLimit(2)
            if DynamoNotificationRouter.shared.routedCount > 0 {
                Text("Routed \(DynamoNotificationRouter.shared.routedCount) · last: \(DynamoNotificationRouter.shared.lastRoutedTitle)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                if mirror.accessDenied {
                    Button("Open Full Disk Access") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    Button("Retry ingest") {
                        mirror.stop()
                        mirror.start()
                    }
                    .controlSize(.small)
                }
                Button("Open Focus settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.focus") {
                        NSWorkspace.shared.open(url)
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .help("Silence system banners so the Peek hub is the only surface")
            }
            if PeekNotificationCenter.shared.pendingCount > 0 {
                Text("\(PeekNotificationCenter.shared.pendingCount) queued in hub")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if PeekNotificationCenter.shared.unreadCount > 0 {
                Text("\(PeekNotificationCenter.shared.unreadCount) unread in Hub tab")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let last = PeekNotificationCenter.shared.lastDelivered {
                Text("Last Peek: \(last.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Send test message Peek") {
                // Uses Contacts so the island tints to the contact photo colors.
                let me = NSFullUserName()
                let name = me.isEmpty ? "Alex" : me
                let art = ContactPhotoResolver.imageDataForMessage(
                    title: name,
                    body: "On my way — 5 min"
                ) ?? ContactPhotoResolver.imageData(matchingName: name)
                DynamoNotificationAPI.post(
                    title: name,
                    subtitle: "On my way — 5 min",
                    detail: "Text · Messages",
                    systemImage: "message.fill",
                    urgency: .critical,
                    category: "text",
                    id: "test-text|\(Date().timeIntervalSince1970)",
                    artworkData: art
                )
            }
            .controlSize(.small)
            Text("Message Peeks tint from the contact photo (allow Contacts).")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Toggle("External Peek bridge (Shortcuts)", isOn: Binding(
                get: { PeekBridge.shared.isEnabled },
                set: { PeekBridge.shared.isEnabled = $0 }
            ))
            Text("Notification API: dynamo://notify?title=…&subtitle=…&urgency=high · distributed com.akshithkonda.Dynamo.notify")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Send test Peek") {
                DynamoNotificationAPI.post(
                    title: "Dynamo",
                    subtitle: "Notification API is working",
                    detail: "Test",
                    systemImage: "checkmark.seal.fill",
                    urgency: .high,
                    category: "test",
                    id: "test|\(Date().timeIntervalSince1970)"
                )
            }
            .controlSize(.small)

            Divider()

            Text("Media Amplify")
                .font(.subheadline.weight(.semibold))
            Toggle("Amplify / Symphony EQ", isOn: Binding(
                get: { amplify.isEnabled },
                set: { amplify.isEnabled = $0 }
            ))
            Picker("Profile", selection: Binding(
                get: { amplify.profile },
                set: { amplify.profile = $0 }
            )) {
                ForEach(MediaAmplifyProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .labelsHidden()
            Text(amplify.profile.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Listening device")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Device", selection: Binding(
                get: { amplify.outputDevice },
                set: { amplify.outputDevice = $0 }
            )) {
                ForEach(AmplifyOutputDevice.allCases) { device in
                    Text(device.title).tag(device)
                }
            }
            .labelsHidden()
            Text(amplify.statusLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let err = amplify.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Audio Privacy") {
                        amplify.openAutomationSettings()
                    }
                    .controlSize(.small)
                    Button("Retry EQ") {
                        amplify.retryApply()
                    }
                    .controlSize(.small)
                }
            }
            Text("Fidelity Amplify (local): Reference = transparent; Symphony = mild contour; live adaptive trims; linked true-peak limiter (−1 dBTP). Auto path: Dolby Atmos bed / Spatial / Stereo / stereo-mix fallback. Width only on Impact. Device calibration is mild (AirPods, MacBook, monitors). Works with Atmos/Spatial — does not decode Dolby codecs. macOS 14.2+.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            Text("Display for notch")
                .font(.subheadline.weight(.semibold))
            Picker("Display", selection: Binding(
                get: { DisplayPreference.preferredDisplayID ?? "" },
                set: { newValue in
                    DisplayPreference.preferredDisplayID = newValue.isEmpty ? nil : newValue
                    notch.applyPreferredDisplay()
                }
            )) {
                Text("Automatic (prefer notched)").tag("")
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    Text(DisplayPreference.label(for: screen))
                        .tag(DisplayPreference.displayID(of: screen))
                }
            }
            .labelsHidden()
            Text("Pick which monitor hosts the notch tray when you use multiple displays. Automatic prefers a notched built-in display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyboardShortcutsSection: some View {
        SettingsSection(title: "Keyboard Shortcuts") {
            Text("All shortcuts use ⌃⌥ (Control + Option) plus the key shown below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(GlobalHotKeys.Action.allCases, id: \.rawValue) { action in
                    HStack {
                        Text(action.actionName)
                            .font(.body)
                        Spacer(minLength: 0)
                        Text(action.label)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                                    )
                            )
                    }
                }
            }
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamo")
                        .font(.body.weight(.semibold))
                    Text(appVersionString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Text("Notch widget dock for macOS — media, calendar, world clock, clipboard, shelf, webcam, and more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hotkeys: ⌃⌥D notch · ⌃⌥P play/pause · ⌃⌥M mute · ⌃⌥S shelf · ⌃⌥C calendar · ⌃⌥B clipboard · ⌃⌥H hub")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("URLs: dynamo://show · mute · play · shelf · calendar · clipboard · hub · airdrop · peek?title=")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Show Notch") {
                    notch.revealAndExpand()
                }
                .controlSize(.small)
                Button("Focus File Shelf") {
                    notch.focusPlugin(id: "shelf")
                }
                .controlSize(.small)
                Button("Focus Calendar") {
                    notch.focusPlugin(id: "calendar")
                }
                .controlSize(.small)
                Spacer(minLength: 0)
                Button("About Dynamo…") {
                    NSApp.orderFrontStandardAboutPanel(options: [:])
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }
        }
    }

    private var permissionsSection: some View {
        SettingsSection(title: "Permissions") {
            Text("Everything Dynamo may need from macOS. Core: Calendar, Reminders, Control Music. Optional: Webcam, Meeting Listen, Amplify EQ, notification mirror (Full Disk Access), Location (optional city label for Clocks “Here”). Clocks use Apple’s time zone database offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Core")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            ForEach(DynamoPermission.allCases.filter(\.isRequiredForCore)) { permission in
                permissionRow(permission)
            }

            Text("Optional")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 8)
            ForEach(DynamoPermission.allCases.filter { !$0.isRequiredForCore }) { permission in
                permissionRow(permission)
            }

            HStack {
                Button("Refresh permissions") {
                    permissions.refreshFromSystem()
                }
                .controlSize(.small)
                Spacer()
                Text("\(DynamoPermission.allCases.filter { permissions.isGranted($0) }.count)/\(DynamoPermission.allCases.count) granted")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func permissionRow(_ permission: DynamoPermission) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor(permissions.status(for: permission)))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.displayName)
                        .font(.body.weight(.medium))
                    if permission.isRequiredForCore {
                        Text("Core")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusLabel(permissions.status(for: permission)))
                    .font(.caption2)
                    .foregroundStyle(statusColor(permissions.status(for: permission)).opacity(0.9))
            }
            Spacer(minLength: 0)
            if permissions.status(for: permission) != .granted {
                Button("System Settings") {
                    permissions.openSystemSettings(for: permission)
                }
                .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: PermissionMemoryStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .unknown: return .gray
        }
    }

    private func statusLabel(_ status: PermissionMemoryStatus) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied — open macOS System Settings to change"
        case .notDetermined: return "Not asked yet — use the feature once to prompt"
        case .unknown: return "Unknown (app may be closed / not installed)"
        }
    }

    private var widgetsSection: some View {
        SettingsSection(title: "Widgets") {
            Text("Toggle widgets on or off and drag to reorder the notch tray. Changes apply immediately and survive relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(registry.allRegistered, id: \.id) { item in
                    SettingsWidgetRow(
                        name: item.name,
                        isEnabled: Binding(
                            get: { registry.isEnabled(item.id) },
                            set: { registry.setEnabled(item.id, isEnabled: $0) }
                        )
                    )
                }
                .onMove { indices, newOffset in
                    var ids = registry.allRegistered.map(\.id)
                    ids.move(fromOffsets: indices, toOffset: newOffset)
                    registry.reorder(ids: ids)
                    WidgetSettingsStore.shared.persist(from: registry)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 300)
        }
    }
}

/// Grouped settings card — dark neon glass plate.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [NotchTheme.neonCyan.opacity(0.9), NotchTheme.neonViolet.opacity(0.65)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: 13)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                NotchTheme.neonCyan.opacity(0.07),
                                Color.clear,
                                NotchTheme.neonViolet.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                // Soft grid sheen — futuristic, not loud.
                PreferencesGridSheen()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(0.18)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NotchTheme.neonEdge, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 5)
    }
}

private struct SettingsWidgetRow: View {
    let name: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(NotchTheme.neonCyan.opacity(0.55))
                .font(.system(size: 12, weight: .semibold))
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NotchTheme.neonCyan)
        }
        .padding(.vertical, 3)
    }
}

/// Dark glass wash for Preferences columns.
private struct PreferencesGlassBackground: View {
    var intensity: Double = 0.8

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.09)
            LinearGradient(
                colors: [
                    NotchTheme.neonCyan.opacity(0.08 * intensity),
                    Color.clear,
                    NotchTheme.neonViolet.opacity(0.07 * intensity)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PreferencesGridSheen()
                .opacity(0.12 * intensity)
        }
        .ignoresSafeArea()
    }
}

/// Subtle technical grid — readable neon glass, not cyberpunk wallpaper.
private struct PreferencesGridSheen: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 22
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(
                path,
                with: .color(NotchTheme.neonCyan.opacity(0.22)),
                lineWidth: 0.4
            )
        }
        .allowsHitTesting(false)
    }
}
