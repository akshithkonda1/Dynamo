import Foundation

/// Optional capability for widgets that accept filesystem drops on the notch.
/// Hosts discover acceptors via `WidgetRegistry` — never by widget name.
@MainActor
protocol FileDropAccepting: NotchWidgetPlugin {
    func handleFileDrop(urls: [URL])
}
