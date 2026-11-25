import XCTest
@testable import VesperCore

final class PersonaCharacterTests: XCTestCase {
    private let svgNS = "xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\""

    private func wrap(_ body: String) -> String {
        "<svg \(svgNS) viewBox=\"0 0 64 64\">\(body)</svg>"
    }

    private func flatten(_ node: SanitizedSVGNode) -> [SanitizedSVGNode] {
        [node] + node.children.flatMap(flatten)
    }

    func testSanitizerDropsScriptsStylesImagesNestedSVGAndCountsSkipped() throws {
        let input = wrap(
            "<script>alert(1)</script>"
                + "<style>rect{fill:red}</style>"
                + "<foreignObject><div xmlns=\"http://www.w3.org/1999/xhtml\"><b>x</b></div></foreignObject>"
                + "<h:p xmlns:h=\"http://www.w3.org/1999/xhtml\"/>"
                + "<image href=\"data:image/png;base64,AAAA\"/>"
                + "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"4\"/></svg>"
                + "<rect width=\"10\"/>"
        )
        let result = PersonaCharacterSanitizer.sanitizeCharacterSVG(input, prefix: "pc-1-")
        let tree = try XCTUnwrap(result.tree)
        XCTAssertEqual(tree.children.map(\.tag), ["rect"])
        XCTAssertEqual(result.skipped, 1 + 1 + 3 + 1 + 1 + 2)
    }

    func testRejectsMissingNamespaceNonSVGRootAndDoctypes() {
        XCTAssertNil(PersonaCharacterSanitizer.sanitizeCharacterSVG("<svg><rect/></svg>").tree)
        XCTAssertNil(PersonaCharacterSanitizer.sanitizeCharacterSVG("<div xmlns=\"http://www.w3.org/2000/svg\"/>").tree)
        XCTAssertNil(PersonaCharacterSanitizer.sanitizeCharacterSVG("<!DOCTYPE svg><svg \(svgNS)><rect/></svg>").tree)
        XCTAssertNil(PersonaCharacterSanitizer.sanitizeCharacterSVG("<!ENTITY x \"y\"><svg \(svgNS)><rect/></svg>").tree)
        XCTAssertNil(PersonaCharacterSanitizer.sanitizeCharacterSVG("<svg \(svgNS)><unclosed").tree)
    }

    func testDropsEventsStylesJavascriptURLsExternalRefsAndPrefixesIDs() {
        let input = wrap(
            "<defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"#fff\"/></linearGradient><clipPath id=\"c\"/></defs>"
                + "<rect onclick=\"x()\" onload=\"y()\" style=\"fill:red\" class=\"a\" data-x=\"1\" fill=\"url(#g)\" clip-path=\"url(#c)\" id=\"r\" width=\"5\" stroke-width=\"2\"/>"
                + "<rect id=\"9bad id\" fill=\"url(https://evil.test/a)\" stroke=\"url(#g) red\"/>"
                + "<rect fill=\"java script:alert(1)\" stroke=\"jav&#x61;script:alert(1)\"/>"
                + "<use xlink:href=\"#g\"/>"
                + "<use xlink:href=\"#g\" href=\"#r\"/>"
                + "<use href=\"https://evil.test/x\"/>"
                + "<use href=\"data:image/png;base64,AAAA\"/>"
                + "<use href=\"javascript:alert(1)\"/>"
        )
        let result = PersonaCharacterSanitizer.sanitizeCharacterSVG(input, prefix: "pc-1-")
        guard let tree = result.tree else { return XCTFail("Expected sanitized tree") }
        let nodes = flatten(tree)

        let grad = nodes.first { $0.tag == "linearGradient" }
        XCTAssertEqual(grad?.attrs["id"], "pc-1-g")

        let rects = nodes.filter { $0.tag == "rect" }
        XCTAssertEqual(rects[0].attrs, [
            "clip-path": "url(#pc-1-c)",
            "fill": "url(#pc-1-g)",
            "id": "pc-1-r",
            "stroke-width": "2",
            "width": "5",
        ])
        XCTAssertEqual(rects[1].attrs, [:])
        XCTAssertEqual(rects[2].attrs, [:])

        let uses = nodes.filter { $0.tag == "use" }
        XCTAssertEqual(uses.map { $0.attrs["href"] }, ["#pc-1-g", "#pc-1-r", nil, nil, nil])
    }

