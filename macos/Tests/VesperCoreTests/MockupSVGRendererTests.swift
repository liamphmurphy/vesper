import CoreGraphics
import ImageIO
import XCTest
@testable import VesperCore

final class MockupSVGRendererTests: XCTestCase {
    private static let doc = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
      <rect x="10" y="10" width="40" height="20" fill="#ff0000"/>
      <g transform="translate(100 0)">
        <rect x="10" y="10" width="40" height="20" fill="#00ff00" transform="scale(2)"/>
      </g>
      <line x1="0" y1="90" x2="200" y2="90" stroke="#0000ff" stroke-width="4"/>
      <rect x="160" y="60" width="30" height="20" fill="none" stroke="#000" stroke-width="2"/>
      <defs><g id="chip"><rect width="10" height="10" fill="#123456"/></g></defs>
      <use href="#chip" x="60" y="60"/>
      <text x="10" y="70" font-size="12">Hi</text>
    </svg>
    """

    private func document(_ s: String = MockupSVGRendererTests.doc) throws -> MockupSVGDocument {
        try MockupSVGDocument(source: s)
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Bitmap rows run top-down in the image; CG draws Y-up.
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (px[0], px[1], px[2], px[3])
    }

    func testRejectsNonConformingSource() {
        XCTAssertThrowsError(try MockupSVGDocument(source: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect class="a"/></svg>"#)) { error in
            XCTAssertFalse((error as? MockupSVGDocument.NotConforming)?.violations.isEmpty ?? true)
        }
    }

    func testSizesAndGeometry() throws {
        let d = try document()
        XCTAssertEqual(d.viewBox, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(d.intrinsicSize, CGSize(width: 200, height: 100))
        let red = try XCTUnwrap(d.geometry(at: "1"))
        XCTAssertEqual(red.bounds, CGRect(x: 10, y: 10, width: 40, height: 20))
        // A transformed element: local bounds before its own transform, bounds in root space.
        let green = try XCTUnwrap(d.geometry(at: "3.1"))
        XCTAssertEqual(green.localBounds, CGRect(x: 10, y: 10, width: 40, height: 20))
        XCTAssertEqual(green.bounds, CGRect(x: 120, y: 20, width: 80, height: 40))
        XCTAssertEqual(green.parentTransform, CGAffineTransform(translationX: 100, y: 0))
        // A <use> reports its instance's bounds, with x/y.
        let use = try XCTUnwrap(d.geometry(at: "11"))
        XCTAssertEqual(use.bounds, CGRect(x: 60, y: 60, width: 10, height: 10))
        XCTAssertEqual(d.drawablePaths, ["1", "3.1", "5", "7", "11", "13"])
    }

    func testHitTesting() throws {
        let d = try document()
        XCTAssertEqual(d.hitTest(CGPoint(x: 20, y: 20)), "1")
        XCTAssertEqual(d.hitTest(CGPoint(x: 150, y: 50)), "3.1")
        XCTAssertEqual(d.hitTest(CGPoint(x: 100, y: 91)), "5", "a stroke is hit")
        XCTAssertNil(d.hitTest(CGPoint(x: 175, y: 70)), "an unfilled rect's inside isn't hit")
        XCTAssertEqual(d.hitTest(CGPoint(x: 160, y: 70)), "7", "its stroke is")
        XCTAssertEqual(d.hitTest(CGPoint(x: 65, y: 65)), "11", "a use instance hits as the use")
        XCTAssertEqual(d.hitTest(CGPoint(x: 14, y: 66)), "13")
        XCTAssertNil(d.hitTest(CGPoint(x: 90, y: 40)))
    }

    func testDrawsColoursWhereTheyBelong() throws {
        let d = try document()
        let img = try XCTUnwrap(MockupSVGRenderer.makeImage(d, scale: 2))
        XCTAssertEqual(img.width, 400)
        XCTAssertEqual(pixel(img, 60, 40).0, 255, "red rect")
        XCTAssertEqual(pixel(img, 300, 60).1, 255, "green rect through two transforms")
        XCTAssertEqual(pixel(img, 200, 180).2, 255, "blue line")
        XCTAssertEqual(pixel(img, 130, 130).2, 0x56, "use instance")
        XCTAssertEqual(pixel(img, 180, 140).3, 0, "transparent background")
    }

    func testHiddenAndOnlyPathsMakeTheEditorsLayers() throws {
        let d = try document()
        let base = try XCTUnwrap(MockupSVGRenderer.makeImage(d, scale: 2, options: .init(hiddenPaths: ["3.1"])))
        XCTAssertEqual(pixel(base, 300, 60).3, 0, "hidden element isn't drawn")
        XCTAssertEqual(pixel(base, 60, 40).0, 255, "others are")
        let layer = try XCTUnwrap(MockupSVGRenderer.makeImage(d, scale: 2, options: .init(onlyPaths: ["3.1"])))
        XCTAssertEqual(pixel(layer, 300, 60).1, 255, "the isolated element keeps its ancestors' transform")
        XCTAssertEqual(pixel(layer, 60, 40).3, 0, "nothing else is drawn")
    }

    // Agent-written sizes and lengths can be extreme. Each of these trapped converting a Double that
    // was NaN, infinite or past Int's range to Int; they now draw what they can instead.

    func testRepeatingGradientWithANearZeroRadiusDoesNotTrap() throws {
        let d = try document("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs><radialGradient id="g" gradientUnits="userSpaceOnUse" cx="50" cy="50" r="1e-300" spreadMethod="repeat">
            <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>
          </radialGradient></defs>
          <rect x="0" y="0" width="100" height="100" fill="url(#g)"/>
          <rect x="0" y="0" width="10" height="10" fill="#00ff00"/>
        </svg>
        """)
        let img = try XCTUnwrap(MockupSVGRenderer.makeImage(d, scale: 1))
        XCTAssertEqual(pixel(img, 5, 5).1, 255, "the rest of the document still draws")
    }

    func testReflectedGradientWithAVanishingTransformDoesNotTrap() throws {
        let d = try document("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="1" y2="0" spreadMethod="reflect" gradientTransform="scale(1e-30)">
            <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>
          </linearGradient></defs>
          <rect x="0" y="0" width="100" height="100" fill="url(#g)"/>
        </svg>
        """)
        XCTAssertNotNil(MockupSVGRenderer.makeImage(d, scale: 1))
    }

    func testGradientCyclesFarFromTheOriginGiveNoGradient() {
        let stops: [(Double, CGColor)] = [(0, CGColor(gray: 0, alpha: 1)), (1, CGColor(gray: 1, alpha: 1))]
        XCTAssertNil(MockupSVGGradients.makeGradient(stops, spread: "reflect", from: 1e300, to: 1e300))
        XCTAssertNil(MockupSVGGradients.makeGradient(stops, spread: "repeat", from: 0, to: .infinity))
        XCTAssertNil(MockupSVGGradients.makeGradient(stops, spread: "repeat", from: 0, to: .nan))
        XCTAssertNotNil(MockupSVGGradients.makeGradient(stops, spread: "reflect", from: -3, to: 4), "ordinary ranges still work")
    }

    func testHugeMaskRegionDoesNotTrap() throws {
        let d = try document("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1e30" height="1e30">
            <rect x="0" y="0" width="100" height="100" fill="#ffffff"/>
          </mask></defs>
          <rect x="0" y="0" width="100" height="100" fill="#ff0000" mask="url(#m)"/>
        </svg>
        """)
        XCTAssertNotNil(MockupSVGRenderer.makeImage(d, scale: 1))
    }

    func testHugeMaskRegionWhoseAreaOverflowsIntDoesNotTrap() throws {
        let d = try document("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="5e9" height="5e9">
            <rect x="0" y="0" width="100" height="100" fill="#ffffff"/>
          </mask></defs>
          <rect x="0" y="0" width="100" height="100" fill="#ff0000" mask="url(#m)"/>
        </svg>
        """)
        XCTAssertNotNil(MockupSVGRenderer.makeImage(d, scale: 1))
    }

    func testHugePatternTileDoesNotTrap() throws {
        let d = try document("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs><pattern id="p" patternUnits="userSpaceOnUse" x="0" y="0" width="1e30" height="1e30">
            <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
          </pattern></defs>
          <rect x="0" y="0" width="100" height="100" fill="url(#p)"/>
        </svg>
        """)
        XCTAssertNotNil(MockupSVGRenderer.makeImage(d, scale: 1))
    }

    func testHugeDocumentSizeGivesNoImage() throws {
        let d = try document("""
        <svg xmlns="http://www.w3.org/2000/svg" width="1e30" height="1e30" viewBox="0 0 10 10">
          <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
        </svg>
        """)
        XCTAssertNil(MockupSVGRenderer.makeImage(d, scale: 1))
    }

    func testPNGRoundTrip() throws {
        let d = try document()
        let png = try XCTUnwrap(MockupSVGRenderer.pngData(d, scale: 2, background: CGColor(gray: 1, alpha: 1)))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 400)
        XCTAssertEqual(img.height, 200)
        XCTAssertEqual(pixel(img, 180, 140).0, 255, "white background")
    }

    func testFontMatchingFollowsCSS() {
        XCTAssertEqual(MockupSVGFonts.matchWeight(600, available: [400, 700]), 700)
        XCTAssertEqual(MockupSVGFonts.matchWeight(500, available: [400, 700]), 400)
        XCTAssertEqual(MockupSVGFonts.matchWeight(300, available: [400, 700]), 400)
        XCTAssertEqual(MockupSVGFonts.matchWeight(300, available: [100, 400]), 100)
        XCTAssertEqual(MockupSVGFonts.matchWeight(450, available: [300, 500, 700]), 500)
    }

    /// The editor redraws on every committed edit; a full wireframe must draw well inside a frame
    /// or two. The bound is loose so CI machines don't flake; the log line has the real number.
    func testDrawsABusyWireframeQuickly() throws {
        var body = ""
        for i in 0..<100 {
            let x = (i % 10) * 120 + 20, y = (i / 10) * 75 + 20
            body += "<rect x=\"\(x)\" y=\"\(y)\" width=\"100\" height=\"60\" rx=\"6\" fill=\"#F3F4F6\" stroke=\"#D1D5DB\"/>"
            body += "<text x=\"\(x + 8)\" y=\"\(y + 24)\" font-family=\"sans-serif\" font-size=\"13\">Card \(i)</text>"
            body += "<line x1=\"\(x + 8)\" y1=\"\(y + 40)\" x2=\"\(x + 90)\" y2=\"\(y + 40)\" stroke=\"#9CA3AF\"/>"
        }
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 800">"# + body + "</svg>"
        let d = try MockupSVGDocument(source: source)
        _ = MockupSVGRenderer.makeImage(d, scale: 2)
        let start = Date()
        for _ in 0..<5 { _ = MockupSVGRenderer.makeImage(d, scale: 2) }
        let ms = Date().timeIntervalSince(start) * 1000 / 5
        print(String(format: "mockup draw: 300 elements at 2x in %.1f ms", ms))
        XCTAssertLessThan(ms, 100)
    }
}
