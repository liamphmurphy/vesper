import CoreGraphics
import XCTest
@testable import VesperCore

/// The timing and keyframe math behind native persona characters, against values worked out from
/// the CSS in `PersonaCharacterSanitizer.characterCSS`. `PersonaCharacterWebKitParityTests`
/// compares whole frames with WebKit.
final class PersonaCharacterAnimatorTests: XCTestCase {
    private let accuracy = 1e-9

    // MARK: Timing functions

    func testCubicBezierMatchesCSSEasingCurves() {
        // Reference values from bisecting each curve to double precision.
        let ease: [(Double, Double)] = [(0.1, 0.09479630571604324), (0.25, 0.40851059135539586), (0.5, 0.802403387584857),
                                        (0.75, 0.9604589783489741), (0.9, 0.9943164774845563)]
        let easeInOut: [(Double, Double)] = [(0.1, 0.019722453548311196), (0.25, 0.1291619310473198), (0.5, 0.5),
                                             (0.75, 0.8708380689526802), (0.9, 0.9802775464516889)]
        for (x, y) in ease { XCTAssertEqual(CSSTimingFunction.ease.value(at: x), y, accuracy: 1e-7, "ease(\(x))") }
        for (x, y) in easeInOut { XCTAssertEqual(CSSTimingFunction.easeInOut.value(at: x), y, accuracy: 1e-7, "ease-in-out(\(x))") }
        for f in [CSSTimingFunction.ease, .easeInOut, .linear] {
            XCTAssertEqual(f.value(at: 0), 0)
            XCTAssertEqual(f.value(at: 1), 1)
        }
        XCTAssertEqual(CSSTimingFunction.linear.value(at: 0.37), 0.37)
    }

    // MARK: Keyframe table

    func testEveryMotionHasAKeyframeTableMatchingTheCSS() {
        for motion in CharacterMotion.allCases {
            guard let spec = motion.spec else {
                XCTAssertEqual(motion, CharacterMotion.none)
                continue
            }
            XCTAssertTrue(PersonaCharacterSanitizer.renderHTML(svg: Self.minimal, color: "#000000", state: .idle)?
                .contains("@keyframes pc-\(motion.rawValue) ") == true, "\(motion) has CSS")
            XCTAssertEqual(spec.keyframes.map(\.offset), spec.keyframes.map(\.offset).sorted(), "\(motion) stops in order")
            XCTAssertTrue(spec.keyframes.allSatisfy { (0...1).contains($0.offset) })
        }
        XCTAssertEqual(CharacterMotion.blink.spec?.timing, .ease, "blink names no easing, so CSS's default applies")
        XCTAssertEqual(CharacterMotion.orbit.spec?.timing, .linear)
        XCTAssertEqual(CharacterMotion.wagFast.spec?.duration, 0.65)
    }

    /// CSS interpolates function by function only when the lists line up (WebKit pads the shorter
    /// one with identities); otherwise it falls back to matrices, which the animator doesn't do.
    func testAdjacentStopsInterpolateFunctionByFunction() {
        for motion in CharacterMotion.allCases {
            guard let spec = motion.spec else { continue }
            var stops = spec.keyframes.map(\.transform)
            stops.insert([], at: 0)
            stops.append([])
            for (a, b) in zip(stops, stops.dropFirst()) {
                for i in 0..<min(a.count, b.count) {
                    XCTAssertEqual(a[i].identity, b[i].identity, "\(motion): \(a) → \(b)")
                }
            }
        }
    }

    // MARK: Sampling

