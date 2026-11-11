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
        XCTAssertNil(WeatherKitWeatherProvider.place(forTimeZone: "Mars/Olympus"))
    }
}

private struct DummyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
