import XCTest
@testable import VesperCore

final class SessionStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vesper-session-\(UUID().uuidString)/session.json")
    }

    func testMissingFileGivesDefault() {
        XCTAssertEqual(SessionStore.load(from: tempFile()), .empty)
    }

    func testSaveLoadRoundTrip() throws {
        let url = tempFile()
        let state = SessionState(tabs: ["http://127.0.0.1:8080/", "http://127.0.0.1:8080/work"], activeIndex: 1,
                                 bounds: WindowBounds(x: 10, y: 20, width: 1280, height: 840, isMaximized: false))
        try SessionStore.save(state, to: url)
        XCTAssertEqual(SessionStore.load(from: url), state)
    }

    func testFiltersAndClamps() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"tabs":["http://a.test/x","file:///etc/passwd","javascript:1",5,"https://b.test/"],"activeIndex":9,
         "bounds":{"x":1.4,"y":2.6,"width":800.4,"height":600}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let s = SessionStore.load(from: url)
        XCTAssertEqual(s.tabs, ["http://a.test/x", "https://b.test/"])
        XCTAssertEqual(s.activeIndex, 1)
        XCTAssertEqual(s.bounds, WindowBounds(x: 1, y: 3, width: 800, height: 600))
    }

    func testSmallBoundsAndBadActiveIndexDropped() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"tabs":["http://a.test/"],"activeIndex":-1,"bounds":{"width":300,"height":300}}"#.write(to: url, atomically: true, encoding: .utf8)
        let s = SessionStore.load(from: url)
        XCTAssertEqual(s.activeIndex, 0)
        XCTAssertNil(s.bounds)
    }

    func testGarbageGivesDefault() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStore.load(from: url), .empty)
    }
}
