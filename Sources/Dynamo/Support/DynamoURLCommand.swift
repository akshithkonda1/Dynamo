import Foundation

/// Parsed `dynamo://` host (no side effects). Used by `DynamoURLRouter` and tests.
enum DynamoURLCommand: Equatable {
    case show
    case mute
    case play
    case shelf
    case calendar
    case clipboard
    case hub
    case airdrop
    case notify
    case unknown(String)

    static func parse(_ url: URL) -> DynamoURLCommand {
        guard url.scheme?.lowercased() == "dynamo" else {
            return .unknown(url.scheme ?? "")
        }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
        switch host {
        case "show", "notch":
            return .show
        case "mute":
            return .mute
        case "play", "playpause":
            return .play
        case "shelf":
            return .shelf
        case "calendar":
            return .calendar
        case "clipboard", "paste":
            return .clipboard
        case "hub", "inbox", "peeks":
            return .hub
        case "airdrop":
            return .airdrop
        case "notify", "notification", "peek":
            return .notify
        default:
            return .unknown(host)
        }
    }
}
