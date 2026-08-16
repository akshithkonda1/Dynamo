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
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Preferences"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.backgroundColor = NSColor.windowBackgroundColor
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DynamoPreferencesWindow")
            window.setContentSize(NSSize(width: 600, height: 800))
            window.minSize = NSSize(width: 520, height: 560)
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
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchStatus = LaunchAtLogin.statusDescription
    @AppStorage("peekDwellMultiplier") private var peekDwellMultiplier: Double = 1.0
    @ObservedObject private var amplify = MediaAmplifyController.shared
    @ObservedObject private var mirror = SystemNotificationMirror.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preferences")
                        .font(.largeTitle.weight(.bold))
                    Text("Dynamo · notch dock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // IA: General · Feel · Appearance · Widgets · Permissions · About
                generalSection
                feelSection
                appearanceSection
                widgetsSection
                keyboardShortcutsSection
                permissionsSection

                // Per-widget configuration, discovered generically via
                // `WidgetSettingsProviding` — Settings never names a widget.
                let sections = registry.settingsSections()
                ForEach(sections, id: \.id) { section in
                    SettingsSection(title: section.name) {
                        section.view
                    }
                }

                aboutSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchStatus = LaunchAtLogin.statusDescription
            PermissionsStore.shared.refreshFromSystem()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dynamoWidgetConfigurationDidChange)) { _ in
            WidgetSettingsStore.shared.persist(from: registry)
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

            Divider()

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
            Text("While a calendar event is Now, suppress routine sneak peeks. Critical alerts still show. Dim ambient softens music in the collapsed strip during meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Feel & alerts — collapse timing, peeks, Amplify, notification surface.
    private var feelSection: some View {
        SettingsSection(title: "Feel & alerts") {
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
            Text("How long the tray stays open after the cursor leaves. Default is 3s for a responsive feel. Use Hover only for instantaneous collapse.")
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

            Text("Notifications → Peek")
                .font(.subheadline.weight(.semibold))
            Toggle("Deliver all Dynamo alerts as Peeks", isOn: Binding(
                get: { PeekNotificationCenter.shared.isPrimaryDelivery },
                set: { PeekNotificationCenter.shared.isPrimaryDelivery = $0 }
            ))
            Toggle("Mirror calls, texts & system notifications", isOn: Binding(
                get: { mirror.isEnabled },
                set: { mirror.isEnabled = $0 }
            ))
            Toggle("Prioritize calls & texts (critical Peek)", isOn: Binding(
                get: { mirror.prioritizeCallsAndTexts },
                set: { mirror.prioritizeCallsAndTexts = $0 }
            ))
            .disabled(!mirror.isEnabled)
            Toggle("Peek haptics", isOn: Binding(
                get: { PeekNotificationCenter.shared.hapticsEnabled },
                set: { PeekNotificationCenter.shared.hapticsEnabled = $0 }
            ))
            Toggle("Critical alert sound", isOn: Binding(
                get: { PeekNotificationCenter.shared.criticalSoundEnabled },
                set: { PeekNotificationCenter.shared.criticalSoundEnabled = $0 }
            ))
            Text("Like reminders: Messages, FaceTime/Phone, Mail, Slack/Teams, and other Notification Center alerts appear as notch Peeks when mirroring is on. Grant Full Disk Access so Dynamo can read the Notification Center store. macOS may still show system banners — quiet them in Focus / Notifications if you want Peek-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(mirror.lastStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(mirror.accessDenied ? Color.orange : Color.secondary)
                .lineLimit(2)
            if !mirror.lastMirroredApp.isEmpty {
                Text("Last app: \(mirror.lastMirroredApp) · \(mirror.mirroredCount) mirrored")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if mirror.accessDenied {
                HStack(spacing: 8) {
                    Button("Open Full Disk Access") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    Button("Retry") {
                        mirror.stop()
                        mirror.start()
                    }
                    .controlSize(.small)
                }
            }
            if PeekNotificationCenter.shared.pendingCount > 0 {
                Text("\(PeekNotificationCenter.shared.pendingCount) queued")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let last = PeekNotificationCenter.shared.lastDelivered {
                Text("Last Peek: \(last.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Send test text Peek") {
                DynamoNotificationAPI.post(
                    title: "Alex",
                    subtitle: "On my way — 5 min",
                    detail: "Text · Messages",
                    systemImage: "message.fill",
                    urgency: .critical,
                    category: "text",
                    id: "test-text|\(Date().timeIntervalSince1970)"
                )
            }
            .controlSize(.small)

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
            Text("Hotkeys: ⌃⌥D notch · ⌃⌥P play/pause · ⌃⌥M mute · ⌃⌥S shelf · ⌃⌥C calendar")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("URLs: dynamo://show · mute · play · shelf · calendar · peek?title=")
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

/// Grouped settings block using system control background (native) with
/// continuous corner radius (Dynamo softness).
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        )
    }
}

private struct SettingsWidgetRow: View {
    let name: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .semibold))
            Text(name)
                .font(.body)
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}
