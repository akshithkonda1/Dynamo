import XCTest
@testable import Dynamo

/// Pure geometry math — no windowing, no network.
///
/// Claim (2) — expanded island stays a compact hanging card:
/// `testExpandedPanelFitsLaptop16by10`, `testExpandedPanelFitsLargeExternal`,
/// `testExpandedWidthIsCompactNotBanner`, `testExpandedChromePlusCardStaysUnderCap`,
/// `testProductionPluginHeightsFitCapForEveryState`.
@MainActor
final class NotchGeometryTests: XCTestCase {

    private let laptopDisplays: [(CGFloat, CGFloat)] = [
        (1440, 900),
        (1680, 1050),
        (1920, 1200)
    ]

    private let externalDisplays: [(CGFloat, CGFloat)] = [
        (2560, 1440),
        (3840, 2160)
    ]

    func testExpandedWidthNilScreenUsesFallback() {
        let w = NotchGeometry.expandedWidth(for: nil)
        XCTAssertEqual(w, NotchGeometry.expandedWidthFallback, accuracy: 0.5)
    }

    func testExpandedWidthRespectsFloorAndCap() {
        XCTAssertGreaterThanOrEqual(NotchGeometry.fallbackWidth, 100)
        let nilW = NotchGeometry.expandedWidth(for: nil)
        XCTAssertGreaterThanOrEqual(nilW, NotchGeometry.expandedWidthFloor)
        XCTAssertLessThanOrEqual(nilW, NotchGeometry.expandedWidthCap)
    }

    func testExpandedContentHeightNilUsesBase() {
        let h = NotchGeometry.expandedContentHeight(base: NotchTheme.expandedContentBase, for: nil)
        XCTAssertEqual(h, NotchTheme.expandedContentBase, accuracy: 0.5)
    }

    func testExpandedWidthIsCompactNotBanner() {
        // Owner target ~555pt; 38% of a 1470pt display ≈ 559pt.
        XCTAssertEqual(NotchGeometry.expandedWidthFallback, 555, accuracy: 0.5)
        XCTAssertEqual(NotchGeometry.expandedWidth(screenWidth: 1470, screenHeight: 956), 559, accuracy: 1)
        XCTAssertGreaterThanOrEqual(NotchGeometry.expandedWidthFloor, 480)
        XCTAssertLessThanOrEqual(NotchGeometry.expandedWidthCap, 680)
    }

    func testExpandedPanelSizeNilScreenMatchesOwnerTarget() {
        let size = NotchGeometry.expandedPanelSize(
            contentBase: NotchTheme.expandedContentBase,
            for: nil
        )
        XCTAssertEqual(size.width, NotchGeometry.expandedWidthFallback, accuracy: 0.5)
        XCTAssertEqual(size.height, NotchGeometry.expandedPanelHeightTarget, accuracy: 0.5)
        XCTAssertEqual(size.height, 200, accuracy: 0.5)
    }

    func testExpandedPanelSizeMatchesWidthAndHeightHelpers() {
        let samples: [(CGFloat, CGFloat)] = laptopDisplays + externalDisplays
        for (width, height) in samples {
            let size = NotchGeometry.expandedPanelSize(
                contentBase: NotchTheme.expandedContentBase,
                screenWidth: width,
                screenHeight: height
            )
            XCTAssertEqual(
                size.width,
                NotchGeometry.expandedWidth(screenWidth: width, screenHeight: height),
                accuracy: 0.5
            )
            XCTAssertEqual(
                size.height,
                NotchGeometry.expandedPanelHeight(
                    contentBase: NotchTheme.expandedContentBase,
                    screenHeight: height
                ),
                accuracy: 0.5
            )
        }
    }

    func testExpandedChromePlusCardStaysUnderCap() {
        XCTAssertEqual(NotchTheme.expandedChromeHeight, 56, accuracy: 0.5)
        XCTAssertEqual(NotchTheme.radiusExpanded, 28, accuracy: 0.5)
        let total = NotchTheme.expandedContentBase + NotchTheme.expandedChromeHeight
        XCTAssertEqual(total, NotchGeometry.expandedPanelHeightTarget, accuracy: 0.5)
        XCTAssertEqual(total, 200, accuracy: 0.5)
        XCTAssertLessThanOrEqual(total, NotchGeometry.expandedPanelHeightCap)
        for (id, base) in productionHeightSamples() {
            let panel = base + NotchTheme.expandedChromeHeight
            XCTAssertLessThanOrEqual(
                panel,
                NotchGeometry.expandedPanelHeightCap,
                "\(id) content \(base) + chrome exceeds the hanging-card cap"
            )
        }
    }

