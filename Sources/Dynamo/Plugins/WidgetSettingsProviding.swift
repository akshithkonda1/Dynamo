import SwiftUI

/// Optional capability: a widget that exposes its own configuration UI inside
/// the Settings window.
///
/// Like `FileDropAccepting`, this is discovered by a protocol cast on the
/// registry (`WidgetRegistry.settingsSections()`) — hosts never special-case a
/// widget by name. A widget adds settings by conforming and returning a view;
/// nothing in Settings needs to know it exists.
@MainActor
protocol WidgetSettingsProviding: AnyObject {
    /// Configuration UI rendered under this widget's name in Settings.
    func settingsView() -> AnyView
}
