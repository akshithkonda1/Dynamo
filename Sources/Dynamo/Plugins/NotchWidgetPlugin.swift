import SwiftUI

/// The single seam every notch widget must conform to.
///
/// Hosts (`NotchContentView`, `WidgetRegistry`, `NotchWindowController`) must
/// never special-case a widget by name. Adding a widget means implementing this
/// protocol and registering it — nothing else.
@MainActor
protocol NotchWidgetPlugin: AnyObject, Identifiable {
    /// Stable identifier used for settings persistence and ordering.
    var id: String { get }

    /// Short label shown in Settings and accessibility.
    var displayName: String { get }

    /// SF Symbol name for the collapsed tray icon.
    var systemImage: String { get }

    /// Compact content that lives in the collapsed notch strip.
    func collapsedView() -> AnyView

    /// Full content shown when the notch is expanded and this widget is active.
    func expandedView() -> AnyView

    /// Called once when the plugin is registered. Use for timers, observers, etc.
    func start()

    /// Called when the plugin is torn down (app quit or disabled in settings).
    func stop()
}

extension NotchWidgetPlugin {
    func start() {}
    func stop() {}
}