    func testSamplesBetweenStopsWithTheMotionsEasing() throws {
        let breathe = try XCTUnwrap(CharacterMotion.breathe.spec)
        // Implicit 0% (none) to 50%: halfway is ease-in-out(0.5) = 0.5.
        assertTransform(breathe.sample(at: 0.25, underlyingOpacity: 1).transform, [.translateY(-0.6), .scaleY(1.01)])
        assertTransform(breathe.sample(at: 0.5, underlyingOpacity: 1).transform, [.translateY(-1.2), .scaleY(1.02)])
        XCTAssertNil(breathe.sample(at: 0.5, underlyingOpacity: 1).opacity, "breathe leaves opacity alone")

        let blink = try XCTUnwrap(CharacterMotion.blink.spec)
        let shut = blink.sample(at: 0.46, underlyingOpacity: 1)
        assertTransform(shut.transform, [.scaleY(0.12)])
        XCTAssertEqual(try XCTUnwrap(shut.opacity), 0.25, accuracy: accuracy)
        // 45% is halfway from 44% to 46%, eased by `ease`.
        let closing = blink.sample(at: 0.45, underlyingOpacity: 1)
        let e = CSSTimingFunction.ease.value(at: 0.5)
        assertTransform(closing.transform, [.scaleY(1 - 0.88 * e)])
        XCTAssertEqual(try XCTUnwrap(closing.opacity), 1 - 0.75 * e, accuracy: accuracy)
        assertTransform(blink.sample(at: 0.2, underlyingOpacity: 1).transform, [.scaleY(1)])

        let orbit = try XCTUnwrap(CharacterMotion.orbit.spec)
        assertTransform(orbit.sample(at: 0.25, underlyingOpacity: 1).transform, [.rotate(degrees: 90)])

        // tap has no 0%: it starts from none, padded to translateY(0) rotate(0).
        let tap = try XCTUnwrap(CharacterMotion.tap.spec)
        assertTransform(tap.sample(at: 0.125, underlyingOpacity: 1).transform, [.translateY(-1), .rotate(degrees: -1)])
        assertTransform(tap.sample(at: 0.625, underlyingOpacity: 1).transform, [.translateY(-1), .rotate(degrees: 0)])

        // type pads its one-function 0% with a rotate(0) to meet 25%.
        let type = try XCTUnwrap(CharacterMotion.type.spec)
        assertTransform(type.sample(at: 0.125, underlyingOpacity: 1).transform, [.translateY(-0.8), .rotate(degrees: -0.75)])

        // tilt holds between 40% and 60%.
        let tilt = try XCTUnwrap(CharacterMotion.tilt.spec)
        assertTransform(tilt.sample(at: 0.5, underlyingOpacity: 1).transform, [.rotate(degrees: -7), .translateY(-1)])

        // shadow's implicit stops hold the element's own opacity.
        let shadow = try XCTUnwrap(CharacterMotion.shadow.spec)
        let quarter = shadow.sample(at: 0.25, underlyingOpacity: 0.22)
        assertTransform(quarter.transform, [.scaleX(0.92)])
        XCTAssertEqual(try XCTUnwrap(quarter.opacity), 0.26, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(shadow.sample(at: 0, underlyingOpacity: 0.22).opacity), 0.22, accuracy: accuracy)
    }

    func testTransformListsComposeAboutTheOriginInCSSOrder() {
        let origin = CGPoint(x: 32, y: 34)
        // A quarter turn clockwise (Y down) about the origin.
        let turn = CharacterTransformFunction.affine([.rotate(degrees: 90)], origin: origin)
        assertPoint(CGPoint(x: 42, y: 34).applying(turn), CGPoint(x: 32, y: 44))
        // rotate then translateY: the translation runs along the rotated axis.
        let tilt = CharacterTransformFunction.affine([.rotate(degrees: 90), .translateY(-2)], origin: origin)
        assertPoint(origin.applying(tilt), CGPoint(x: 34, y: 34))
        // translateY then rotate: the translation stays vertical.
        let nod = CharacterTransformFunction.affine([.translateY(-2), .rotate(degrees: 90)], origin: origin)
        assertPoint(origin.applying(nod), CGPoint(x: 32, y: 32))
        // Scale pulls toward the origin.
        let shrink = CharacterTransformFunction.affine([.scale(0.5)], origin: origin)
        assertPoint(CGPoint(x: 40, y: 34).applying(shrink), CGPoint(x: 36, y: 34))
    }

    // MARK: Rig

