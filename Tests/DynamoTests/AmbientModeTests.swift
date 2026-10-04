import XCTest
@testable import Dynamo

/// Ambient mode: pill size, setting persistence, and waveform animate/settle.
///
/// Size and animation decisions live in the same functions the window / view
/// call (`NotchGeometry.collapsedSize`, `AmbientWaveform.shouldAnimate` via
/// `AmbientWaveformState`). Source guards fail if those call sites drift.
final class AmbientModeTests: XCTestCase {

    // MARK: - Pill size (width = notch + 2 cheeks, height = menu bar)

    func testAmbientPillSizeIsNotchPlusTwoCheeks() {
        let notch: CGFloat = 200
        let bar: CGFloat = 28
        let size = NotchGeometry.ambientPillSize(notchWidth: notch, menuBarHeight: bar)
        XCTAssertEqual(size.width, notch + NotchGeometry.ambientCheekWidth + NotchGeometry.ambientCheekWidth)
        XCTAssertEqual(size.height, bar)
    }

    func testAmbientPillSizeNilScreen() {
        let size = NotchGeometry.collapsedSize(ambientEnabled: true, isPlaying: true, screen: nil)
        XCTAssertEqual(
            size.width,
            NotchGeometry.fallbackNotchWidth + NotchGeometry.ambientCheekWidth + NotchGeometry.ambientCheekWidth,
            accuracy: 0.01
        )
        XCTAssertEqual(size.height, NotchGeometry.menuBarHeightFallback, accuracy: 0.01)
    }

    func testAmbientPillSizeFor16by10And3by2() {
        let displays: [(CGFloat, CGFloat, String)] = [
            (1440, 900, "16:10 1440×900"),
            (1680, 1050, "16:10 1680×1050"),
            (1470, 980, "3:2 1470×980"),
            (1440, 960, "3:2 1440×960")
        ]
        let expectedWidth = NotchGeometry.fallbackNotchWidth
            + NotchGeometry.ambientCheekWidth
            + NotchGeometry.ambientCheekWidth
        for (width, height, label) in displays {
            let size = NotchGeometry.ambientPillSize(screenWidth: width, screenHeight: height)
            XCTAssertEqual(size.width, expectedWidth, accuracy: 0.01, "\(label) width")
            XCTAssertEqual(size.height, NotchGeometry.menuBarHeightFallback, accuracy: 0.01, "\(label) height")
        }
    }

    func testCollapsedSizeUsesNormalNotchWhenAmbientOff() {
        let metrics = NotchGeometry.currentMetrics(for: nil)
        let offPlaying = NotchGeometry.collapsedSize(ambientEnabled: false, isPlaying: true, screen: nil)
        XCTAssertEqual(offPlaying.width, metrics.width, accuracy: 0.01)
        XCTAssertEqual(offPlaying.height, metrics.height, accuracy: 0.01)
    }

    func testCollapsedSizeUsesNormalNotchWhenNothingPlaying() {
        let metrics = NotchGeometry.currentMetrics(for: nil)
        let onIdle = NotchGeometry.collapsedSize(ambientEnabled: true, isPlaying: false, screen: nil)
        XCTAssertEqual(onIdle.width, metrics.width, accuracy: 0.01)
        XCTAssertEqual(onIdle.height, metrics.height, accuracy: 0.01)
    }

    func testCollapsedSizeUsesPillWhenOnAndPlaying() {
        let pill = NotchGeometry.collapsedSize(ambientEnabled: true, isPlaying: true, screen: nil)
        let normal = NotchGeometry.currentMetrics(for: nil)
        XCTAssertEqual(pill.height, NotchGeometry.menuBarHeightFallback, accuracy: 0.01)
        XCTAssertGreaterThan(pill.width, normal.width)
        XCTAssertTrue(AmbientMode.showsPill(ambientEnabled: true, isPlaying: true))
        XCTAssertFalse(AmbientMode.showsPill(ambientEnabled: false, isPlaying: true))
        XCTAssertFalse(AmbientMode.showsPill(ambientEnabled: true, isPlaying: false))
    }

    // MARK: - Setting default + persist

