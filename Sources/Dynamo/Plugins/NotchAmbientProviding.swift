import SwiftUI

/// Optional capability: a widget that can present *ambient* content in the
/// collapsed notch — the thin slivers either side of the camera — when it has
/// something worth showing at rest.
///
/// Discovered by protocol cast on the registry (like `FileDropAccepting` and
/// `WidgetSettingsProviding`), so hosts never special-case a widget by name.
/// Media uses it to show album art on the leading edge and a visualizer on the
/// trailing edge while something is playing; otherwise the notch stays empty
/// and disappears into the cutout.
@MainActor
protocol NotchAmbientProviding: AnyObject {
    /// Whether this widget currently has ambient content worth showing.
    var isAmbientActive: Bool { get }

    /// A self-contained view laid out across the collapsed notch. It should push
    /// its own content toward the leading and trailing edges, leaving the middle
    /// clear for the physical camera.
    func ambientView() -> AnyView
}
