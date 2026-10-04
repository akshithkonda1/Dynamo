import SwiftUI
import XCTest
@testable import Dynamo

/// Claim (1) — every registered widget stays reachable from the top-band tab
/// row, including when the compact panel overflows and the cheeks scroll:
/// `testProductionRegistryPluginsAreAllReachable`,
/// `testOverflowDoesNotDropPlugins`,
/// `testTabRowNeverDropsAVisiblePlugin`.
@MainActor
final class NotchTabRowTests: XCTestCase {

    private final class MockPlugin: NotchWidgetPlugin {
        let id: String
        let displayName: String
        let systemImage = "circle"

        init(id: String) {
            self.id = id
            self.displayName = id
        }

        func expandedView() -> AnyView { AnyView(EmptyView()) }
    }

    private func register(_ ids: [String]) -> WidgetRegistry {
        let registry = WidgetRegistry()
        for id in ids {
            registry.register(MockPlugin(id: id))
        }
        return registry
    }

    func testProductionRegistryPluginsAreAllReachable() {
        let registry = register(NotchTabRow.productionRegisteredIDs)
        let visible = Set(registry.plugins.map(\.id))
        let reachable = Set(NotchTabRow.reachableIDs(from: registry.plugins))

        XCTAssertEqual(visible.count, NotchTabRow.productionRegisteredIDs.count)
        XCTAssertEqual(visible, Set(NotchTabRow.productionRegisteredIDs))
        XCTAssertEqual(
            reachable,
            visible,
            "Tab row dropped a production plugin — every AppDelegate-registered widget must stay in the top band"
        )
        for id in NotchTabRow.productionRegisteredIDs {
            XCTAssertTrue(reachable.contains(id), "\(id) is not in the tab row")
        }
    }

    func testOverflowDoesNotDropPlugins() {
        // Compact ~555pt panel cannot show 13+ icons at once. Cheeks scroll;
        // membership must still include every visible plugin — including
        // Weather (ships but is not in the production tray) and extras.
        var ids = NotchTabRow.productionRegisteredIDs
        ids.append(contentsOf: ["weather", "extra-a", "extra-b", "extra-c"])
        let registry = register(ids)

        let visible = registry.plugins.map(\.id)
        let reachable = NotchTabRow.reachableIDs(from: registry.plugins)

        XCTAssertEqual(visible.count, ids.count)
        XCTAssertEqual(
            Set(reachable),
            Set(visible),
            "Overflow / scroll path dropped a plugin instead of keeping it in a scrollable cheek"
        )
        XCTAssertTrue(reachable.contains("weather"))
        XCTAssertTrue(reachable.contains("extra-c"))
        XCTAssertFalse(
            reachable.contains("gearshape"),
            "Settings is chrome, not a registered plugin"
        )
    }

    func testTabRowNeverDropsAVisiblePlugin() {
        let registry = register(NotchTabRow.productionRegisteredIDs)
        let leading = NotchTabRow.leading(from: registry.plugins).map(\.id)
        let trailing = NotchTabRow.trailing(from: registry.plugins).map(\.id)

        XCTAssertEqual(Set(leading).intersection(trailing).count, 0)
        XCTAssertEqual(Set(leading + trailing), Set(registry.plugins.map(\.id)))

        for id in NotchTabRow.trailingIDs {
            XCTAssertTrue(trailing.contains(id), "trailing cluster missing \(id)")
            XCTAssertFalse(leading.contains(id), "\(id) listed on both cheeks")
        }
        XCTAssertTrue(leading.contains("media"))
        XCTAssertTrue(leading.contains("calendar"))
        XCTAssertTrue(leading.contains("battery"))
    }
}
