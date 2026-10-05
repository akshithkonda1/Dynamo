import XCTest
@testable import Dynamo

/// Expanded hang: ~555×200, camera-gap tab band, one card per tab.
/// Tests call the same helpers the views / window use.
final class ExpandedIslandLayoutTests: XCTestCase {

    func testCameraGapClampsAroundIdeal() {
        XCTAssertEqual(NotchTabBand.cameraGapWidth(panelWidth: 555), 94, accuracy: 0.5)
        XCTAssertEqual(NotchTabBand.cameraGapWidth(panelWidth: 400), NotchTabBand.cameraGapMin)
        XCTAssertEqual(NotchTabBand.cameraGapWidth(panelWidth: 900), NotchTabBand.cameraGapMax)
        XCTAssertEqual(NotchTabBand.cameraGapIdeal, 96, accuracy: 0.5)
    }

    func testMediaMetricsScaleWithCardWidth() {
        let compact = NotchWidgetCardLayout.mediaMetrics(width: 480)
        XCTAssertEqual(compact.artSize, 68)
        XCTAssertEqual(compact.playDiameter, 38)
        XCTAssertEqual(compact.titleSize, 16)

        let wide = NotchWidgetCardLayout.mediaMetrics(width: NotchGeometry.expandedWidthFallback)
        XCTAssertEqual(wide.artSize, 80)
        XCTAssertEqual(wide.playDiameter, 42)
        XCTAssertEqual(wide.titleSize, 17)
        XCTAssertEqual(wide.sideDiameter, 32)
        XCTAssertEqual(wide.auxDiameter, 28)
    }

    func testCarouselDetectorMatchesFullPagePatternOnly() {
        let paged = """
        NotchHScroll(leftHelp: "Earlier", rightHelp: "Later") {
            HStack {
                player.frame(width: max(geo.size.width, 1))
            }
        }
        """
        XCTAssertTrue(NotchWidgetCardLayout.isFullPageCarousel(paged))

        let strip = """
        NotchHScroll(leftHelp: "Earlier cities", rightHelp: "Later cities") {
            HStack { cityCard.frame(width: 260) }
        }
        """
        XCTAssertFalse(NotchWidgetCardLayout.isFullPageCarousel(strip))
    }

    func testWidgetCardTokensAreNonZero() {
        XCTAssertEqual(NotchTheme.widgetCardInset, 10, accuracy: 0.5)
        XCTAssertEqual(NotchTheme.widgetCardRadius, 16, accuracy: 0.5)
    }

    // MARK: - Source guards (fail if views stop calling the helpers)

    func testContentViewUsesTabBandGapAndWidgetCard() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/NotchContentView.swift")
        XCTAssertTrue(
            text.contains("NotchTabBand.cameraGapWidth("),
            "Expanded tab band must size the camera gap through NotchTabBand.cameraGapWidth"
        )
        XCTAssertTrue(
            text.contains("NotchWidgetCard"),
            "Expanded body must wrap the active plugin in NotchWidgetCard"
        )
        XCTAssertTrue(text.contains("NotchTabRow.leading("))
        XCTAssertTrue(text.contains("NotchTabRow.trailing("))
    }

    func testWidgetCardUsesThemeInsets() throws {
        let text = try sourceFile("Sources/Dynamo/Theme/NotchChrome.swift")
        XCTAssertTrue(text.contains("NotchTheme.widgetCardInset"))
        XCTAssertTrue(text.contains("NotchTheme.widgetCardRadius"))
        XCTAssertTrue(text.contains("struct NotchWidgetCard"))
    }

    func testWindowUsesExpandedPanelSize() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/NotchWindowController.swift")
        XCTAssertTrue(
            text.contains("NotchGeometry.expandedPanelSize("),
            "Window must size the open island through NotchGeometry.expandedPanelSize"
        )
    }

    func testMediaViewUsesCardLayoutMetrics() throws {
        let text = try sourceFile("Sources/Dynamo/Widgets/MediaControls/MediaControlsPlugin.swift")
        XCTAssertTrue(
            text.contains("NotchWidgetCardLayout.mediaMetrics("),
            "Music card must size art/transport through NotchWidgetCardLayout.mediaMetrics"
        )
        XCTAssertFalse(
            NotchWidgetCardLayout.isFullPageCarousel(text),
            "Music tab must stay one player card — no second page"
        )
    }

    private func sourceFile(_ relative: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
