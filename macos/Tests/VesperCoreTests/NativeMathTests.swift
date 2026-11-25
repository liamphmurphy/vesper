import CoreGraphics
import XCTest
@testable import VesperCore

@MainActor
final class NativeMathTests: XCTestCase {
    private func request(_ tex: String, display: Bool = true, size: Double = 15) -> MathRenderRequest {
        MathRenderRequest(tex: tex, display: display, color: "#112233", fontSize: size)
    }

    /// The TeX agents write most (fractions, roots, sums, matrices, text, Greek) all lay out.
    func testCommonTeXRenders() throws {
        let corpus = [
            #"e^{i\pi} + 1 = 0"#,
            #"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#,
            #"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}"#,
            #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#,
            #"f(x) = \begin{cases} 1 & x > 0 \\ 0 & \text{otherwise} \end{cases}"#,
            #"\mathbb{R}^n \to \mathbb{R}, \quad \alpha\beta\gamma\Omega"#,
            #"\lim_{x \to 0} \frac{\sin x}{x} = 1"#,
            #"\operatorname{softmax}(z)_i = \frac{e^{z_i}}{\sum_j e^{z_j}}"#,
        ]
        for tex in corpus {
            let drawn = try XCTUnwrap(NativeMath.render(request(tex)), tex)
            XCTAssertGreaterThan(drawn.width, 10, tex)
            XCTAssertGreaterThan(drawn.height, 5, tex)
            let ascent = try XCTUnwrap(drawn.ascent, tex)
            XCTAssertGreaterThan(ascent, 0, tex)
            XCTAssertLessThanOrEqual(ascent, drawn.height, tex)
            XCTAssertEqual(drawn.pdf.prefix(5), Data("%PDF-".utf8), tex)
        }
    }

    /// Bad TeX returns nil so the chat keeps the source, as it did with KaTeX errors.
    func testInvalidTeXReturnsNil() {
        XCTAssertNil(NativeMath.render(request(#"\frac{1}{"#)))
        XCTAssertNil(NativeMath.render(request(#"\notacommand{x}"#)))
        XCTAssertNil(NativeMath.render(request("")))
    }

    /// Inline (text style) sets a fraction's parts smaller, so it's shorter than the display one.
    /// (Unlike KaTeX, SwiftMath stacks a sum's limits in both styles, so a sum wouldn't tell them apart.)
    func testDisplayIsTallerThanInline() throws {
        let tex = #"\frac{a+b}{c+d}"#
        let display = try XCTUnwrap(NativeMath.render(request(tex, display: true)))
        let inline = try XCTUnwrap(NativeMath.render(request(tex, display: false)))
        XCTAssertGreaterThan(display.height, inline.height)
    }

    /// Size follows the text: twice the point size is about twice as wide.
    func testScalesWithFontSize() throws {
        let small = try XCTUnwrap(NativeMath.render(request("x + y", size: 12)))
        let large = try XCTUnwrap(NativeMath.render(request("x + y", size: 24)))
        XCTAssertEqual(large.width / small.width, 2, accuracy: 0.15)
    }

    /// The PDF opens and is the size the embed reports, so `EmbedImageView` shows it unscaled.
    func testPDFMatchesReportedSize() throws {
        let drawn = try XCTUnwrap(NativeMath.render(request(#"\frac{a}{b}"#)))
        let provider = try XCTUnwrap(CGDataProvider(data: drawn.pdf as CFData))
        let page = try XCTUnwrap(CGPDFDocument(provider)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, drawn.width, accuracy: 0.01)
        XCTAssertEqual(box.height, drawn.height, accuracy: 0.01)
    }
}
