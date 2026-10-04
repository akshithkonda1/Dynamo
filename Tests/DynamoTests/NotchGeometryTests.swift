import XCTest
@testable import Dynamo

/// Pure geometry math — no windowing, no network.
///
/// Claim (2) — expanded island stays a compact hanging card:
/// `testExpandedPanelFitsLaptop16by10`, `testExpandedPanelFitsLargeExternal`,
/// `testExpandedWidthIsCompactNotBanner`, `testExpandedChromePlusCardStaysUnderCap`.
final class NotchGeometryTests: XCTestCase {

    /// Tallest compact-card bases used by production plugins (Battery / Meeting /
    /// Webcam large). Default card is `NotchTheme.expandedContentBase` (144).
    private let productionContentBases: [CGFloat] = [
        NotchTheme.expandedContentBase,
        148, // Hub
        160  // Battery, Focus meeting, Webcam large
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
        // ~38% of a 1470pt display ≈ 559pt; fallback is the same density.
        XCTAssertEqual(NotchGeometry.expandedWidthFallback, 560, accuracy: 0.5)
        XCTAssertEqual(NotchGeometry.expandedWidth(screenWidth: 1470, screenHeight: 956), 559, accuracy: 1)
        XCTAssertGreaterThanOrEqual(NotchGeometry.expandedWidthFloor, 480)
        XCTAssertLessThanOrEqual(NotchGeometry.expandedWidthCap, 680)
    }

    func testExpandedChromePlusCardStaysUnderCap() {
        XCTAssertEqual(NotchTheme.expandedChromeHeight, 56, accuracy: 0.5)
        XCTAssertEqual(NotchTheme.radiusExpanded, 28, accuracy: 0.5)
        let total = NotchTheme.expandedContentBase + NotchTheme.expandedChromeHeight
        XCTAssertEqual(total, 200, accuracy: 0.5)
        XCTAssertLessThanOrEqual(total, NotchGeometry.expandedPanelHeightCap)
        for base in productionContentBases {
            let panel = base + NotchTheme.expandedChromeHeight
            XCTAssertLessThanOrEqual(
                panel,
                NotchGeometry.expandedPanelHeightCap,
                "content \(base) + chrome exceeds the hanging-card cap"
            )
        }
    }

    /// Laptop 16:10 (1440×900 and 1920×1200). Width in [480, 680]; height ≤ 230.
    func testExpandedPanelFitsLaptop16by10() {
        let displays: [(CGFloat, CGFloat)] = [
            (1440, 900),
            (1680, 1050),
            (1920, 1200)
        ]
        for (width, height) in displays {
            let w = NotchGeometry.expandedWidth(screenWidth: width, screenHeight: height)
            XCTAssertGreaterThanOrEqual(w, NotchGeometry.expandedWidthFloor, "16:10 \(Int(width))×\(Int(height)) width")
            XCTAssertLessThanOrEqual(w, NotchGeometry.expandedWidthCap, "16:10 \(Int(width))×\(Int(height)) width")
            // ~38% density on 1440×900 → 547pt, not a banner.
            if width == 1440 {
                XCTAssertEqual(w, 547, accuracy: 1)
            }
            for base in productionContentBases {
                let panelHeight = NotchGeometry.expandedPanelHeight(contentBase: base, screenHeight: height)
                XCTAssertLessThanOrEqual(
                    panelHeight,
                    NotchGeometry.expandedPanelHeightCap,
                    "16:10 \(Int(width))×\(Int(height)) height for base \(base)"
                )
                XCTAssertGreaterThan(panelHeight, 100)
            }
        }
    }

    /// Large external (2560×1440, 3840×2160). Width stays capped; height does not grow.
    func testExpandedPanelFitsLargeExternal() {
        let displays: [(CGFloat, CGFloat)] = [
            (2560, 1440),
            (3840, 2160)
        ]
        for (width, height) in displays {
            let w = NotchGeometry.expandedWidth(screenWidth: width, screenHeight: height)
            XCTAssertGreaterThanOrEqual(w, NotchGeometry.expandedWidthFloor, "external \(Int(width))×\(Int(height)) width")
            XCTAssertLessThanOrEqual(w, NotchGeometry.expandedWidthCap, "external \(Int(width))×\(Int(height)) width")
            // 38% of 2560 would be ~973 — must cap so it stays a card.
            XCTAssertEqual(w, NotchGeometry.expandedWidthCap, accuracy: 0.5)

            for base in productionContentBases {
                let panelHeight = NotchGeometry.expandedPanelHeight(contentBase: base, screenHeight: height)
                XCTAssertLessThanOrEqual(
                    panelHeight,
                    NotchGeometry.expandedPanelHeightCap,
                    "external \(Int(width))×\(Int(height)) height for base \(base)"
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
}
