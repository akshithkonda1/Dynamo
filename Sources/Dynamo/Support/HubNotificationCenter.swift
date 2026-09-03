import AppKit
import Foundation

/// How Hub + Peek stand in for macOS Notification Center.
///
/// Apple does not let third-party apps hide other apps’ corner banners.
/// Dynamo can still **be** the notification system if:
/// 1. Full Disk Access (read the local Notification Center store)
/// 2. Every app still *allows* notifications (so Dynamo can ingest them)
/// 3. Each app’s **Alert style is None** (no top-right banner)
/// Then Peek is the banner and Hub is the inbox.
enum HubNotificationCenter {
    struct AppGroup: Identifiable, Equatable {
        var id: String
        var title: String
        var bundleID: String
        var items: [PeekNotificationCenter.PeekHistoryItem]
        var unread: Int { items.filter(\.isUnread).count }
    }

    /// Apps to silence in System Settings so Peek is the only banner.
    static let bannerSilenceApps: [(name: String, bundleID: String)] = [
        ("Messages", "com.apple.MobileSMS"),
        ("FaceTime", "com.apple.FaceTime"),
        ("Mail", "com.apple.mail"),
        ("Phone", "com.apple.InCallService"),
        ("Calendar", "com.apple.iCal"),
        ("Reminders", "com.apple.reminders"),
        ("Safari", "com.apple.Safari"),
        ("Slack", "com.tinyspeck.slackmacgap"),
        ("Discord", "com.hnc.Discord"),
        ("Zoom", "us.zoom.xos"),
        ("Teams", "com.microsoft.teams2"),
        ("Telegram", "ru.keepcoder.Telegram"),
        ("WhatsApp", "net.whatsapp.WhatsApp"),
        ("Signal", "org.whispersystems.signal-macos")
    ]

    static func grouped(
        _ items: [PeekNotificationCenter.PeekHistoryItem]
    ) -> [AppGroup] {
        var order: [String] = []
        var buckets: [String: [PeekNotificationCenter.PeekHistoryItem]] = [:]
        for item in items {
            let key = groupKey(item)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let items = buckets[key], let first = items.first else { return nil }
            return AppGroup(
                id: key,
                title: groupTitle(first),
                bundleID: first.sourceBundleID,
                items: items
            )
        }
    }

    static func groupKey(_ item: PeekNotificationCenter.PeekHistoryItem) -> String {
        let bid = item.sourceBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bid.isEmpty { return bid }
        let cat = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return cat.isEmpty ? "dynamo" : "dynamo.\(cat)"
    }

    static func groupTitle(_ item: PeekNotificationCenter.PeekHistoryItem) -> String {
        if !item.appName.isEmpty { return item.appName }
        let bid = item.sourceBundleID
        if !bid.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return FileManager.default.displayName(atPath: url.path)
            }
            return bid.split(separator: ".").last.map(String.init) ?? bid
        }
        let c = item.category.lowercased()
        if c.contains("calendar") { return "Calendar" }
        if c.contains("media") { return "Media" }
        if c.contains("battery") { return "Battery" }
        if c.contains("reminder") { return "Reminders" }
        if c.contains("focus") { return "Focus" }
        return "Dynamo"
    }

    static func notificationsSettingsURL(bundleID: String? = nil) -> URL? {
        if let bundleID, !bundleID.isEmpty {
            let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encoded)") {
                return url
            }
        }
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    }

    static func openApp(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
