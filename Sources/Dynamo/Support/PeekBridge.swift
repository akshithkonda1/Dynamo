import Combine
import Foundation

/// Opt-in critical peek channel for external tools (Shortcuts, scripts).
///
/// Post a distributed notification:
/// ```
/// name: com.akshithkonda.Dynamo.externalPeek
/// userInfo: title, subtitle (optional), critical (Bool, default true)
/// ```
/// Or open `dynamo://peek?title=...&subtitle=...`
@MainActor
final class PeekBridge: ObservableObject {
    static let shared = PeekBridge()
    static let notificationName = Notification.Name("com.akshithkonda.Dynamo.externalPeek")

    private static let enabledKey = "dynamo.peekBridge.enabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private var observer: NSObjectProtocol?
    private weak var registry: WidgetRegistry?

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = false
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    func attach(registry: WidgetRegistry) {
        self.registry = registry
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handle(userInfo: note.userInfo as? [String: Any])
            }
        }
    }

    func teardown() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    func handle(userInfo: [String: Any]?) {
        guard isEnabled else { return }
        let title = (userInfo?["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }
        let subtitle = (userInfo?["subtitle"] as? String) ?? ""
        let critical: Bool
        if let b = userInfo?["critical"] as? Bool {
            critical = b
        } else if let s = userInfo?["critical"] as? String {
            critical = (s as NSString).boolValue
        } else {
            critical = true
        }
        registry?.sneakPeekPublisher.send(
            NotchSneakPeek(
                systemImage: critical ? "bell.badge.fill" : "bell",
                title: title,
                subtitle: subtitle,
                emphasis: critical ? .critical : .normal
            )
        )
    }

    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "dynamo" else { return }
        guard url.host?.lowercased() == "peek" else { return }
        var info: [String: Any] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                if let v = item.value {
                    info[item.name] = v
                }
            }
        }
        handle(userInfo: info)
    }
}
