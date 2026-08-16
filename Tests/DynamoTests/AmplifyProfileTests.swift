import XCTest
@testable import Dynamo

final class AmplifyProfileTests: XCTestCase {

    func testAllProfilesHaveStableIDs() {
        for p in MediaAmplifyProfile.allCases {
            XCTAssertFalse(p.id.isEmpty)
            XCTAssertEqual(p.id, p.rawValue)
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertFalse(p.subtitle.isEmpty)
            XCTAssertFalse(p.systemImage.isEmpty)
        }
    }

    func testResolvedKnownRawValues() {
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "symphony"), .symphony)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "presence"), .presence)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "cinema"), .cinema)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "impact"), .impact)
    }

    func testResolvedLegacyAliases() {
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "crisp"), .presence)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "balanced"), .cinema)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "visceral"), .impact)
    }

    func testResolvedNilAndUnknownDefaultToSymphony() {
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: nil), .symphony)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "not-a-profile"), .symphony)
    }

    func testSymphonyIsDefaultAdaptiveProfile() {
        XCTAssertTrue(MediaAmplifyProfile.allCases.contains(.symphony))
        XCTAssertEqual(MediaAmplifyProfile.allCases.first, .symphony)
    }
}

final class AmplifyDeviceTests: XCTestCase {

    func testInferWirelessFromAirPods() {
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "Akshith’s AirPods Pro"), .wireless)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "Bluetooth Headset"), .wireless)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "Beats Solo"), .wireless)
    }

    func testInferWiredHeadphones() {
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "External Headphones"), .headphones)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "USB Headset"), .headphones)
    }

    func testInferBuiltInSpeakers() {
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "MacBook Pro Speakers"), .speakers)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "Built-in Output"), .speakers)
    }

    func testInferExternal() {
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "LG UltraFine Display"), .external)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "USB Audio DAC"), .external)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "HomePod mini"), .external)
    }

    func testInferNilOrEmptyIsAuto() {
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: nil), .auto)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: ""), .auto)
        XCTAssertEqual(AmplifyOutputDevice.infer(fromDeviceName: "Mysterious Device XYZ"), .auto)
    }

    func testEmbeddedCurvesProduceFilters() {
        for profile in MediaAmplifyProfile.allCases {
            for device in AmplifyOutputDevice.allCases {
                let built = DynamoEQCurves.filters(for: profile, device: device, sampleRate: 48_000)
                XCTAssertFalse(built.filters.isEmpty, "\(profile) \(device)")
                XCTAssertGreaterThan(built.makeup, 0)
                XCTAssertGreaterThanOrEqual(built.width, 0)
                XCTAssertLessThanOrEqual(built.width, 0.5)
                // Process a sample without exploding
                var y: Float = 0.2
                for f in built.filters {
                    y = f.process(y)
                }
                y *= built.makeup
                XCTAssertTrue(y.isFinite)
            }
        }
    }
}