    /// Laptop 16:10 (1440×900 and 1920×1200). Width in [480, 680]; height ≤ 230.
    func testExpandedPanelFitsLaptop16by10() {
        for (width, height) in laptopDisplays {
            let w = NotchGeometry.expandedWidth(screenWidth: width, screenHeight: height)
            XCTAssertGreaterThanOrEqual(w, NotchGeometry.expandedWidthFloor, "16:10 \(Int(width))×\(Int(height)) width")
            XCTAssertLessThanOrEqual(w, NotchGeometry.expandedWidthCap, "16:10 \(Int(width))×\(Int(height)) width")
            // ~38% density on 1440×900 → 547pt, not a banner.
            if width == 1440 {
                XCTAssertEqual(w, 547, accuracy: 1)
            }
            for (id, base) in productionHeightSamples() {
                let panelHeight = NotchGeometry.expandedPanelHeight(contentBase: base, screenHeight: height)
                XCTAssertLessThanOrEqual(
                    panelHeight,
                    NotchGeometry.expandedPanelHeightCap,
                    "16:10 \(Int(width))×\(Int(height)) height for \(id) base \(base)"
                )
                XCTAssertGreaterThan(panelHeight, 100)
            }
        }
    }

    /// Large external (2560×1440, 3840×2160). Width stays capped; height does not grow.
    func testExpandedPanelFitsLargeExternal() {
        for (width, height) in externalDisplays {
            let w = NotchGeometry.expandedWidth(screenWidth: width, screenHeight: height)
            XCTAssertGreaterThanOrEqual(w, NotchGeometry.expandedWidthFloor, "external \(Int(width))×\(Int(height)) width")
            XCTAssertLessThanOrEqual(w, NotchGeometry.expandedWidthCap, "external \(Int(width))×\(Int(height)) width")
            // 38% of 2560 would be ~973 — must cap so it stays a card.
            XCTAssertEqual(w, NotchGeometry.expandedWidthCap, accuracy: 0.5)

            for (id, base) in productionHeightSamples() {
                let panelHeight = NotchGeometry.expandedPanelHeight(contentBase: base, screenHeight: height)
                XCTAssertLessThanOrEqual(
                    panelHeight,
                    NotchGeometry.expandedPanelHeightCap,
                    "external \(Int(width))×\(Int(height)) height for \(id) base \(base)"
                )
                // Scale never exceeds 1.0 — large displays do not grow taller.
                XCTAssertEqual(
                    panelHeight,
                    base + NotchTheme.expandedChromeHeight,
                    accuracy: 0.5
                )
            }
        }
    }

    /// Every factory plugin’s live height and every declared state (calendar
    /// auth/composer, Focus modes, Webcam sizes) must fit the hanging card.
    func testProductionPluginHeightsFitCapForEveryState() {
        let bundle = ProductionTestFixtures.bundle()
        XCTAssertEqual(bundle.plugins.count, ProductionWidgetKind.allCases.count)

        var sawCalendar = false
        var sawFocus = false
        var sawWebcam = false

        let allowedHeights: [String: Set<CGFloat>] = [
            "media": [144],
            "peek-hub": [148],
            "calendar": [120, 144, 160],
            "clipboard": [144],
            "checklist": [144],
            "world-clock": [144],
            "battery": [160],
            "focus": [144, 160],
            "sports": [144],
            "system-health": [144],
            "shelf": [144],
            "webcam": [132, 144, 160]
        ]

        for plugin in bundle.plugins {
            let live = plugin.expandedContentHeight
            guard let allowed = allowedHeights[plugin.id] else {
                XCTFail("\(plugin.id) missing from the height contract")
                continue
            }
            XCTAssertTrue(allowed.contains(live), "\(plugin.id) live height \(live) is not in \(allowed)")
            for base in allowed {
                for (width, height) in laptopDisplays + externalDisplays {
                    let panel = NotchGeometry.expandedPanelHeight(contentBase: base, screenHeight: height)
                    XCTAssertLessThanOrEqual(
                        panel,
                        NotchGeometry.expandedPanelHeightCap,
                        "\(plugin.id) state \(base) on \(Int(width))×\(Int(height))"
                    )
                }
            }
            switch plugin.id {
            case "calendar": sawCalendar = true
            case "focus": sawFocus = true
            case "webcam": sawWebcam = true
            default: break
            }
        }
        XCTAssertTrue(sawCalendar && sawFocus && sawWebcam)
        assertCalendarLiveHeights()
        assertFocusLiveHeights()
        assertWebcamLiveHeights()
    }

