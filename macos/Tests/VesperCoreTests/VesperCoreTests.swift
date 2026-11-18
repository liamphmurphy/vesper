import XCTest
@testable import VesperCore

final class VesperCoreTests: XCTestCase {
    func testProtocolVersion() {
        XCTAssertEqual(VesperCore.protocolVersion, 1)
    }
}
