import AppKit
import Foundation

/// Opens a Messages compose window for a reply — **no Automation / Apple Events
/// permission**. macOS has no public silent-send API; AppleScript was the old
/// approach and required System Settings → Automation → Messages.
///
/// Strategy (first hit wins):
/// 1. `NSSharingService.composeMessage` with the chat's phone/email + body
/// 2. `imessage:` / `sms:` URL with pre-filled body
/// 3. Copy body to the pasteboard and open Messages.app (groups / unknown ids)
///
/// The user confirms Send in Messages. Once they do, Dynamo's next chat.db
/// poll picks up the real row — no optimistic fake bubble.
@MainActor
final class MessagesSendService {
    enum Outcome: Equatable {
        /// Compose UI opened (or pasteboard + Messages for groups).
        case openedCompose
        case failed
    }

    @discardableResult
    func send(
        text: String,
        chatGUID: String,
        chatIdentifier: String,
        isGroupChat: Bool
    ) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        // 1:1 chats have a real phone/email in chat_identifier.
        if !isGroupChat, let recipient = Self.recipientAddress(from: chatIdentifier) {
            if sendViaSharingService(recipient: recipient, text: trimmed) {
                return .openedCompose
            }
            if openComposeURL(recipient: recipient, text: trimmed) {
                return .openedCompose
            }
        }

        // Groups (and anything we can't address): paste + open Messages so the
        // user can paste into the right thread. chat.db has no public deep-link
        // for "open this group by guid".
        return openMessagesWithPasteboard(text: trimmed)
    }

    // MARK: - Paths

    private func sendViaSharingService(recipient: String, text: String) -> Bool {
        guard let service = NSSharingService(named: .composeMessage) else { return false }
        service.recipients = [recipient]
        guard service.canPerform(withItems: [text]) else { return false }
        // Accessory apps need a brief activation or the sheet can fail to front.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [text])
        return true
    }

    private func openComposeURL(recipient: String, text: String) -> Bool {
        let encodedBody = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let encodedRecipient = recipient.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? recipient

        // Prefer iMessage scheme; fall back to SMS (works for either on modern macOS).
        let candidates = [
            "imessage:\(encodedRecipient)&body=\(encodedBody)",
            "sms:\(encodedRecipient)&body=\(encodedBody)"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    private func openMessagesWithPasteboard(text: String) -> Outcome {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let appURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
        if NSWorkspace.shared.open(appURL) {
            return .openedCompose
        }
        // Older installs / custom volume layout.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            if NSWorkspace.shared.open(url) { return .openedCompose }
        }
        return .failed
    }

    // MARK: - Identifier cleanup

    /// Turns chat.db `chat_identifier` values into something Messages accepts.
    /// Examples: `+15551234567`, `name@icloud.com`, `28102(smsfp)` → `28102`.
    static func recipientAddress(from chatIdentifier: String) -> String? {
        var id = chatIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        // chat.guid style sometimes leaks in: any;-;+1555… / any;+;group-uuid
        if id.hasPrefix("any;") {
            let parts = id.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 {
                id = String(parts[2])
            }
        }

        // Short-code / carrier noise: `28102(smsfp)`
        if let paren = id.firstIndex(of: "(") {
            id = String(id[..<paren])
        }

        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        // Group / room identifiers are UUIDs or opaque tokens — not a person.
        if id.count >= 32, id.contains("-"), !id.contains("@"), id.first != "+" {
            return nil
        }

        return id
    }
}
