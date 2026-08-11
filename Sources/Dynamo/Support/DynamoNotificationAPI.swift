import AppKit
import Foundation

/// **Dynamo Notification API** — the single supported way to post alerts into
/// the notch Peek (and to receive mirrored system notifications).
///
/// ### Sources
/// | Path | How |
/// |------|-----|
/// | Swift | `DynamoNotificationAPI.post(...)` |
/// | URL | `dynamo://notify?title=…&subtitle=…&urgency=high` |
/// | URL (alias) | `dynamo://peek?title=…` |
/// | Distributed | `com.akshithkonda.Dynamo.notify` userInfo |
/// | Distributed (legacy) | `com.akshithkonda.Dynamo.externalPeek` |
/// | System apps | `SystemNotificationMirror` → this API |
/// | Widgets | `onSneakPeek` / registry → PeekNotificationCenter |
///
/// Always **EQ-safe**: never touches system volume. Delivery is queued, coalesced,
/// and presented by `PeekNotificationCenter`.
@MainActor
enum DynamoNotificationAPI {
    /// Preferred distributed notification name for external posters.
    static let distributedName = Notification.Name("com.akshithkonda.Dynamo.notify")
    /// Legacy name (PeekBridge).
    static let legacyDistributedName = Notification.Name("com.akshithkonda.Dynamo.externalPeek")

    struct Payload: Equatable {
        var title: String
        var subtitle: String = ""
        var detail: String = ""
        var systemImage: String = "bell.fill"
        var urgency: NotchSneakPeekUrgency = .normal
        var category: String = "api"
        var id: String? = nil
        var coalesce: Bool = true

        var asPeek: NotchSneakPeek {
            NotchSneakPeek(
                systemImage: systemImage,
                title: title,
                subtitle: subtitle,
                urgency: urgency,
                detail: detail
            )
        }
    }

    // MARK: - Post

    /// Post any notification into the Peek queue.
    static func post(_ payload: Payload) {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var p = payload
        p.title = title
        PeekNotificationCenter.shared.deliver(
            p.asPeek,
            id: p.id ?? "api|\(p.category)|\(p.title)|\(p.subtitle)",
            category: p.category,
            coalesce: p.coalesce
        )
    }

    static func post(
        title: String,
        subtitle: String = "",
        detail: String = "",
        systemImage: String = "bell.fill",
        urgency: NotchSneakPeekUrgency = .normal,
        category: String = "api",
        id: String? = nil
    ) {
        post(Payload(
            title: title,
            subtitle: subtitle,
            detail: detail,
            systemImage: systemImage,
            urgency: urgency,
            category: category,
            id: id
        ))
    }

    // MARK: - URL

    /// `dynamo://notify?title=Hello&subtitle=World&urgency=high&category=mail&image=envelope`
    @discardableResult
    static func postFromURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "dynamo" else { return false }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
        guard host == "notify" || host == "peek" || host == "notification" else {
            return false
        }
        var info: [String: Any] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                if let v = item.value { info[item.name.lowercased()] = v }
            }
        }
        return postFromUserInfo(info, defaultCategory: host == "peek" ? "external" : "api")
    }

    // MARK: - Distributed / userInfo

    @discardableResult
    static func postFromUserInfo(
        _ userInfo: [String: Any]?,
        defaultCategory: String = "api"
    ) -> Bool {
        guard let userInfo else { return false }
        let title = string(userInfo, keys: ["title", "t"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return false }

        let subtitle = string(userInfo, keys: ["subtitle", "body", "message", "s"]) ?? ""
        let detail = string(userInfo, keys: ["detail", "app", "source", "d"]) ?? ""
        let image = string(userInfo, keys: ["image", "systemimage", "icon", "i"]) ?? "bell.fill"
        let category = string(userInfo, keys: ["category", "cat", "c"]) ?? defaultCategory
        let id = string(userInfo, keys: ["id", "uuid", "identifier"])

        let urgency: NotchSneakPeekUrgency
        if let u = string(userInfo, keys: ["urgency", "priority", "u"])?.lowercased() {
            switch u {
            case "critical", "3", "max": urgency = .critical
            case "high", "2": urgency = .high
            case "low", "0": urgency = .low
            default: urgency = .normal
            }
        } else if let critical = bool(userInfo, keys: ["critical"]) {
            urgency = critical ? .critical : .normal
        } else {
            urgency = .normal
        }

        post(Payload(
            title: title,
            subtitle: subtitle,
            detail: detail.isEmpty ? "API" : detail,
            systemImage: image,
            urgency: urgency,
            category: category,
            id: id
        ))
        return true
    }

    // MARK: - Listeners (external)

    private static var distributedObservers: [NSObjectProtocol] = []
    private static var didInstallListeners = false

    /// Install once at app launch — accepts both modern and legacy distributed names.
    static func installExternalListeners() {
        guard !didInstallListeners else { return }
        didInstallListeners = true
        let center = DistributedNotificationCenter.default()
        for name in [distributedName, legacyDistributedName] {
            let obs = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { note in
                Task { @MainActor in
                    _ = postFromUserInfo(note.userInfo as? [String: Any], defaultCategory: "external")
                }
            }
            distributedObservers.append(obs)
        }
    }

    static func removeExternalListeners() {
        let center = DistributedNotificationCenter.default()
        for obs in distributedObservers {
            center.removeObserver(obs)
        }
        distributedObservers.removeAll()
        didInstallListeners = false
    }

    // MARK: - Helpers

    private static func string(_ info: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = info[k] as? String { return s }
            // Case-insensitive key match
            if let pair = info.first(where: { $0.key.lowercased() == k.lowercased() }) {
                if let s = pair.value as? String { return s }
                if let n = pair.value as? NSNumber { return n.stringValue }
            }
        }
        return nil
    }

    private static func bool(_ info: [String: Any], keys: [String]) -> Bool? {
        for k in keys {
            if let b = info[k] as? Bool { return b }
            if let s = info[k] as? String {
                return (s as NSString).boolValue
            }
            if let pair = info.first(where: { $0.key.lowercased() == k.lowercased() }) {
                if let b = pair.value as? Bool { return b }
                if let s = pair.value as? String { return (s as NSString).boolValue }
            }
        }
        return nil
    }
}
