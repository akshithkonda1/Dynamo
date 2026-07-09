import Combine
import Foundation
import SwiftUI

/// Owns the ordered list of widget plugins and which one is currently focused
/// in the expanded tray. Does not special-case any widget by name.
@MainActor
final class WidgetRegistry: ObservableObject {
    @Published private(set) var plugins: [any NotchWidgetPlugin] = []
    @Published var activePluginID: String?

    private var allPlugins: [String: any NotchWidgetPlugin] = [:]
    private var order: [String] = []
    private var enabled: Set<String> = []

    var activePlugin: (any NotchWidgetPlugin)? {
        guard let activePluginID else { return plugins.first }
        return plugins.first { $0.id == activePluginID } ?? plugins.first
    }

    func register(_ plugin: any NotchWidgetPlugin) {
        allPlugins[plugin.id] = plugin
        if !order.contains(plugin.id) {
            order.append(plugin.id)
        }
        enabled.insert(plugin.id)
        rebuildVisible()
        plugin.start()
    }

    /// Replaces the visible set from persisted settings without knowing widget names.
    func applyConfiguration(order: [String], enabledIDs: Set<String>) {
        let known = Set(allPlugins.keys)
        let sanitizedOrder = order.filter { known.contains($0) }
        let missing = known.subtracting(sanitizedOrder)
        self.order = sanitizedOrder + missing.sorted()
        self.enabled = enabledIDs.intersection(known)
        if self.enabled.isEmpty {
            self.enabled = known
        }
        rebuildVisible()
        if let active = activePluginID, !self.enabled.contains(active) {
            activePluginID = plugins.first?.id
        }
    }

    func setEnabled(_ id: String, isEnabled: Bool) {
        guard allPlugins[id] != nil else { return }
        if isEnabled {
            enabled.insert(id)
            allPlugins[id]?.start()
        } else {
            enabled.remove(id)
            allPlugins[id]?.stop()
        }
        rebuildVisible()
        if activePluginID == id {
            activePluginID = plugins.first?.id
        }
        NotificationCenter.default.post(name: .dynamoWidgetConfigurationDidChange, object: self)
    }

    func movePlugin(fromOffsets: IndexSet, toOffset: Int) {
        var visibleIDs = plugins.map(\.id)
        visibleIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // Rebuild full order: visible order first, then disabled in prior relative order.
        let disabled = order.filter { !enabled.contains($0) }
        order = visibleIDs + disabled
        rebuildVisible()
        NotificationCenter.default.post(name: .dynamoWidgetConfigurationDidChange, object: self)
    }

    func reorder(ids: [String]) {
        let known = Set(allPlugins.keys)
        let sanitized = ids.filter { known.contains($0) }
        let missing = order.filter { !sanitized.contains($0) }
        order = sanitized + missing
        rebuildVisible()
        NotificationCenter.default.post(name: .dynamoWidgetConfigurationDidChange, object: self)
    }

    func isEnabled(_ id: String) -> Bool {
        enabled.contains(id)
    }

    var configurationSnapshot: (order: [String], enabled: Set<String>) {
        (order, enabled)
    }

    var allRegistered: [(id: String, name: String, enabled: Bool)] {
        order.compactMap { id in
            guard let plugin = allPlugins[id] else { return nil }
            return (id, plugin.displayName, enabled.contains(id))
        }
    }

    func stopAll() {
        for plugin in allPlugins.values {
            plugin.stop()
        }
    }

    /// Forwards file drops to every enabled widget that opts into `FileDropAccepting`.
    /// Returns true if at least one acceptor handled the drop.
    @discardableResult
    func dispatchFileDrop(urls: [URL]) -> Bool {
        var firstAcceptorID: String?
        var handled = false
        for plugin in plugins {
            guard let acceptor = plugin as? any FileDropAccepting else { continue }
            acceptor.handleFileDrop(urls: urls)
            if firstAcceptorID == nil { firstAcceptorID = plugin.id }
            handled = true
        }
        if let firstAcceptorID {
            activePluginID = firstAcceptorID
        }
        return handled
    }

    private func rebuildVisible() {
        plugins = order.compactMap { id in
            guard enabled.contains(id) else { return nil }
            return allPlugins[id]
        }
        if activePluginID == nil || !(enabled.contains(activePluginID ?? "")) {
            activePluginID = plugins.first?.id
        }
    }
}

extension Notification.Name {
    static let dynamoWidgetConfigurationDidChange = Notification.Name("dynamoWidgetConfigurationDidChange")
}