    @MainActor
    func testAmbientModeDefaultsOff() {
        let suiteName = "dynamo.tests.ambient.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = AmbientModeStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(defaults.object(forKey: AmbientModeStore.defaultsKey))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testAmbientModePersists() {
        let suiteName = "dynamo.tests.ambient.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = AmbientModeStore(defaults: defaults)
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: AmbientModeStore.defaultsKey))
        let restored = AmbientModeStore(defaults: defaults)
        XCTAssertTrue(restored.isEnabled)
        restored.setEnabled(false)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertFalse(AmbientModeStore(defaults: defaults).isEnabled)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Play / pause / reduce motion / sleep → animate

    func testShouldAnimateOnlyWhilePlayingAwakeAndMotionAllowed() {
        XCTAssertTrue(AmbientWaveform.shouldAnimate(isPlaying: true, reduceMotion: false, screenAsleep: false))
    }

    func testPauseStopsAnimation() {
        XCTAssertFalse(AmbientWaveform.shouldAnimate(isPlaying: false, reduceMotion: false, screenAsleep: false))
    }

    func testReduceMotionStopsAnimation() {
        XCTAssertFalse(AmbientWaveform.shouldAnimate(isPlaying: true, reduceMotion: true, screenAsleep: false))
    }

    func testScreenAsleepStopsAnimation() {
        XCTAssertFalse(AmbientWaveform.shouldAnimate(isPlaying: true, reduceMotion: false, screenAsleep: true))
    }

    func testViewModelAnimationFlagIsThePureFunction() {
        let cases: [(Bool, Bool, Bool)] = [
            (true, false, false),
            (false, false, false),
            (true, true, false),
            (true, false, true),
            (false, true, true)
        ]
        for (playing, reduce, asleep) in cases {
            let model = AmbientWaveformState(
                isPlaying: playing,
                reduceMotion: reduce,
                screenAsleep: asleep
            )
            XCTAssertEqual(
                model.shouldAnimate,
                AmbientWaveform.shouldAnimate(
                    isPlaying: playing,
                    reduceMotion: reduce,
                    screenAsleep: asleep
                )
            )
        }
    }

    func testTimelineIntervalIsThirtyFps() {
        XCTAssertEqual(1.0 / AmbientWaveform.timelineInterval, 30, accuracy: 0.01)
    }

    func testSettledBarsAreFlattened() {
        let heights = AmbientWaveform.barHeights(at: Date(), animate: false)
        XCTAssertEqual(heights.count, AmbientWaveform.barCount)
        for height in heights {
            XCTAssertGreaterThan(height, 0)
            XCTAssertLessThan(height, 0.4)
        }
    }

    func testAnimatedBarsVaryWithTime() {
        let a = AmbientWaveform.barHeights(at: Date(timeIntervalSinceReferenceDate: 0), animate: true)
        let b = AmbientWaveform.barHeights(at: Date(timeIntervalSinceReferenceDate: 0.45), animate: true)
        XCTAssertEqual(a.count, 5)
        XCTAssertFalse(a.elementsEqual(b))
    }

    // MARK: - Routing guards (fail if the view / window stop using the helpers)

    func testWaveformViewRoutesThroughShouldAnimate() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/AmbientWaveform.swift")
        XCTAssertTrue(
            text.contains("AmbientWaveform.shouldAnimate("),
            "AmbientWaveformState must call AmbientWaveform.shouldAnimate"
        )
        XCTAssertTrue(
            text.contains("model.shouldAnimate"),
            "AmbientWaveformView must decide TimelineView from the view-model flag"
        )
        XCTAssertTrue(text.contains("AmbientWaveformState("))
        XCTAssertTrue(text.contains("TimelineView"))
        XCTAssertFalse(text.contains("MusicAudioSampler"))
        XCTAssertFalse(text.contains("ScreenCaptureKit"))
        XCTAssertFalse(text.contains("SCStream"))
    }

    func testPillViewDoesNotCaptureSystemAudio() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/AmbientPillView.swift")
        XCTAssertFalse(text.contains("MusicAudioSampler"))
        XCTAssertFalse(text.contains("ScreenCaptureKit"))
        XCTAssertTrue(text.contains("AmbientWaveformView("))
    }

    func testWindowCollapsedSizeRoutesThroughGeometryDecision() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/NotchWindowController.swift")
        XCTAssertTrue(
            text.contains("NotchGeometry.collapsedSize("),
            "Window must size the closed island through NotchGeometry.collapsedSize"
        )
        XCTAssertTrue(text.contains("ambientEnabled:"))
        XCTAssertTrue(text.contains("isPlaying:"))
    }

    func testContentViewRoutesPillThroughShowsPill() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/NotchContentView.swift")
        XCTAssertTrue(
            text.contains("AmbientMode.showsPill("),
            "Collapsed chrome must use AmbientMode.showsPill — the same predicate collapsedSize uses"
        )
        XCTAssertTrue(text.contains("AmbientPillView()"))
    }

    func testGeometryCollapsedSizeUsesShowsPill() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/NotchGeometry.swift")
        XCTAssertTrue(text.contains("AmbientMode.showsPill("))
        XCTAssertTrue(text.contains("static func collapsedSize(ambientEnabled:"))
    }

    private func sourceFile(_ relative: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
