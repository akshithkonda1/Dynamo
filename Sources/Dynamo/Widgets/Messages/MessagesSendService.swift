import Foundation

/// Sends iMessages/SMS by driving Messages.app via AppleScript — the exact
/// same "control another app via Apple Events, with the user's permission"
/// pattern `AppleScriptMedia` (MediaRemoteNowPlayingProvider.swift) already
/// uses for Music/Spotify. The recipient receives a completely ordinary
/// message; nothing about how it arrives differs from the user typing it
/// into Messages.app themselves.
///
/// macOS prompts for Automation access (System Settings → Privacy & Security
/// → Automation → Dynamo → Messages) the first time this actually runs —
/// there is no way to request that ahead of time, same limitation as Full
/// Disk Access.
@MainActor
final class MessagesSendService {
    @discardableResult
    func send(text: String, chatGUID: String) -> Bool {
        let script = """
        tell application "Messages"
            send \(Self.appleScriptLiteral(text)) to chat id \(Self.appleScriptLiteral(chatGUID))
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil {
            PermissionsStore.shared.recordGranted(.automationMessages)
            return true
        }
        // Don't mark denied on transient failures (Messages not running, bad chat id).
        return false
    }

    /// Quotes and escapes a string for safe interpolation into an AppleScript
    /// string literal — the message text is arbitrary user input and could
    /// otherwise break out of the quoted literal.
    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