    func testValidatesCharacterRigAttributesAndResolvesNodeStyle() {
        let input = wrap(
            "<g data-part=\"body\" data-motion-idle=\"breathe\" data-motion-coding=\"type\" data-pivot=\"32 34\" data-delay=\"-0.5\" data-speed=\"fast\" data-show=\"idle coding\">"
                + "<rect data-motion=\"explode\" data-pivot=\"99 99\" data-delay=\"99\" data-speed=\"warp\" data-show=\"nap\" data-part=\"Bad!\"/>"
                + "</g>"
        )
        guard let tree = PersonaCharacterSanitizer.sanitizeCharacterSVG(input).tree else {
            return XCTFail("Expected tree")
        }
        let g = tree.children[0]
        XCTAssertEqual(g.attrs["data-part"], "body")
        XCTAssertEqual(g.attrs["data-motion-idle"], "breathe")
        XCTAssertEqual(g.attrs["data-motion-coding"], "type")
        XCTAssertEqual(g.attrs["data-pivot"], "32 34")
        XCTAssertEqual(g.attrs["data-delay"], "-0.5")
        XCTAssertEqual(g.attrs["data-speed"], "fast")
        XCTAssertEqual(g.attrs["data-show"], "idle coding")
        XCTAssertEqual(g.children[0].attrs, [:])

        let attrs: [String: String] = [
            "data-motion": "blink",
            "data-motion-idle": "breathe",
            "data-motion-working": "tap",
            "data-motion-coding": "type",
            "data-motion-reading": "none",
            "data-pivot": "32 34",
            "data-delay": "-0.5",
            "data-speed": "fast",
        ]
        XCTAssertNil(PersonaCharacterSanitizer.resolveCharacterNodeStyle(attrs, state: .staticState).motion)
        XCTAssertEqual(PersonaCharacterSanitizer.resolveCharacterNodeStyle(attrs, state: .idle).motion, .breathe)
        XCTAssertEqual(PersonaCharacterSanitizer.resolveCharacterNodeStyle(attrs, state: .thinking).motion, .tap)
        XCTAssertEqual(PersonaCharacterSanitizer.resolveCharacterNodeStyle(attrs, state: .coding).motion, .type)
        XCTAssertNil(PersonaCharacterSanitizer.resolveCharacterNodeStyle(attrs, state: .reading).motion)

        let coding = PersonaCharacterSanitizer.resolveCharacterNodeStyle(attrs, state: .coding)
        XCTAssertFalse(coding.hidden)
        XCTAssertEqual(coding.transformOrigin, "32px 34px")
        XCTAssertEqual(coding.animationDelay, "-0.5s")
        XCTAssertEqual(coding.speedMultiplier, "0.65")

        let sparkAttrs = ["data-show": "coding creating", "data-motion": "spark"]
        XCTAssertTrue(PersonaCharacterSanitizer.resolveCharacterNodeStyle(sparkAttrs, state: .staticState).hidden)
        XCTAssertTrue(PersonaCharacterSanitizer.resolveCharacterNodeStyle(sparkAttrs, state: .idle).hidden)
        XCTAssertTrue(PersonaCharacterSanitizer.resolveCharacterNodeStyle(sparkAttrs, state: .reading).hidden)
        XCTAssertFalse(PersonaCharacterSanitizer.resolveCharacterNodeStyle(sparkAttrs, state: .coding).hidden)
        XCTAssertEqual(PersonaCharacterSanitizer.resolveCharacterNodeStyle(sparkAttrs, state: .coding).motion, .spark)
        XCTAssertFalse(PersonaCharacterSanitizer.resolveCharacterNodeStyle(sparkAttrs, state: .creating).hidden)

        let workAttrs = ["data-show": "working", "data-motion": "orbit"]
        XCTAssertTrue(PersonaCharacterSanitizer.resolveCharacterNodeStyle(workAttrs, state: .idle).hidden)
        XCTAssertFalse(PersonaCharacterSanitizer.resolveCharacterNodeStyle(workAttrs, state: .reading).hidden)
        XCTAssertFalse(PersonaCharacterSanitizer.resolveCharacterNodeStyle(workAttrs, state: .coding).hidden)
        XCTAssertTrue(PersonaCharacterSanitizer.resolveCharacterNodeStyle(workAttrs, state: .needsYou).hidden)

        let alertAttrs = ["data-show": "needs-you", "data-motion": "pulse"]
        XCTAssertFalse(PersonaCharacterSanitizer.resolveCharacterNodeStyle(alertAttrs, state: .needsYou).hidden)
        XCTAssertTrue(PersonaCharacterSanitizer.resolveCharacterNodeStyle(alertAttrs, state: .idle).hidden)
    }

