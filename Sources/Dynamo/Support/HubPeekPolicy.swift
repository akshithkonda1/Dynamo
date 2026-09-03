import Foundation

/// Resolves Hub inbox categories without hosts switching on widget names.
enum HubPeekPolicy {
    /// Prefer an explicit router category, then the peek's own hint, then inference.
    static func resolveCategory(
        peek: NotchSneakPeek,
        source: DynamoNotificationRouter.Source,
        explicit: String? = nil
    ) -> String {
        if let explicit {
            let t = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.lowercased() != "widget", t.lowercased() != "general" {
                return t
            }
        }
        let hinted = peek.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hinted.isEmpty { return hinted }

        if peek.style == .media { return "media" }

        let img = peek.systemImage.lowercased()
        let title = peek.title.lowercased()
        let detail = peek.detail.lowercased()

        if img.contains("calendar") { return "calendar" }
        if img.contains("checklist") { return "reminder" }
        if img.contains("music") || img.contains("headphones") { return "media" }
        if img.contains("battery") || img.contains("bolt") { return "battery" }
        if img.contains("clipboard") || img.contains("doc.on") || img.contains("photo.on") { return "clipboard" }
        if img.contains("heart.text") || img.contains("stethoscope") || img.contains("cross.case") {
            return "health"
        }
        if img.contains("cloud") || img.contains("sun.") || img.contains("cloud.sun") { return "weather" }
        if img.contains("sportscourt")
            || img.contains("basketball")
            || img.contains("football")
            || img.contains("hockey")
            || img.contains("baseball")
            || img.contains("soccer")
            || img.contains("tennis") {
            return "sports"
        }
        if img.contains("phone") || detail.hasPrefix("call") || title.contains("incoming") {
            return "call"
        }
        if detail.hasPrefix("text") { return "text" }
        if detail.hasPrefix("mail") { return "mail" }
        if img.contains("target") || img.contains("brain") || detail.contains("true focus") {
            return "focus"
        }

        switch source {
        case .widget: return "widget"
        case .focus: return "focus"
        case .system: return "system"
        case .call: return "call"
        case .api: return "api"
        case .external: return "external"
        case .test: return "test"
        }
    }
}

/// Hub chip filters — same matching the inbox UI uses.
enum HubInboxFilter: String, CaseIterable, Identifiable {
    case all, unread, battery, messages, calendar, media, system, sports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        case .battery: return "Battery"
        case .messages: return "Messages"
        case .calendar: return "Calendar"
        case .media: return "Media"
        case .system: return "System"
        case .sports: return "Sports"
        }
    }

    func matches(_ item: PeekNotificationCenter.PeekHistoryItem) -> Bool {
        let c = item.category.lowercased()
        let d = item.detail.lowercased()
        let img = item.systemImage.lowercased()
        switch self {
        case .all: return true
        case .unread: return item.isUnread
        case .battery: return c.contains("battery")
        case .messages:
            return c.contains("text") || c.contains("call") || c.contains("mail")
                || d.hasPrefix("text") || d.hasPrefix("call") || d.hasPrefix("mail")
        case .calendar:
            return c.contains("calendar") || c.contains("reminder")
                || img.contains("calendar") || img.contains("checklist")
        case .media:
            return c.contains("media") || img.contains("music")
        case .system:
            return c.contains("system") || c.contains("health") || c == "general"
        case .sports:
            return c.contains("sport")
                || img.contains("basketball") || img.contains("football")
                || img.contains("hockey") || img.contains("baseball")
                || img.contains("soccer") || img.contains("tennis")
        }
    }
}
