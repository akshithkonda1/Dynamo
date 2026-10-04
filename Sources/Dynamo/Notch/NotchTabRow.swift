import Foundation

/// Membership of the expanded island’s top-band tab row.
///
/// Dynamo registers more plugins than a NotchDock-style strip can show at once.
/// The row **never drops a plugin** — left and right cheeks scroll when the
/// compact ~555pt panel cannot fit every icon. Settings is chrome, not a plugin.
///
/// `NotchWidgetPlugin.id` is main-actor isolated, so these helpers must run
/// on the main actor (and tests that call them must be `@MainActor` too).
@MainActor
enum NotchTabRow {
    /// Right-side cluster (before Settings): Focus, Sports, Health, Shelf, Webcam.
    static let trailingIDs = ["focus", "sports", "system-health", "shelf", "webcam"]

    /// IDs `AppDelegate` registers today. Weather ships as a plugin but is not
    /// in the production tray (World Clock replaced WeatherKit).
    static let productionRegisteredIDs: [String] = [
        "media",
        "peek-hub",
        "calendar",
        "clipboard",
        "checklist",
        "world-clock",
        "battery",
        "focus",
        "sports",
        "system-health",
        "shelf",
        "webcam"
    ]

    static func leading(from plugins: [any NotchWidgetPlugin]) -> [any NotchWidgetPlugin] {
        let trailing = Set(trailingIDs)
        return plugins.filter { !trailing.contains($0.id) }
    }

    static func trailing(from plugins: [any NotchWidgetPlugin]) -> [any NotchWidgetPlugin] {
        trailingIDs.compactMap { id in
            plugins.first { $0.id == id }
        }
    }

    /// Every visible plugin, in tab-row order (leading cheek, then trailing).
    /// Overflow is scroll — this list is never a subset of `plugins`.
    static func reachableIDs(from plugins: [any NotchWidgetPlugin]) -> [String] {
        leading(from: plugins).map { $0.id } + trailing(from: plugins).map { $0.id }
    }
}