    func testCharacterStateForStatusIsExhaustiveAndHandlesAwaitingAndStopping() {
        for kind in ActivitySceneKind.allCases {
            let state = PersonaCharacterSanitizer.characterStateForStatus(kind)
            XCTAssertNotEqual(state, .staticState, "\(kind.rawValue) mapped to static")
            XCTAssertNotEqual(state, .idle, "\(kind.rawValue) mapped to idle")
        }
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.readingCode), .reading)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.writingCode), .coding)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.tests), .coding)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.canvas), .creating)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.thinking), .thinking)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.connector), .needsYou)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.writingCode, awaiting: true), .needsYou)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.writingCode, stopping: true), .staticState)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForStatus(.writingCode, awaiting: true, stopping: true), .staticState)

        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForDock(.working), .working)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForDock(.needsYou), .needsYou)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForDock(.replied), .idle)
        XCTAssertEqual(PersonaCharacterSanitizer.characterStateForDock(nil), .idle)

        let detected = PersonaCharacterSanitizer.detectCharacterStates(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><g data-motion-idle=\"breathe\" data-motion-coding=\"type\"><path data-show=\"reading needs-you\"/></g></svg>"
        )
        XCTAssertEqual(detected, [.idle, .coding, .reading, .needsYou])
    }

    func testRenderHTMLIncludesStrictCSPKeyframesAndEscaping() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"128\" height=\"128\" viewBox=\"0 0 10 10\"><g data-motion-coding=\"type\" data-show=\"coding\"><circle fill=\"currentColor\" cx=\"32\" cy=\"32\" r=\"10\"/></g><text>1 &lt; 2</text><script>evil()</script></svg>"
        let html = PersonaCharacterSanitizer.renderHTML(svg: svg, color: "#a3a6ff", state: .coding, clipped: true, reduceMotion: false)
        guard let html else { return XCTFail("Expected HTML") }

        XCTAssertTrue(html.contains("default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none';"))
        XCTAssertTrue(html.contains("viewBox=\"0 0 64 64\""))
        XCTAssertFalse(html.contains("width=\"128\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("data-pc-state=\"coding\""))
        XCTAssertTrue(html.contains("data-pc-clipped=\"true\""))
        XCTAssertTrue(html.contains("data-pc-motion=\"type\""))
        XCTAssertTrue(html.contains("color: #a3a6ff;"))
        XCTAssertTrue(html.contains("1 &lt; 2"))
        XCTAssertTrue(html.contains("@keyframes pc-breathe"))
        XCTAssertTrue(html.contains("@keyframes pc-shadow"))

        // Rejects CSS injection inside color.
        let injected = PersonaCharacterSanitizer.renderHTML(svg: svg, color: "red;}body{background:url(https://evil)", state: .idle)
        XCTAssertTrue(injected?.contains("color: #64748b;") == true)

        // Reduce Motion forces static state & reduced-motion attribute.
        let reduced = PersonaCharacterSanitizer.renderHTML(svg: svg, color: "#a3a6ff", state: .coding, reduceMotion: true)
        XCTAssertTrue(reduced?.contains("data-pc-state=\"static\"") == true)
        XCTAssertTrue(reduced?.contains("data-pc-reduced-motion=\"true\"") == true)
    }

    func testActivityStateMatchesTheWebTable() {
        XCTAssertEqual(CharacterState.forActivity(.thinking), .thinking)
        XCTAssertEqual(CharacterState.forActivity(.searchingCode), .reading)
        XCTAssertEqual(CharacterState.forActivity(.web), .reading)
        XCTAssertEqual(CharacterState.forActivity(.install), .coding)
        XCTAssertEqual(CharacterState.forActivity(.workflow), .coding)
        XCTAssertEqual(CharacterState.forActivity(.writingReply), .creating)
        XCTAssertEqual(CharacterState.forActivity(.tickets), .creating)
        XCTAssertEqual(CharacterState.forActivity(.connector), .needsYou)
        XCTAssertEqual(CharacterState.forActivity(.secret), .needsYou)
    }

    func testActivityStateAsksForThePersonWhileAwaitingAndFreezesWhileStopping() {
        XCTAssertEqual(CharacterState.forActivity(.writingCode, awaiting: true), .needsYou)
        XCTAssertEqual(CharacterState.forActivity(.writingCode, awaiting: true, stopping: true), .staticState)
        XCTAssertEqual(CharacterState.forActivity(.thinking, stopping: true), .staticState)
    }
}
