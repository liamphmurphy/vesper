import XCTest
@testable import VesperCore

final class WorkPersonaFaceTests: XCTestCase {
    func testPhotoWinsOutsideAChat() {
        XCTAssertEqual(WorkPersona.face(avatarUrl: "/a.png", characterSvg: "<svg/>", preferCharacter: false), .photo(url: "/a.png"))
    }

    func testCharacterWinsInAChat() {
        XCTAssertEqual(WorkPersona.face(avatarUrl: "/a.png", characterSvg: "<svg/>", preferCharacter: true), .character(svg: "<svg/>"))
    }

    func testFallsBackToWhicheverTheyHave() {
        XCTAssertEqual(WorkPersona.face(avatarUrl: "/a.png", characterSvg: "", preferCharacter: true), .photo(url: "/a.png"))
        XCTAssertEqual(WorkPersona.face(avatarUrl: nil, characterSvg: "<svg/>", preferCharacter: false), .character(svg: "<svg/>"))
        XCTAssertEqual(WorkPersona.face(avatarUrl: "", characterSvg: nil, preferCharacter: true), .initial)
    }
}
