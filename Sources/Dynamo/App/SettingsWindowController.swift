import AppKit
import SwiftUI

/// Real Settings window (NSWindow, not a notch panel), opened from the menu bar.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private let registry: WidgetRegistry

    init(registry: WidgetRegistry) {
        self.registry = registry
        super.init()
    }

    func show() {
        if window == nil {
            let root = SettingsView(registry: registry)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Dynamo Settings"
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 460))
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI

struct SettingsView: View {
    @ObservedObject var registry: WidgetRegistry
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchStatus = LaunchAtLogin.statusDescription

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("General")
                    .font(.title2.weight(.semibold))
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        LaunchAtLogin.isEnabled = newValue
                        launchStatus = LaunchAtLogin.statusDescription
                    }
                Text(launchStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Widgets")
                    .font(.title3.weight(.semibold))
                Text("Toggle widgets on or off and drag to reorder the notch tray. Changes apply immediately and survive relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            HStack {
                Spacer()
                Text("Dynamo · notch widget dock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 400)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchStatus = LaunchAtLogin.statusDescription
        }
        .onReceive(NotificationCenter.default.publisher(for: .dynamoWidgetConfigurationDidChange)) { _ in
            WidgetSettingsStore.shared.persist(from: registry)
        }
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
