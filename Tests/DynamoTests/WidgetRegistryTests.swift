import Combine
import SwiftUI
import XCTest
@testable import Dynamo

/// Exercises `WidgetRegistry`'s ordering / enable-disable / configuration
/// sanitization — the parts with real edge logic — using a side-effect-free
/// mock plugin so no timers, CoreLocation, or network start up.
@MainActor
final class WidgetRegistryTests: XCTestCase {

    // MARK: - Test doubles

    private final class MockPlugin: NotchWidgetPlugin {
        let id: String
        let displayName: String
        let systemImage = "circle"

        init(id: String) {
            self.id = id
            self.displayName = id
        }

        func collapsedView() -> AnyView { AnyView(EmptyView()) }
        func expandedView() -> AnyView { AnyView(EmptyView()) }
        // start()/stop() use the protocol's default no-op implementations.
    }

    private final class ConfigurableMockPlugin: NotchWidgetPlugin, WidgetSettingsProviding {
        let id: String
        let displayName: String
        let systemImage = "gear"

        init(id: String) {
            self.id = id
            self.displayName = id
        }

        func collapsedView() -> AnyView { AnyView(EmptyView()) }
        func expandedView() -> AnyView { AnyView(EmptyView()) }
        func settingsView() -> AnyView { AnyView(EmptyView()) }
    }

    private final class SneakPeekMockPlugin: NotchWidgetPlugin, NotchSneakPeekProviding {
        let id: String
        let displayName: String
        let systemImage = "bell"
        var onSneakPeek: ((NotchSneakPeek) -> Void)?

        init(id: String) {
            self.id = id
            self.displayName = id
        }

        func collapsedView() -> AnyView { AnyView(EmptyView()) }
        func expandedView() -> AnyView { AnyView(EmptyView()) }

        func fire(_ content: NotchSneakPeek) {
            onSneakPeek?(content)
        }
    }

    // MARK: - Tests

    func testRegisterMakesPluginVisibleAndActive() {
        let registry = WidgetRegistry()
        registry.register(MockPlugin(id: "a"))
        XCTAssertEqual(registry.plugins.map(\.id), ["a"])
        XCTAssertEqual(registry.activePluginID, "a")
    }

    func testDisableRemovesFromVisibleThenReenableRestores() {
        let registry = WidgetRegistry()
        registry.register(MockPlugin(id: "a"))
        registry.register(MockPlugin(id: "b"))

        registry.setEnabled("a", isEnabled: false)
        XCTAssertEqual(registry.plugins.map(\.id), ["b"])
        XCTAssertFalse(registry.isEnabled("a"))

        registry.setEnabled("a", isEnabled: true)
        XCTAssertEqual(Set(registry.plugins.map(\.id)), ["a", "b"])
        XCTAssertTrue(registry.isEnabled("a"))
    }

    func testApplyConfigurationSanitizesUnknownIDsAndAppendsMissing() {
        let registry = WidgetRegistry()
        registry.register(MockPlugin(id: "a"))
        registry.register(MockPlugin(id: "b"))
        registry.register(MockPlugin(id: "c"))

        registry.applyConfiguration(order: ["c", "a", "zzz"], enabledIDs: ["a", "c"])

        // Unknown "zzz" is dropped; the missing known id "b" is appended.
        XCTAssertEqual(registry.configurationSnapshot.order, ["c", "a", "b"])
        // Only enabled a & c are visible, in the sanitized order.
        XCTAssertEqual(registry.plugins.map(\.id), ["c", "a"])
    }

    func testApplyConfigurationEmptyEnabledFallsBackToAll() {
        let registry = WidgetRegistry()
        registry.register(MockPlugin(id: "a"))
        registry.register(MockPlugin(id: "b"))

        registry.applyConfiguration(order: ["a", "b"], enabledIDs: [])

        XCTAssertEqual(Set(registry.plugins.map(\.id)), ["a", "b"])
    }

    func testReorderRespectsProvidedOrder() {
        let registry = WidgetRegistry()
        registry.register(MockPlugin(id: "a"))
        registry.register(MockPlugin(id: "b"))
        registry.register(MockPlugin(id: "c"))

        registry.reorder(ids: ["c", "b", "a"])

        XCTAssertEqual(registry.plugins.map(\.id), ["c", "b", "a"])
    }

    func testSettingsSectionsOnlyIncludesConformers() {
        let registry = WidgetRegistry()
        registry.register(MockPlugin(id: "plain"))
        registry.register(ConfigurableMockPlugin(id: "cfg"))

        XCTAssertEqual(registry.settingsSections().map(\.id), ["cfg"])
    }

    func testSneakPeekRequestsAreForwardedThroughRegistry() {
        let registry = WidgetRegistry()
        let plugin = SneakPeekMockPlugin(id: "peeker")
        registry.register(plugin)

        var received: [NotchSneakPeek] = []
        let cancellable = registry.sneakPeekPublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        let content = NotchSneakPeek(systemImage: "music.note", title: "Song", subtitle: "Artist")
        plugin.fire(content)

        XCTAssertEqual(received, [content])
    }
}
