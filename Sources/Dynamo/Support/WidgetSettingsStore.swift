import Foundation

/// Persists widget order + enabled flags in UserDefaults (small settings only).
@MainActor
final class WidgetSettingsStore {
    static let shared = WidgetSettingsStore()

    private let orderKey = "dynamo.widget.order"
    private let enabledKey = "dynamo.widget.enabled"

    private init() {}

    func apply(to registry: WidgetRegistry) {
        let defaults = UserDefaults.standard
        let order = defaults.stringArray(forKey: orderKey) ?? []
        let enabledArray = defaults.stringArray(forKey: enabledKey)
        let enabled: Set<String>
        if let enabledArray {
            enabled = Set(enabledArray)
        } else {
            // First launch: enable everything currently registered.
            enabled = Set(registry.allRegistered.map(\.id))
        }
        if !order.isEmpty || enabledArray != nil {
            registry.applyConfiguration(order: order, enabledIDs: enabled)
        }
    }

    func persist(from registry: WidgetRegistry) {
        let snap = registry.configurationSnapshot
        UserDefaults.standard.set(snap.order, forKey: orderKey)
        UserDefaults.standard.set(Array(snap.enabled), forKey: enabledKey)
    }
}
