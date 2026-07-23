import Foundation

enum MeetingActionExtractor {
    private static let triggers: [String] = [
        "i'll", "i will", "i need to", "i should",
        "we'll", "we will", "we need to", "we should",
        "can you", "could you", "please",
        "action:", "todo:", "follow up", "next step",
        "let's", "let me", "remind me",
        "send", "schedule", "book", "ping", "share",
    ]

    static func extract(from bullets: [MeetingNoteBullet]) -> [MeetingNoteBullet] {
        bullets.filter { b in
            let t = b.text.lowercased()
            return triggers.contains { t.hasPrefix($0) || t.contains(" \($0)") }
        }
    }
}
