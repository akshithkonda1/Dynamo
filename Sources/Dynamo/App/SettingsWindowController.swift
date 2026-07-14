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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Dynamo Settings"
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
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

                generalSection
                widgetsSection

                // Per-widget configuration, discovered generically via
                // `WidgetSettingsProviding` — Settings never names a widget.
                let sections = registry.settingsSections()
                ForEach(sections, id: \.id) { section in
                    SettingsSection(title: section.name) {
                        section.view
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchStatus = LaunchAtLogin.statusDescription
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

            Toggle("Hidden mode (peek from the top edge)", isOn: Binding(
                get: { notch.isHiddenModeEnabled },
                set: { notch.setHiddenMode($0) }
            ))
            Text("When on, the notch stays hidden until you move the cursor to the top of the screen, then retreats when you move away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// A titled, card-styled settings group — makes each block of settings visible
/// and obvious at a glance rather than crammed into one list.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
