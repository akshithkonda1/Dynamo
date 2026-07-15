import AppKit
import Foundation

/// Which screen hosts the notch panel. Persisted by display UUID (stable across
/// reconnects when available) with a fall-back to automatic notched/main pick.
@MainActor
enum DisplayPreference {
    private static let key = "dynamo.preferredDisplayID"

    /// Empty string / missing = automatic.
    static var preferredDisplayID: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: key)
            NotificationCenter.default.post(name: .dynamoPreferredDisplayDidChange, object: nil)
        }
    }

    static func resolveScreen() -> NSScreen? {
        if let id = preferredDisplayID,
           let match = NSScreen.screens.first(where: { displayID(of: $0) == id }) {
            return match
        }
        // Automatic: prefer a notched display, else main.
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> String {
        // NSScreen.deviceDescription["NSScreenNumber"] is the CGDirectDisplayID.
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return String(num.uint32Value)
        }
        return screen.localizedName
    }

    static func label(for screen: NSScreen) -> String {
        let name = screen.localizedName
        let notched = screen.safeAreaInsets.top > 0
        let main = screen == NSScreen.main
        var tags: [String] = []
        if main { tags.append("Main") }
        if notched { tags.append("Notch") }
        if tags.isEmpty { return name }
        return "\(name) (\(tags.joined(separator: ", ")))"
    }
}

extension Notification.Name {
    static let dynamoPreferredDisplayDidChange = Notification.Name("dynamoPreferredDisplayDidChange")
}
