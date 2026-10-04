import Foundation

/// Single catalog of widgets AppDelegate registers.
///
/// Tests instantiate this factory instead of a hand-typed ID list. Adding a
/// case registers it on launch; renaming `rawValue` must match `plugin.id`
/// or `NotchTabRowTests` fails. Weather is intentionally omitted (World Clock
/// replaced WeatherKit in production).
enum ProductionWidgetKind: String, CaseIterable {
    case media = "media"
    case peekHub = "peek-hub"
    case calendar = "calendar"
    case clipboard = "clipboard"
    case checklist = "checklist"
    case worldClock = "world-clock"
    case battery = "battery"
    case focus = "focus"
    case sports = "sports"
    case systemHealth = "system-health"
    case shelf = "shelf"
    case webcam = "webcam"
}

/// Result of `ProductionWidgets.makeDefaultPlugins`.
@MainActor
struct ProductionWidgetBundle {
    let plugins: [any NotchWidgetPlugin]
    let media: MediaControlsPlugin
    let worldClock: WorldClockPlugin

    var ids: [String] { plugins.map { $0.id } }
}

@MainActor
enum ProductionWidgets {
    /// Ordered IDs from the catalog — same order AppDelegate registers.
    static var orderedIDs: [String] {
        ProductionWidgetKind.allCases.map(\.rawValue)
    }

    /// Build the production tray. Callers may inject test doubles.
    static func makeDefaultPlugins(
        mediaProvider: NowPlayingProvider? = nil,
        calendarProvider: CalendarProvider? = nil
    ) -> ProductionWidgetBundle {
        let media = MediaControlsPlugin(provider: mediaProvider ?? MediaRemoteNowPlayingProvider())
        let worldClock = WorldClockPlugin()
        let plugins: [any NotchWidgetPlugin] = ProductionWidgetKind.allCases.map { kind in
            switch kind {
            case .media: return media
            case .peekHub: return NotificationsPlugin()
            case .calendar: return CalendarPlugin(provider: calendarProvider)
            case .clipboard: return ClipboardPlugin()
            case .checklist: return ChecklistPlugin()
            case .worldClock: return worldClock
            case .battery: return BatteryPlugin()
            case .focus: return FocusPlugin()
            case .sports: return SportsPlugin()
            case .systemHealth: return SystemHealthPlugin()
            case .shelf: return ShelfPlugin()
            case .webcam: return WebcamPlugin()
            }
        }
        return ProductionWidgetBundle(plugins: plugins, media: media, worldClock: worldClock)
    }
}
