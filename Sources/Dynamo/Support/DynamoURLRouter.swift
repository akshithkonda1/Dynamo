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
/// | dynamo://notify?title=…&subtitle=…&urgency=high | Peek via Notification API |
/// | dynamo://peek?title=…&subtitle=… | Same as notify (legacy) |
@MainActor
enum DynamoURLRouter {
    static func handle(
        _ url: URL,
        notch: NotchWindowController?,
        media: MediaControlsPlugin?
    ) {
        guard url.scheme?.lowercased() == "dynamo" else { return }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()

        switch host {
        case "show", "notch":
            notch?.revealAndExpand()
        case "mute":
            SystemVolumeController.shared.toggleMute()
        case "play", "playpause":
            media?.togglePlayPause()
        case "shelf":
            notch?.focusPlugin(id: "shelf")
        case "calendar":
            notch?.focusPlugin(id: "calendar")
        case "notify", "notification", "peek":
            if PeekBridge.shared.isEnabled {
                _ = DynamoNotificationAPI.postFromURL(url)
            }
        default:
            break
        }
    }
}
