import AppKit
import SwiftUI

/// Placeholder settings window for Phase 0. Feature 5 replaces the body with
/// full reorder/toggle UI; the window shell exists so the menu item works now.
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
            let root = SettingsPlaceholderView(registry: registry)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Dynamo Settings"
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsPlaceholderView: View {
    @ObservedObject var registry: WidgetRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widgets")
                .font(.headline)
            Text("Reorder and enable/disable controls land in a later pass. Registered widgets:")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(registry.allRegistered, id: \.id) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(item.enabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 160)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
