import XCTest
@testable import Dynamo

final class WeatherErrorTextTests: XCTestCase {
    func testFriendlyMessageMapsEntitlementAndNetwork() {
        XCTAssertTrue(
            WeatherKitWeatherProvider.friendlyMessage(for: DummyError("missing entitlement"))
                .localizedCaseInsensitiveContains("WeatherKit")
        )
        XCTAssertTrue(
            WeatherKitWeatherProvider.friendlyMessage(for: DummyError("The Internet connection appears to be offline."))
                .localizedCaseInsensitiveContains("network")
        )
        XCTAssertTrue(
            WeatherKitWeatherProvider.friendlyMessage(for: DummyError("something else"))
                .contains("something else")
        )
    }

    func testTimeZoneGuessesACity() {
        XCTAssertEqual(WeatherKitWeatherProvider.place(forTimeZone: "America/Chicago")?.name, "Chicago")
        XCTAssertEqual(WeatherKitWeatherProvider.place(forTimeZone: "Pacific/Honolulu")?.name, "Honolulu")
        XCTAssertEqual(WeatherKitWeatherProvider.place(forTimeZone: "US/Central")?.name, "Chicago")
        XCTAssertNil(WeatherKitWeatherProvider.place(forTimeZone: "Mars/Olympus"))
        let fallback = WeatherKitWeatherProvider.fallbackPlace()
        XCTAssertFalse(fallback.name.isEmpty)
        XCTAssertNotEqual(fallback.latitude, 0, accuracy: 0.0001)
    }
}

private struct DummyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
