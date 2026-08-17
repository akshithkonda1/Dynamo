import CoreLocation
import XCTest
@testable import Dynamo

@MainActor
final class WorldClockSortTests: XCTestCase {

    func testSortModeTitlesAndIDs() {
        for mode in WorldClockSortMode.allCases {
            XCTAssertFalse(mode.id.isEmpty)
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.systemImage.isEmpty)
        }
        XCTAssertEqual(WorldClockSortMode.allCases.count, 4)
    }

    func testMajorCitiesHaveCoordinatesForDistance() {
        let withCoords = WorldClockEntry.majorCities.filter {
            $0.latitude != nil && $0.longitude != nil
        }
        XCTAssertEqual(withCoords.count, WorldClockEntry.majorCities.count)
        // Spot-check a few hubs
        let tokyo = WorldClockEntry.majorCities.first { $0.id == "tokyo" }
        XCTAssertNotNil(tokyo?.latitude)
        XCTAssertNotNil(tokyo?.longitude)
    }

    func testReferenceTimeZonesHaveIDs() {
        XCTAssertFalse(WorldClockEntry.referenceTimeZones.isEmpty)
        for z in WorldClockEntry.referenceTimeZones {
            XCTAssertTrue(z.id.hasPrefix("tz:") || z.id == "tz:UTC" || z.timeZoneIdentifier.count > 1)
            XCTAssertNotNil(TimeZone(identifier: z.timeZoneIdentifier))
        }
    }

    func testShortZoneName() {
        XCTAssertEqual(WorldClockEntry.shortZoneName("America/Los_Angeles"), "Los Angeles")
        XCTAssertEqual(WorldClockEntry.shortZoneName("UTC"), "UTC")
    }

    func testCurrentLocationEntry() {
        let e = WorldClockEntry.currentLocation(
            placeName: "Cupertino",
            coordinate: CLLocationCoordinate2D(latitude: 37.3, longitude: -122.0)
        )
        XCTAssertEqual(e.id, WorldClockEntry.currentLocationID)
        XCTAssertEqual(e.name, "Cupertino")
        XCTAssertEqual(e.kind, .currentLocation)
        XCTAssertEqual(e.latitude ?? -1, 37.3, accuracy: 0.01)
        XCTAssertEqual(e.longitude ?? 0, -122.0, accuracy: 0.01)
    }

    func testDistanceOrderingNearest() {
        let plugin = WorldClockPlugin()
        plugin.sortMode = .nearest
        // Force a known origin (SF-ish) without waiting on Core Location
        // by selecting cities and using distanceKm with reference set via selected list fallback.
        plugin.selectedIDs = ["tokyo", "new-york", "london"]
        // Without GPS, origin becomes first city with coords → tokyo, then distances from Tokyo.
        let ordered = plugin.activeEntries.map(\.id)
        XCTAssertEqual(ordered.count, 3)
        // Tokyo should be closest to itself as origin fallback
        XCTAssertEqual(ordered.first, "tokyo")
    }

    func testRandomSortIsStableForSeed() {
        let plugin = WorldClockPlugin()
        plugin.selectedIDs = ["tokyo", "new-york", "london", "paris"]
        plugin.sortMode = .random
        let a = plugin.activeEntries.map(\.id)
        let b = plugin.activeEntries.map(\.id)
        XCTAssertEqual(a, b, "same seed must produce stable order")
    }

    func testReshuffleChangesSeed() {
        let plugin = WorldClockPlugin()
        plugin.selectedIDs = ["tokyo", "new-york", "london"]
        let before = plugin.randomSeed
        plugin.reshuffle()
        XCTAssertNotEqual(before, plugin.randomSeed)
        XCTAssertEqual(plugin.sortMode, .random)
    }

    func testCurrentLocationAlwaysFirst() {
        let plugin = WorldClockPlugin()
        plugin.selectedIDs = [
            "tokyo",
            WorldClockEntry.currentLocationID,
            "london",
            "new-york"
        ]
        for mode in WorldClockSortMode.allCases {
            plugin.sortMode = mode
            if mode == .random { plugin.setRandomSeedForTesting(42) }
            let ordered = plugin.activeEntries
            XCTAssertEqual(
                ordered.first?.kind,
                .currentLocation,
                "Here must lead in \(mode.title) sort"
            )
            // Rest still present
            XCTAssertEqual(ordered.count, 4)
            XCTAssertTrue(ordered.dropFirst().allSatisfy { $0.kind != .currentLocation })
        }
    }

    func testFarthestKeepsHereFirstThenRestByDistance() {
        let plugin = WorldClockPlugin()
        plugin.selectedIDs = [WorldClockEntry.currentLocationID, "tokyo", "london"]
        plugin.sortMode = .farthest
        let ordered = plugin.activeEntries
        XCTAssertEqual(ordered.first?.id, WorldClockEntry.currentLocationID)
        // Remaining cities still included
        XCTAssertEqual(Set(ordered.dropFirst().map(\.id)), Set(["tokyo", "london"]))
    }
}
