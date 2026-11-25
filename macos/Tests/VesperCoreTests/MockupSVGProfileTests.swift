import XCTest
@testable import VesperCore

/// The shared corpus keeps this validator and the server's `ValidateMockupProfile` in step.
final class MockupSVGProfileTests: XCTestCase {
    static let corpus = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testdata/mockup-svg")

    static func files(_ dir: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: corpus.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testValidCorpusConforms() throws {
        let files = try Self.files("valid")
        XCTAssertGreaterThan(files.count, 5)
        for f in files {
            let v = MockupSVGProfile.violations(try String(contentsOf: f, encoding: .utf8))
            XCTAssertEqual(v, [], f.lastPathComponent)
        }
    }

    func testInvalidCorpusIsRejected() throws {
        let files = try Self.files("invalid")
        XCTAssertGreaterThan(files.count, 20)
        for f in files {
            let v = MockupSVGProfile.violations(try String(contentsOf: f, encoding: .utf8))
            XCTAssertFalse(v.isEmpty, "\(f.lastPathComponent) should be rejected")
        }
    }

    func testNormalizedServerOutputConforms() throws {
        for f in try Self.files("normalize") where f.lastPathComponent.hasSuffix(".out.svg") {
            XCTAssertEqual(MockupSVGProfile.violations(try String(contentsOf: f, encoding: .utf8)), [], f.lastPathComponent)
        }
    }

    func testBlankWireframeConforms() {
        XCTAssertEqual(MockupSVGProfile.violations(LibraryLogic.blankWireframe(title: "A & B <c>")), [])
    }

    func testMessagesNameTheElementAndFix() {
        let v = MockupSVGProfile.violations(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect class="a" width="1em" height="1"/></svg>"#)
        XCTAssertEqual(v.count, 2)
        XCTAssertTrue(v.allSatisfy { $0.path == "0" && $0.message.hasPrefix("<rect>") })
        XCTAssertTrue(v.contains { $0.message.contains("presentation attributes") })
    }

    func testPathData() {
        for ok in ["", "M0 0", "M0,0L10,10z", "m10-20l.5.5", "M0 0 A10 10 0 1 0 20 20", "M0 0a5 5 0 1120 0", "M1e2 1E-2 L 3 4 5 6"] {
            XCTAssertTrue(MockupSVGPathData.isValid(ok), ok)
        }
        for bad in ["L0 0", "M0", "M0 0 X1 1", "M0 0 A10 10 0 2 0 1 1", "M0 0 C1 1 2 2"] {
            XCTAssertFalse(MockupSVGPathData.isValid(bad), bad)
        }
    }

    /// The editor's operations must never take a conforming mockup out of the profile.
    func testEditsKeepAMockupConforming() throws {
        var source = LibraryLogic.blankWireframe(title: "Edits")
        for kind in MockupSVGShapeKind.allCases {
            let r = try XCTUnwrap(MockupSVGEditing.insert(source, kind: kind, center: CGPoint(x: 100, y: 100)))
            source = r.source
            XCTAssertEqual(MockupSVGProfile.violations(source), [], "insert \(kind)")
            let sel = try XCTUnwrap(r.selection)
            let doc = try MockupSVGDocument(source: source)
            let g = try XCTUnwrap(doc.geometry(at: sel))
            let grown = g.localBounds.insetBy(dx: -10, dy: -5).offsetBy(dx: 3, dy: 4)
            for edit in [MockupSVGEditing.translate(source, path: sel, dx: 12.5, dy: -3),
                         MockupSVGEditing.resize(source, path: sel, from: g.localBounds, to: grown),
                         MockupSVGEditing.duplicate(source, path: sel),
                         MockupSVGEditing.sendToBack(source, path: sel)] {
                let next = try XCTUnwrap(edit)
                XCTAssertEqual(MockupSVGProfile.violations(next.source), [], "edit of \(kind)")
            }
        }
    }
}
