import XCTest
@testable import Dynamo

/// Claim (1b) — a plain mouse wheel can reach overflow tabs:
/// `testVerticalWheelMapsOntoHorizontal`, `testHorizontalWheelKeepsItsAxis`.
final class NotchTabScrollTests: XCTestCase {

    func testVerticalWheelMapsOntoHorizontal() {
        XCTAssertEqual(NotchTabScroll.horizontalDelta(deltaX: 0, deltaY: 3), 3)
        XCTAssertEqual(NotchTabScroll.horizontalDelta(deltaX: 0, deltaY: -4), -4)
        XCTAssertEqual(NotchTabScroll.horizontalDelta(deltaX: 1, deltaY: 5), 5)
    }

    func testHorizontalWheelKeepsItsAxis() {
        XCTAssertEqual(NotchTabScroll.horizontalDelta(deltaX: 4, deltaY: 1), 4)
        XCTAssertEqual(NotchTabScroll.horizontalDelta(deltaX: -6, deltaY: 2), -6)
        XCTAssertEqual(NotchTabScroll.horizontalDelta(deltaX: 2, deltaY: 2), 2)
    }
}
