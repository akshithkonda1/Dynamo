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

    /// Full content shown when the notch is expanded and this widget is active.
    func expandedView() -> AnyView

    /// Preferred height of the expanded panel while this widget is active.
    /// Width is constant across every widget (so the tray icon row never
    /// jumps horizontally on tab switch); height defaults to the size that
    /// fits a full media player / scrollable list. Override only when a
    /// widget's content is reliably much shorter than that in every state
    /// (e.g. Battery) — the panel should expand to fit what's on screen, not
    /// balloon to the same footprint as the busiest widget regardless of
    /// content.
    var expandedContentHeight: CGFloat { get }

    /// Called once when the plugin is registered. Use for timers, observers, etc.
    func start()

    /// Called when the plugin is torn down (app quit or disabled in settings).
    func stop()
}

extension NotchWidgetPlugin {
    var expandedContentHeight: CGFloat { 220 }
    func start() {}
    func stop() {}
}