    func testPeekAndHudSizesArePositiveAndBounded() {
        let peek = NotchGeometry.peekOverlaySize(for: nil)
        let hud = NotchGeometry.hudOverlaySize(for: nil)
        XCTAssertGreaterThan(peek.width, 0)
        XCTAssertGreaterThan(peek.height, 0)
        XCTAssertGreaterThan(hud.width, 0)
        XCTAssertGreaterThan(hud.height, 0)
        // Peeks flare modestly from the cutout — not banner-wide.
        XCTAssertLessThanOrEqual(peek.width, 480)
        XCTAssertLessThanOrEqual(hud.width, peek.width + 1)
        // Peek is taller than HUD (content row under camera band).
        XCTAssertGreaterThanOrEqual(peek.height, hud.height)
    }

    func testPeekContentTopInsetFallsBackWithoutScreen() {
        let inset = NotchGeometry.peekContentTopInset(for: nil)
        XCTAssertGreaterThanOrEqual(inset, 8)
        XCTAssertLessThanOrEqual(inset, 36)
    }

    func testCollapsedFallbackMetrics() {
        let m = NotchGeometry.currentMetrics(for: nil)
        XCTAssertGreaterThan(m.width, 0)
        XCTAssertGreaterThan(m.height, 0)
    }

    private func productionHeightSamples() -> [(String, CGFloat)] {
        ProductionTestFixtures.bundle().plugins.flatMap { plugin in
            plugin.expandedContentHeightVariants.map { (plugin.id, $0) }
        }
    }

    private func assertCalendarLiveHeights() {
        let stub = StubCalendarProvider(authorizationState: .authorized)
        let calendar = CalendarPlugin(provider: stub)
        let expected: [(CalendarAuthState, Bool, CGFloat)] = [
            (.authorized, false, 144),
            (.authorized, true, 160),
            (.writeOnly, false, 120),
            (.writeOnly, true, 160),
            (.denied, false, 120),
            (.denied, true, 160),
            (.notDetermined, false, 120),
            (.notDetermined, true, 160)
        ]
        for (auth, composer, height) in expected {
            stub.authorizationState = auth
            calendar.refresh()
            calendar.showComposer = composer
            XCTAssertEqual(calendar.expandedContentHeight, height, "calendar \(auth) composer=\(composer)")
            XCTAssertLessThanOrEqual(height + NotchTheme.expandedChromeHeight, NotchGeometry.expandedPanelHeightCap)
        }
    }

    private func assertFocusLiveHeights() {
        let focus = FocusPlugin()
        let previous = FocusController.shared.baseMode
        defer { FocusController.shared.baseMode = previous }
        let expected: [FocusBaseMode: CGFloat] = [
            .normal: 144,
            .dynamic: 144,
            .trueFocus: 144,
            .meeting: 160
        ]
        for (mode, height) in expected {
            FocusController.shared.baseMode = mode
            XCTAssertEqual(focus.expandedContentHeight, height, "focus \(mode)")
            XCTAssertLessThanOrEqual(height + NotchTheme.expandedChromeHeight, NotchGeometry.expandedPanelHeightCap)
        }
    }

    private func assertWebcamLiveHeights() {
        let webcam = WebcamPlugin()
        let previous = webcam.previewSize
        defer { webcam.previewSize = previous }
        let expected: [WebcamPlugin.PreviewSize: CGFloat] = [
            .compact: 132,
            .regular: 144,
            .large: 160
        ]
        for (size, height) in expected {
            webcam.previewSize = size
            XCTAssertEqual(webcam.expandedContentHeight, height, "webcam \(size)")
            XCTAssertLessThanOrEqual(height + NotchTheme.expandedChromeHeight, NotchGeometry.expandedPanelHeightCap)
        }
    }
}
