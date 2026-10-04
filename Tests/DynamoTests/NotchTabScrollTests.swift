import AppKit
import XCTest
@testable import Dynamo

/// Mouse-wheel → horizontal mapping. A plain mouse only sends vertical
/// line deltas; trackpad/Magic Mouse precise gestures stay native.
final class NotchTabScrollTests: XCTestCase {

    func testPlainMouseWheelConvertsVerticalToHorizontal() {
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: 3, deltaX: 0, hasPreciseScrollingDeltas: false),
            3
        )
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: -4, deltaX: 0, hasPreciseScrollingDeltas: false),
            -4
        )
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: 2, deltaX: 0.004, hasPreciseScrollingDeltas: false),
            2
        )
    }

    func testTrackpadHorizontalSwipeIsUnchanged() {
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: 1, deltaX: 4, hasPreciseScrollingDeltas: true),
            4
        )
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: -0.5, deltaX: -6, hasPreciseScrollingDeltas: true),
            -6
        )
    }

    func testTrackpadVerticalSwipeIsNotHijacked() {
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: 5, deltaX: 0, hasPreciseScrollingDeltas: true),
            0
        )
        XCTAssertEqual(
            NotchTabScroll.horizontalDelta(deltaY: -8, deltaX: 0, hasPreciseScrollingDeltas: true),
            0
        )
    }

    func testNativeHorizontalScrollerIsVisibleAndDraggable() {
        let scroll = NotchTabScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 36))
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertTrue(scroll.autohidesScrollers)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
    }
}
