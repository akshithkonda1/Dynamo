import Combine
import Foundation

/// Thin facade over `DynamoNotificationAPI` for external tools (Shortcuts, scripts).
///
/// Preferred:
/// ```
/// name: com.akshithkonda.Dynamo.notify
/// userInfo: title, subtitle, urgency, category, image
/// ```
/// Legacy: `com.akshithkonda.Dynamo.externalPeek`  
/// URL: `dynamo://notify?title=…` or `dynamo://peek?title=…`
@MainActor
final class PeekBridge: ObservableObject {
    static let shared = PeekBridge()
    static let notificationName = DynamoNotificationAPI.legacyDistributedName

    private static let enabledKey = "dynamo.peekBridge.enabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private weak var registry: WidgetRegistry?

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    func attach(registry: WidgetRegistry) {
        self.registry = registry
        // Shared listener covers both modern + legacy distributed names.
        DynamoNotificationAPI.installExternalListeners()
    }

    func teardown() {
        DynamoNotificationAPI.removeExternalListeners()
    }

    func handle(userInfo: [String: Any]?) {
        guard isEnabled else { return }
        _ = DynamoNotificationAPI.postFromUserInfo(userInfo, defaultCategory: "external")
    }

    func handleURL(_ url: URL) {
        guard isEnabled else { return }
        _ = DynamoNotificationAPI.postFromURL(url)
    }
}
