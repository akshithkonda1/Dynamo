import AppKit
import SwiftUI

/// Pops the active notch widget into a larger standalone window.
/// One window per widget id; re-pressing the expand button brings it forward.
@MainActor
final class WidgetExpandWindowController: NSObject {
    static let shared = WidgetExpandWindowController()

    private var windows: [String: NSWindow] = [:]

    func present(plugin: any NotchWidgetPlugin) {
        let id = plugin.id
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = WidgetExpandWindowView(
            title: plugin.displayName,
            systemImage: plugin.systemImage,
            content: plugin.expandedView()
        )
        let hosting = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = plugin.displayName
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 520))
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(pluginID: String) {
        windows[pluginID]?.orderOut(nil)
        windows[pluginID] = nil
    }
}

extension WidgetExpandWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue
        else { return }
        windows[id] = nil
    }
}

private struct WidgetExpandWindowView: View {
    let title: String
    let systemImage: String
    let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .preferredColorScheme(.dark)
    }
}