    func testRigResolvesStatesDelaysSpeedsAndPivots() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
          <rect data-motion="orbit" x="40" y="30" width="4" height="8"/>
          <rect data-motion="orbit" data-pivot="10 10" data-delay="-0.6" x="0" y="0" width="4" height="4"/>
          <rect data-motion="orbit" data-delay="1" data-speed="fast" x="0" y="0" width="4" height="4"/>
          <circle data-show="coding" data-motion-idle="pulse" cx="8" cy="8" r="3"/>
          <circle data-motion-working="wave" data-motion-thinking="tilt" cx="8" cy="8" r="3" opacity="0.4"/>
        </svg>
        """
        let rig = try XCTUnwrap(PersonaCharacterRig(svg: svg, color: "#112233"))
        // The sanitizer keeps text only inside text elements, so these are the root's children 0–4.
        let (plain, delayed, fast, coding, worker) = ("0", "1", "2", "3", "4")

        let idle = rig.overrides(for: .idle, at: 0.6)
        // 0.6s of 2.4s, linear: 90° about the default 32,34.
        let plainTurn = try XCTUnwrap(idle[plain]?.transform)
        assertPoint(CGPoint(x: 42, y: 34).applying(plainTurn), CGPoint(x: 32, y: 44))
        // A -0.6s delay is 1.2s in: 180° about its pivot.
        let delayedTurn = try XCTUnwrap(idle[delayed]?.transform)
        assertPoint(CGPoint(x: 0, y: 10).applying(delayedTurn), CGPoint(x: 20, y: 10))
        // A positive delay leaves the element as drawn until it passes.
        XCTAssertNil(idle[fast])
        XCTAssertNotNil(rig.overrides(for: .idle, at: 1.01)[fast])
        // fast runs at 0.65×: 1 + 0.39s is a quarter of 1.56s.
        let fastTurn = try XCTUnwrap(rig.overrides(for: .idle, at: 1.39)[fast]?.transform)
        assertPoint(CGPoint(x: 42, y: 34).applying(fastTurn), CGPoint(x: 32, y: 44))
        // data-show="coding" hides the layer outside coding, with no motion.
        XCTAssertEqual(idle[coding], MockupSVGNodeOverride(opacity: 0))
        XCTAssertNil(rig.overrides(for: .coding, at: 0.6)[coding])

        // Working states fall back to data-motion-working; thinking overrides it.
        let reading = try XCTUnwrap(rig.plans[.reading]?.animated.first { $0.path == worker })
        XCTAssertEqual(reading.spec, CharacterMotion.wave.spec)
        XCTAssertEqual(reading.underlyingOpacity, 0.4, accuracy: accuracy)
        XCTAssertEqual(rig.plans[.thinking]?.animated.first { $0.path == worker }?.spec, CharacterMotion.tilt.spec)
        XCTAssertEqual(rig.plans[.needsYou]?.animated.first { $0.path == worker }?.spec, CharacterMotion.wave.spec)

        // The static frame animates nothing and shows idle layers.
        XCTAssertFalse(rig.animates(in: .staticState))
        XCTAssertEqual(rig.overrides(for: .staticState, at: 3), [coding: MockupSVGNodeOverride(opacity: 0)])
        XCTAssertTrue(rig.animates(in: .idle))
    }

    func testRigRejectsWhatTheSanitizerRejects() {
        XCTAssertNil(PersonaCharacterRig(svg: "<svg><rect/></svg>", color: "#000000"))
        XCTAssertNil(PersonaCharacterRig(svg: "", color: "#000000"))
    }

    /// The example character the assistant prompt seeds (`server/internal/agents/assistant.go`)
    /// and one element per motion, drawn in every state across two loops of the slowest motion.
    func testEveryMotionAndSeededCharacterAnimatesInEveryState() throws {
        let perMotion = CharacterMotion.allCases.filter { $0 != .none }.enumerated().map { i, m in
            #"<rect data-motion="\#(m.rawValue)" x="\#(i * 3 % 60)" y="\#(i * 5 % 60)" width="3" height="3" fill="currentColor"/>"#
        }.joined()
        let characters = [
            Self.seededExample,
            #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">\#(perMotion)</svg>"#,
        ]
        for svg in characters {
            let rig = try XCTUnwrap(PersonaCharacterRig(svg: svg, color: "#a3a6ff"))
            for state in CharacterState.allCases {
                if state != .staticState { XCTAssertTrue(rig.animates(in: state), "\(state) moves") }
                for step in 0...40 {
                    let t = Double(step) * 0.27
                    for (path, o) in rig.overrides(for: state, at: t) {
                        if let m = o.transform {
                            XCTAssertTrue([m.a, m.b, m.c, m.d, m.tx, m.ty].allSatisfy(\.isFinite), "\(state) \(path) at \(t)")
                        }
                        if let a = o.opacity { XCTAssertTrue((0...1).contains(a), "\(state) \(path) at \(t): \(a)") }
                    }
                    XCTAssertNotNil(Self.render(rig, state: state, at: t))
                }
            }
        }
    }

    // MARK: Drawing

    func testOverridesMoveTheDrawingAndReachUseInstances() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
          <defs><rect id="dot" data-motion="glance" x="0" y="0" width="8" height="8" fill="currentColor"/></defs>
          <use href="#dot" x="28" y="28"/>
        </svg>
        """
        let rig = try XCTUnwrap(PersonaCharacterRig(svg: svg, color: "#ff0000"))
        // 25% of glance's 2.6s: translateX(-2).
        let frame = try XCTUnwrap(Self.render(rig, state: .idle, at: 0.65))
        XCTAssertEqual(Self.pixel(frame, 27, 31).r, 255, "the instance shifted left with its referenced rect")
        XCTAssertEqual(Self.pixel(frame, 35, 31).a, 0)
        let still = try XCTUnwrap(Self.render(rig, state: .staticState, at: 0.65))
        XCTAssertEqual(Self.pixel(still, 27, 31).a, 0)
        XCTAssertEqual(Self.pixel(still, 35, 31).r, 255, "currentColor is the persona's colour")
    }

    // MARK: Helpers

    static let minimal = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="4" height="4"/></svg>"#

    static let seededExample = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
      <title>Character</title>
      <ellipse data-part="shadow" data-motion="shadow" data-pivot="32 58" cx="32" cy="58" rx="15" ry="3" fill="#000" opacity="0.22"/>
      <g data-part="body" data-pivot="32 36" data-motion-idle="breathe" data-motion-thinking="tilt" data-motion-reading="nod" data-motion-coding="type" data-motion-creating="bounce" data-motion-needs-you="wave">
        <circle cx="32" cy="36" r="16" fill="currentColor"/>
        <g data-part="eyes" data-pivot="32 34" data-motion="blink" data-motion-reading="glance">
          <circle cx="26" cy="34" r="2.2" fill="#18181b"/><circle cx="38" cy="34" r="2.2" fill="#18181b"/>
        </g>
        <path data-part="spark" data-show="coding creating" data-motion="spark" data-pivot="50 18" d="M50 12l1.8 4.2L56 18l-4.2 1.8L50 24l-1.8-4.2L44 18l4.2-1.8Z" fill="#ffd6a0"/>
      </g>
    </svg>
    """

    /// A 64×64 bitmap of the character at 1×, Y-down like a view.
    static func render(_ rig: PersonaCharacterRig, state: CharacterState, at t: TimeInterval) -> CGImage? {
        guard let ctx = MockupSVGRenderer.bitmapContext(width: 64, height: 64) else { return nil }
        ctx.translateBy(x: 0, y: 64)
        ctx.scaleBy(x: 1, y: -1)
        rig.draw(state: state, at: t, in: ctx, rect: CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return (px[0], px[1], px[2], px[3])
    }

    private func assertTransform(_ got: [CharacterTransformFunction], _ want: [CharacterTransformFunction],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "\(got) vs \(want)", file: file, line: line)
        for (g, w) in zip(got, want) {
            switch (g, w) {
            case let (.translate(gx, gy), .translate(wx, wy)), let (.scale(gx, gy), .scale(wx, wy)):
                XCTAssertEqual(gx, wx, accuracy: 1e-6, "\(got) vs \(want)", file: file, line: line)
                XCTAssertEqual(gy, wy, accuracy: 1e-6, "\(got) vs \(want)", file: file, line: line)
            case let (.rotate(ga), .rotate(wa)):
                XCTAssertEqual(ga, wa, accuracy: 1e-6, "\(got) vs \(want)", file: file, line: line)
            default:
                XCTFail("\(got) vs \(want)", file: file, line: line)
            }
        }
    }

    private func assertPoint(_ got: CGPoint, _ want: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.x, want.x, accuracy: 1e-6, "\(got) vs \(want)", file: file, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: 1e-6, "\(got) vs \(want)", file: file, line: line)
    }
}
