import XCTest
@testable import VesperCore

final class ThemeTokensTests: XCTestCase {
    func testHexColours() {
        XCTAssertEqual(RGBA(hex: "#ff8000"), RGBA(red: 1, green: 128.0 / 255, blue: 0, alpha: 1))
        XCTAssertEqual(RGBA(hex: "#00000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertNil(RGBA(hex: "ff8000"))
        XCTAssertNil(RGBA(hex: "#ff80"))
        XCTAssertNil(RGBA(hex: "#gg0000"))
    }

    func testTextSizeScalesEveryStyle() {
        let large = ThemeTokens(mode: .dark, textSize: "large")
        XCTAssertEqual(large.typeScale, 1.12)
        XCTAssertEqual(large.pointSize(.body), 13 * 1.12, accuracy: 0.0001)
        XCTAssertEqual(ThemeTokens(mode: .dark, textSize: "unknown").typeScale, 1)
        XCTAssertEqual(ThemeTokens(mode: .dark).pointSize(.display), 26)
    }

    func testPageAppearanceCarriesTheTheme() throws {
        let data = try Data(contentsOf: BridgeProtocolTests.fixtureDir.appendingPathComponent("page-messages.json"))
        let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        let fixtures = try entries.map { try PageMessage.decode(fromJSONObject: $0) }
        let themed = fixtures.compactMap { message -> ThemeTokens? in
            if case .appearance(_, _, let theme?) = message { return theme }
            return nil
        }
        XCTAssertEqual(themed.count, 1)
        XCTAssertEqual(themed.first?.mode, .dark)
        XCTAssertEqual(themed.first?.textSize, "large")
        XCTAssertEqual(themed.first?.color("accent"), RGBA(hex: "#d79921"))
        XCTAssertEqual(themed.first?.color("accent-soft")?.alpha ?? 0, 0x26 / 255.0, accuracy: 0.0001)
        // Older pages send no theme; that's still a valid appearance.
        XCTAssertTrue(fixtures.contains(.appearance(mode: .dark)))
    }
}
