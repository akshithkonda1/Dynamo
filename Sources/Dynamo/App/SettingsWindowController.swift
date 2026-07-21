import AppKit
import SwiftUI

/// Real Settings window (NSWindow, not a notch panel), opened from the menu bar.
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
            // Standard macOS settings window — titled, translucent titlebar.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dynamo Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.backgroundColor = NSColor.windowBackgroundColor
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DynamoSettingsWindow")
            window.setContentSize(NSSize(width: 600, height: 760))
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamo Settings")
                        .font(.largeTitle.weight(.bold))
                    Text("notch widget dock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // IA: General · Appearance · Widgets · Permissions · About
                generalSection
                appearanceSection
                widgetsSection
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

            Text("Collapse after leaving notch")
                .font(.subheadline.weight(.semibold))
            Picker("Collapse delay", selection: Binding(
                get: { Int(notch.collapseDelaySeconds) },
                set: { notch.setCollapseDelay(TimeInterval($0)) }
            )) {
                Text("Hover only (immediate)").tag(0)
                Text("5 seconds").tag(5)
                Text("7 seconds (default)").tag(7)
                Text("10 seconds").tag(10)
                Text("30 seconds").tag(30)
            }
            .labelsHidden()
            Text("How long the expanded tray stays open after the cursor leaves. Default is 7 seconds (in the 5–10s sweet spot). Hover-only collapses as soon as you leave.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Hidden mode (peek from the top edge)", isOn: Binding(
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

            Divider()

            Toggle("Critical Peek bridge (external)", isOn: Binding(
                get: { PeekBridge.shared.isEnabled },
                set: { PeekBridge.shared.isEnabled = $0 }
            ))
            Text("Allow Shortcuts/scripts to show a notch peek via dynamo://peek?title=… or distributed notification com.akshithkonda.Dynamo.externalPeek. Off by default.")
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

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            Text("Dynamo")
                .font(.body.weight(.semibold))
            Text("Notch widget dock for macOS — media, calendar, clipboard, shelf, webcam, and more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Daily driver build: ~/Documents/Dynamo/dist/Dynamo.app")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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
            }
        }
    }

    private var permissionsSection: some View {
        SettingsSection(title: "Permissions") {
            Text("Dynamo remembers the last status it saw and re-checks when you open Settings or return to the app. Grants are still stored by macOS — Dynamo never re-prompts once authorized.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(DynamoPermission.allCases, id: \.rawValue) { permission in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor(permissions.status(for: permission)))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.displayName)
                            .font(.body.weight(.medium))
                        Text(permission.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(statusLabel(permissions.status(for: permission)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if permissions.status(for: permission) != .granted {
                        Button("Open") {
                            permissions.openSystemSettings(for: permission)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }

            Button("Refresh permissions") {
                permissions.refreshFromSystem()
            }
            .controlSize(.small)
        }
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
        case .granted: return "Granted (remembered)"
        case .denied: return "Denied — open System Settings to change"
        case .notDetermined: return "Not asked yet"
        case .unknown: return "Unknown (app may be closed)"
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
