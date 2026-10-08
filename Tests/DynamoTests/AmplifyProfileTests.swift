import CoreAudio
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
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "reference"), .reference)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "symphony"), .symphony)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "presence"), .presence)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "cinema"), .cinema)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "impact"), .impact)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "dynamicSymphony"), .dynamicSymphony)
    }

    func testResolvedLegacyAliases() {
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "crisp"), .presence)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "balanced"), .cinema)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "visceral"), .impact)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "hifi"), .reference)
    }

    func testResolvedNilAndUnknownDefaultToSymphony() {
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: nil), .symphony)
        XCTAssertEqual(MediaAmplifyProfile.resolved(fromStored: "not-a-profile"), .symphony)
    }

    func testOnlyImpactAllowsStereoWidth() {
        XCTAssertFalse(MediaAmplifyProfile.reference.allowsStereoWidth)
        XCTAssertFalse(MediaAmplifyProfile.symphony.allowsStereoWidth)
        XCTAssertFalse(MediaAmplifyProfile.dynamicSymphony.allowsStereoWidth)
        XCTAssertTrue(MediaAmplifyProfile.impact.allowsStereoWidth)
    }

    func testReferenceIsFirstCase() {
        XCTAssertEqual(MediaAmplifyProfile.allCases.first, .reference)
        XCTAssertTrue(MediaAmplifyProfile.allCases.contains(.symphony))
        XCTAssertTrue(MediaAmplifyProfile.allCases.contains(.dynamicSymphony))
    }

    func testFidelityEnsembleNamesALeadAndStaysBounded() {
        let muddy = AmplifyToneAI.Features(
            bassRatio: 0.78, brightness: 0.35, crestDB: 9, zcr: 0.06,
            dynamicRangeDB: 10, speechLikelihood: 0.08, bandwidthHz: 9000, midRatio: 0.62
        )
        let harsh = AmplifyToneAI.Features(
            bassRatio: 0.4, brightness: 0.9, crestDB: 7, zcr: 0.22,
            dynamicRangeDB: 8, speechLikelihood: 0.2, bandwidthHz: 15000, midRatio: 0.4
        )
        for result in [FidelityModelEnsemble.evaluate(features: muddy), FidelityModelEnsemble.evaluate(features: harsh)] {
            XCTAssertFalse(result.lead.isEmpty)
            XCTAssertFalse(result.bias.isEmpty)
            for value in result.bias.values {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, -1.45)
                XCTAssertLessThanOrEqual(value, 1.15)
            }
        }
    }

    func testLiveDynamicBiasStaysFinite() {
        let dull = AmplifyToneAI.Features(
            bassRatio: 0.2, brightness: 0.15, crestDB: 6, zcr: 0.04,
            dynamicRangeDB: 8, speechLikelihood: 0.1, bandwidthHz: 8000, midRatio: 0.2
        )
        let harsh = AmplifyToneAI.Features(
            bassRatio: 0.7, brightness: 0.85, crestDB: 18, zcr: 0.2,
            dynamicRangeDB: 20, speechLikelihood: 0.7, bandwidthHz: 14000, midRatio: 0.15
        )
        for bias in [AmplifyToneAI.liveDynamicBias(features: dull), AmplifyToneAI.liveDynamicBias(features: harsh)] {
            XCTAssertFalse(bias.isEmpty)
            for value in bias.values {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, -1.4)
                XCTAssertLessThanOrEqual(value, 1.4)
            }
        }
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

    func testAtmosPathZeroesWidthAndHasLFE() {
        for profile in MediaAmplifyProfile.allCases {
            let atmos = DynamoEQCurves.curve(
                for: profile, device: .external, sampleRate: 48_000, path: .atmosBed
            )
            XCTAssertEqual(atmos.width, 0, "\(profile)")
            XCTAssertFalse(atmos.lfeFilters.isEmpty, "\(profile)")
            let spatial = DynamoEQCurves.curve(
                for: profile, device: .wireless, sampleRate: 48_000, path: .spatialBinaural
            )
            XCTAssertEqual(spatial.width, 0, "\(profile)")
        }
    }

    func testOnlyImpactHasWidthOnStereo() {
        let impact = DynamoEQCurves.curve(for: .impact, device: .headphones, sampleRate: 48_000, path: .stereo)
        let symphony = DynamoEQCurves.curve(for: .symphony, device: .headphones, sampleRate: 48_000, path: .stereo)
        let reference = DynamoEQCurves.curve(for: .reference, device: .auto, sampleRate: 48_000, path: .stereo)
        XCTAssertGreaterThan(impact.width, 0)
        XCTAssertEqual(symphony.width, 0)
        XCTAssertEqual(reference.width, 0)
        XCTAssertLessThanOrEqual(reference.makeup, pow(10.0, 0.25 / 20.0))
    }
}

final class AmplifySpatialPathTests: XCTestCase {
    func testDetectAtmosBedFromChannelCount() {
        let p = AmplifySpatialPath.detect(
            channels: 8, sampleRate: 48_000, contentImmersiveHint: true, deviceRaw: "external"
        )
        XCTAssertEqual(p, .atmosBed)
        XCTAssertTrue(p.usesLFERole)
        XCTAssertFalse(p.allowsMidSide)
        XCTAssertEqual(p.statusLabel, "Dolby Atmos bed")
    }

    func testDetectMultichannelWithoutHint() {
        let p = AmplifySpatialPath.detect(
            channels: 6, sampleRate: 48_000, contentImmersiveHint: false, deviceRaw: "external",
            sourceApp: ""
        )
        XCTAssertEqual(p, .multichannel)
    }

    func testStereoMixFallbackWhenTapIsStereoMix() {
        let p = AmplifySpatialPath.detect(
            channels: 2, sampleRate: 48_000, contentImmersiveHint: false,
            deviceRaw: "speakers", tapIsStereoMix: true
        )
        XCTAssertEqual(p, .stereoMixFallback)
        XCTAssertEqual(p.statusLabel, "stereo-mix fallback")
    }

    func testContentLooksImmersive() {
        XCTAssertTrue(AmplifySpatialPath.contentLooksImmersive(
            title: "Song", artist: "Artist", album: "Album (Dolby Atmos)"
        ))
        XCTAssertTrue(AmplifySpatialPath.contentLooksImmersive(
            title: "Track · Spatial Audio", artist: "", album: ""
        ))
        XCTAssertFalse(AmplifySpatialPath.contentLooksImmersive(
            title: "Plain Song", artist: "Band", album: "LP"
        ))
    }

    func testLFEFallbackRole() {
        XCTAssertEqual(AmplifyChannelLayout.fallbackRole(channel: 3, total: 6), .lfe)
        XCTAssertEqual(AmplifyChannelLayout.fallbackRole(channel: 0, total: 6), .fullRange)
        XCTAssertEqual(AmplifyChannelLayout.fallbackRole(channel: 5, total: 6), .surround)
    }

    func testMPEG51LayoutRoles() {
        let roles = AmplifyChannelLayout.roles(forLayoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        XCTAssertEqual(roles?.count, 6)
        XCTAssertEqual(roles?[3], AmplifyChannelRole.lfe)
    }
}
