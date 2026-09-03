import AppKit
import Foundation

/// Handles `dynamo://` URLs for Shortcuts and scripts.
///
/// | URL | Action |
/// |-----|--------|
/// | dynamo://show | Expand notch |
/// | dynamo://mute | Toggle mute |
/// | dynamo://play | Play/pause |
/// | dynamo://shelf | Focus shelf |
/// | dynamo://calendar | Focus calendar |
/// | dynamo://clipboard | Focus clipboard |
/// | dynamo://hub | Focus Peek Hub |
/// | dynamo://airdrop | AirDrop newest shelf item |
/// | dynamo://notify?title=…&subtitle=…&urgency=high | Peek via Notification API |
/// | dynamo://peek?title=…&subtitle=… | Same as notify (legacy) |
@MainActor
enum DynamoURLRouter {
    static func handle(
        _ url: URL,
        notch: NotchWindowController?,
        media: MediaControlsPlugin?,
        registry: WidgetRegistry? = nil
    ) {
        switch DynamoURLCommand.parse(url) {
        case .show:
            notch?.revealAndExpand()
        case .mute:
            SystemVolumeController.shared.toggleMute()
        case .play:
            media?.togglePlayPause()
        case .shelf:
            notch?.focusPlugin(id: "shelf")
        case .calendar:
            notch?.focusPlugin(id: "calendar")
        case .clipboard:
            notch?.focusPlugin(id: "clipboard")
        case .hub:
            notch?.focusPlugin(id: "peek-hub")
        case .airdrop:
            registry?.firstPlugin(as: ShelfPlugin.self)?.store.airDropNewest()
        case .notify:
            if PeekBridge.shared.isEnabled {
                _ = DynamoNotificationAPI.postFromURL(url)
            }
        case .unknown:
            break
        }
    }
}
