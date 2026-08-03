import Foundation

/// Persists widget order + enabled flags in UserDefaults (small settings only).
@MainActor
final class WidgetSettingsStore {
    static let shared = WidgetSettingsStore()

    private let orderKey = "dynamo.widget.order"
    private let enabledKey = "dynamo.widget.enabled"

    private init() {}

    /// Widget ids that must never appear in production tray prefs (even if
    /// a previous build saved them).
    private static let productionExcludedIDs: Set<String> = ["weather"]

    func apply(to registry: WidgetRegistry) {
        let defaults = UserDefaults.standard
        let order = (defaults.stringArray(forKey: orderKey) ?? [])
            .filter { !Self.productionExcludedIDs.contains($0) }
        let enabledArray = defaults.stringArray(forKey: enabledKey)
        let enabled: Set<String>
        if let enabledArray {
            enabled = Set(enabledArray).subtracting(Self.productionExcludedIDs)
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
        let order = snap.order.filter { !Self.productionExcludedIDs.contains($0) }
        let enabled = snap.enabled.subtracting(Self.productionExcludedIDs)
        UserDefaults.standard.set(order, forKey: orderKey)
        UserDefaults.standard.set(Array(enabled), forKey: enabledKey)
    }

    /// Remove excluded ids from the live registry configuration and disk.
    func stripDisabledWidgets(from registry: WidgetRegistry, ids: [String]) {
        let ban = Set(ids).union(Self.productionExcludedIDs)
        let snap = registry.configurationSnapshot
        let order = snap.order.filter { !ban.contains($0) }
        let enabled = snap.enabled.subtracting(ban)
        registry.applyConfiguration(order: order, enabledIDs: enabled)
        persist(from: registry)
    }
}
