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

    func testMediaCopyHelpersMatchSpecCard() {
        XCTAssertEqual(
            NotchWidgetCardLayout.mediaSubtitle(artist: "Radiohead", album: "In Rainbows"),
            "Radiohead · In Rainbows"
        )
        XCTAssertEqual(NotchWidgetCardLayout.mediaSubtitle(artist: "Radiohead", album: ""), "Radiohead")
        XCTAssertEqual(NotchWidgetCardLayout.mediaSubtitle(artist: "  ", album: "Kid A"), "Kid A")
        XCTAssertEqual(NotchWidgetCardLayout.formatTime(125), "2:05")
        XCTAssertEqual(NotchWidgetCardLayout.formatTime(0), "0:00")
        XCTAssertEqual(
            NotchWidgetCardLayout.remainingLabel(elapsed: 42, duration: 180),
            "-2:18"
        )
        XCTAssertEqual(
            NotchWidgetCardLayout.remainingLabel(elapsed: 0, duration: 0),
            "--:--"
        )
    }

    func testExpandedHangStaysBlackAndOneCard() {
        XCTAssertEqual(NotchTheme.expandedContentBase + NotchTheme.expandedChromeHeight, 200, accuracy: 0.5)
        XCTAssertEqual(NotchGeometry.expandedWidthFallback, 555, accuracy: 0.5)
        XCTAssertEqual(NotchGeometry.expandedPanelHeightTarget, 200, accuracy: 0.5)
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
        XCTAssertTrue(text.contains("NotchTheme.widgetCardFill"))
        XCTAssertTrue(text.contains("NotchTheme.widgetCardStroke"))
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
        XCTAssertTrue(
            text.contains("NotchWidgetCardLayout.mediaSubtitle("),
            "Music card must build artist · album through NotchWidgetCardLayout.mediaSubtitle"
        )
        XCTAssertTrue(
            text.contains("NotchWidgetCardLayout.remainingLabel("),
            "Progress row must show remaining time through NotchWidgetCardLayout.remainingLabel"
        )
        XCTAssertTrue(text.contains("appBadge"), "Spec card keeps a small player badge")
        XCTAssertFalse(
            text.contains("Now Playing"),
            "Music card must not grow a Now Playing header chip row"
        )
        XCTAssertFalse(
            NotchWidgetCardLayout.isFullPageCarousel(text),
            "Music tab must stay one player card — no second page"
        )
    }

    func testExpandedPanelDropsCyanHangShadow() throws {
        let text = try sourceFile("Sources/Dynamo/Notch/NotchContentView.swift")
        XCTAssertFalse(
            text.contains("NotchTheme.neonCyan.opacity(0.10)"),
            "Expanded hang shadow must stay black, not a cyan bloom"
        )
        XCTAssertTrue(text.contains("Color.black.opacity(0.32)"))
    }

    func testBatteryExpandedBodyIsOneCard() throws {
        let text = try sourceFile("Sources/Dynamo/Widgets/Battery/BatteryPlugin.swift")
        XCTAssertTrue(text.contains("chargeRing"))
        XCTAssertTrue(text.contains("powerModeControls"))
        XCTAssertTrue(text.contains("vitalsStrip"))
        XCTAssertTrue(
            text.contains("No nested plates"),
            "Battery body comment is the contract: one tidy card, no nested plates"
        )
    }

    private func sourceFile(_ relative: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
