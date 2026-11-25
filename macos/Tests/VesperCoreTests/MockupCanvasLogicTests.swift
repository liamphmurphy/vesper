import CoreGraphics
import XCTest
@testable import VesperCore

final class MockupCanvasLogicTests: XCTestCase {
    func testMappingRoundTripsBetweenViewAndUserSpace() {
        let m = MockupCanvasMapping(viewBox: CGRect(x: -10, y: 20, width: 200, height: 100), zoom: 1.5)
        XCTAssertEqual(m.size, CGSize(width: 300, height: 150))
        XCTAssertEqual(m.point(CGPoint(x: -10, y: 20)), .zero)
        XCTAssertEqual(m.user(m.point(CGPoint(x: 42, y: 77))), CGPoint(x: 42, y: 77))
        XCTAssertEqual(m.rect(CGRect(x: 0, y: 20, width: 10, height: 10)), CGRect(x: 15, y: 0, width: 15, height: 15))
    }

    func testResizeHandlesMoveTheirEdgesAndNeverFlip() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(MockupResizeHandle.bottomRight.resized(r, by: CGSize(width: 20, height: 10)), CGRect(x: 10, y: 10, width: 120, height: 60))
        XCTAssertEqual(MockupResizeHandle.left.resized(r, by: CGSize(width: 30, height: 99)), CGRect(x: 40, y: 10, width: 70, height: 50))
        XCTAssertEqual(MockupResizeHandle.top.anchor(in: r), CGPoint(x: 60, y: 10))
        // Dragging past the opposite edge flips into a positive rect rather than a negative size.
        XCTAssertEqual(MockupResizeHandle.right.resized(r, by: CGSize(width: -150, height: 0)), CGRect(x: -40, y: 10, width: 50, height: 50))
    }
}
