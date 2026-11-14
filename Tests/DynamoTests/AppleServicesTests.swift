import XCTest
@testable import Dynamo

final class AppleServicesTests: XCTestCase {
    func testNativePermissionsAreListed() {
        let ids = DynamoPermission.allCases.map(\.rawValue)
        XCTAssertTrue(ids.contains("musicKit"))
        XCTAssertTrue(ids.contains("contacts"))
        XCTAssertTrue(ids.contains("appleFocus"))
        XCTAssertTrue(ids.contains("calendar"))
        XCTAssertTrue(ids.contains("reminders"))
    }

    func testMusicKitIsCoreAndNotesAutomationIsNot() {
        XCTAssertTrue(DynamoPermission.musicKit.isRequiredForCore)
        XCTAssertTrue(DynamoPermission.calendar.isRequiredForCore)
        XCTAssertFalse(DynamoPermission.automationNotes.isRequiredForCore)
        XCTAssertFalse(DynamoPermission.automationSpotify.isRequiredForCore)
    }
}
