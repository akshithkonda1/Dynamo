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
        XCTAssertTrue(ids.contains("automationMusic"))
        XCTAssertTrue(ids.contains("dynamoControls"))
    }

    func testAllowablePermissionsHaveInAppRequests() {
        let settingsOnly: Set<DynamoPermission> = [.fullDiskAccess, .notificationMirror]
        for permission in DynamoPermission.allCases where !settingsOnly.contains(permission) {
            XCTAssertFalse(permission.displayName.isEmpty)
        }
        XCTAssertTrue(DynamoPermission.musicKit.detail.localizedCaseInsensitiveContains("MusicKit"))
        XCTAssertTrue(DynamoPermission.automationMusic.detail.localizedCaseInsensitiveContains("Control Music"))
        XCTAssertTrue(DynamoPermission.dynamoControls.detail.localizedCaseInsensitiveContains("Accessibility"))
    }

    func testMusicKitIsCoreAndNotesAutomationIsNot() {
        XCTAssertTrue(DynamoPermission.musicKit.isRequiredForCore)
        XCTAssertTrue(DynamoPermission.calendar.isRequiredForCore)
        XCTAssertTrue(DynamoPermission.automationMusic.isRequiredForCore)
        XCTAssertTrue(DynamoPermission.dynamoControls.isRequiredForCore)
        XCTAssertFalse(DynamoPermission.automationNotes.isRequiredForCore)
        XCTAssertFalse(DynamoPermission.automationSpotify.isRequiredForCore)
        XCTAssertFalse(DynamoPermission.location.isRequiredForCore)
        XCTAssertFalse(DynamoPermission.camera.isRequiredForCore)
    }

    func testAppleMusicFamilyHoldsMusicKitAndControlMusicSeparatelyFromDynamoControls() {
        XCTAssertEqual(DynamoPermission.musicKit.family, .appleMusic)
        XCTAssertEqual(DynamoPermission.automationMusic.family, .appleMusic)
        XCTAssertEqual(Set(PermissionFamily.appleMusic.members), [.musicKit, .automationMusic])
        XCTAssertEqual(DynamoPermission.dynamoControls.family, .dynamoControls)
        XCTAssertEqual(PermissionFamily.dynamoControls.members, [.dynamoControls])
    }

    func testOnboardingFamiliesCoverEveryPermissionUpFront() {
        let covered = Set((PermissionFamily.core + PermissionFamily.optional).flatMap(\.members))
        XCTAssertEqual(covered, Set(DynamoPermission.allCases))
        XCTAssertTrue(Set(PermissionFamily.core).isDisjoint(with: PermissionFamily.optional))
        XCTAssertEqual(
            PermissionFamily.core.count + PermissionFamily.optional.count,
            PermissionFamily.allCases.count
        )
    }

    func testSettingsRowsPromptOrOpenSystemSettings() {
        XCTAssertTrue(DynamoPermission.fullDiskAccess.requiresSystemSettingsPane)
        XCTAssertTrue(DynamoPermission.notificationMirror.requiresSystemSettingsPane)
        XCTAssertFalse(DynamoPermission.musicKit.requiresSystemSettingsPane)
        XCTAssertTrue(DynamoPermission.musicKit.showsAllow(for: .notDetermined))
        XCTAssertFalse(DynamoPermission.musicKit.showsAllow(for: .granted))
        XCTAssertFalse(DynamoPermission.musicKit.showsAllow(for: .denied))
        XCTAssertTrue(DynamoPermission.musicKit.showsOpenSettings(for: .denied))
        XCTAssertTrue(DynamoPermission.musicKit.showsOpenSettings(for: .granted))
        XCTAssertFalse(DynamoPermission.musicKit.showsOpenSettings(for: .notDetermined))
        XCTAssertEqual(DynamoPermission.calendar.openSettingsTitle(for: .granted), "Change")
        XCTAssertEqual(DynamoPermission.calendar.openSettingsTitle(for: .denied), "Open Settings")
        XCTAssertTrue(DynamoPermission.dynamoControls.canRePromptWhenDenied)
        XCTAssertTrue(DynamoPermission.dynamoControls.showsAllow(for: .denied))
        XCTAssertTrue(DynamoPermission.automationMusic.showsAllow(for: .denied))
    }
}
