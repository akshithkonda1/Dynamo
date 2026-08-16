import XCTest
@testable import Dynamo

/// Pure geometry math — no windowing, no network.
final class NotchGeometryTests: XCTestCase {

    func testExpandedWidthNilScreenUsesFallback() {
        let w = NotchGeometry.expandedWidth(for: nil)
        XCTAssertEqual(w, 640, accuracy: 0.5)
    }

    func testExpandedWidthRespectsFloorAndCap() {
        // expandedWidth uses screen.frame; with nil we already tested fallback.
        // Cap/floor constants must stay consistent with product intent.
        XCTAssertGreaterThanOrEqual(NotchGeometry.fallbackWidth, 100)
        let nilW = NotchGeometry.expandedWidth(for: nil)
        XCTAssertGreaterThanOrEqual(nilW, 520)
        XCTAssertLessThanOrEqual(nilW, 1650)
    }

    func testExpandedContentHeightNilUsesBase() {
        let h = NotchGeometry.expandedContentHeight(base: 268, for: nil)
        XCTAssertEqual(h, 268, accuracy: 0.5)
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
