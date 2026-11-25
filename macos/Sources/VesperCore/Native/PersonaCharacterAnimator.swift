import CoreGraphics
import Foundation

// MARK: - CSS timing

/// The CSS easing functions the character keyframes use (`PersonaCharacterSanitizer.characterCSS`).
enum CSSTimingFunction: Equatable, Sendable {
    case linear
    case cubicBezier(Double, Double, Double, Double)

    /// CSS `ease`, the default for an animation that names none (`blink`).
    static let ease = CSSTimingFunction.cubicBezier(0.25, 0.1, 0.25, 1)
    static let easeInOut = CSSTimingFunction.cubicBezier(0.42, 0, 0.58, 1)

    /// The eased output progress for input progress `x` in 0...1.
    func value(at x: Double) -> Double {
        switch self {
        case .linear:
            return x
        case .cubicBezier(let x1, let y1, let x2, let y2):
            if x <= 0 { return 0 }
            if x >= 1 { return 1 }
            let s = Self.solve(x, x1, x2)
            return Self.bezier(s, y1, y2)
        }
    }

    /// One coordinate of a unit cubic Bézier through (0,0) and (1,1) at parameter `s`.
    static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }

    /// The parameter where the curve's x is `x`: Newton's method, falling back to bisection where
    /// the slope flattens. CSS requires x1 and x2 in 0...1, so x(s) is monotonic and the root unique.
    static func solve(_ x: Double, _ x1: Double, _ x2: Double) -> Double {
        let epsilon = 1e-9
        var s = x
        for _ in 0..<8 {
            let err = bezier(s, x1, x2) - x
            if abs(err) < epsilon { return s }
            let u = 1 - s
            let slope = 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2)
            if abs(slope) < 1e-6 { break }
            s -= err / slope
        }
        var lo = 0.0, hi = 1.0
        s = x
        while hi - lo > epsilon {
            if bezier(s, x1, x2) < x { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return s
    }
}

// MARK: - Transform functions

/// A CSS transform function from the character keyframes, in `px` and degrees of the 64×64 viewBox.
enum CharacterTransformFunction: Equatable, Sendable {
    case translate(x: Double, y: Double)
    case rotate(degrees: Double)
    case scale(x: Double, y: Double)

    static func translateX(_ v: Double) -> Self { .translate(x: v, y: 0) }
    static func translateY(_ v: Double) -> Self { .translate(x: 0, y: v) }
    static func scaleX(_ v: Double) -> Self { .scale(x: v, y: 1) }
    static func scaleY(_ v: Double) -> Self { .scale(x: 1, y: v) }
    static func scale(_ v: Double) -> Self { .scale(x: v, y: v) }

    /// The same function doing nothing: what CSS pads a shorter list (or `none`) with.
    var identity: Self {
        switch self {
        case .translate: .translate(x: 0, y: 0)
        case .rotate: .rotate(degrees: 0)
        case .scale: .scale(x: 1, y: 1)
        }
    }

    /// Interpolates each argument, as CSS does between functions of one type. Every pair the
    /// keyframe table puts side by side shares a type (`PersonaCharacterAnimatorTests`), so CSS's
    /// matrix fallback for mismatched lists never applies.
    func interpolated(to other: Self, _ p: Double) -> Self {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        switch (self, other) {
        case let (.translate(ax, ay), .translate(bx, by)): return .translate(x: mix(ax, bx), y: mix(ay, by))
        case let (.rotate(a), .rotate(b)): return .rotate(degrees: mix(a, b))
        case let (.scale(ax, ay), .scale(bx, by)): return .scale(x: mix(ax, bx), y: mix(ay, by))
        default: return p < 0.5 ? self : other
        }
    }

    /// The function as a CoreGraphics transform. A positive CSS angle turns clockwise on screen,
    /// as `CGAffineTransform(rotationAngle:)` does in the renderer's Y-down space.
    var affine: CGAffineTransform {
        switch self {
        case let .translate(x, y): CGAffineTransform(translationX: x, y: y)
        case let .rotate(deg): CGAffineTransform(rotationAngle: deg * .pi / 180)
        case let .scale(x, y): CGAffineTransform(scaleX: x, y: y)
        }
    }

    /// Interpolates two lists the way WebKit does: the shorter (or `none`, the empty list) is
    /// padded with identities of the longer's functions.
    static func interpolate(_ a: [Self], _ b: [Self], _ p: Double) -> [Self] {
        (0..<max(a.count, b.count)).map { i in
            let from = i < a.count ? a[i] : b[i].identity
            let to = i < b.count ? b[i] : a[i].identity
            return from.interpolated(to: to, p)
        }
    }

    /// The list about `origin`, CSS's `translate(origin) f1 f2 … translate(-origin)`, in
    /// CoreGraphics' order (the first transform concatenated applies first).
    static func affine(_ list: [Self], origin: CGPoint) -> CGAffineTransform {
        var m = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        for f in list.reversed() { m = m.concatenating(f.affine) }
        return m.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}

// MARK: - Keyframes

/// One `@keyframes` stop. Every stop in the table sets `transform`; the four motions that fade
/// also set `opacity` on every stop.
struct CharacterKeyframe: Equatable, Sendable {
    var offset: Double
    var transform: [CharacterTransformFunction]
    var opacity: Double?
}

/// A motion's CSS animation: `animation: pc-NAME calc(duration * var(--pc-speed, 1)) TIMING infinite`.
struct CharacterMotionSpec: Equatable, Sendable {
    var duration: Double
    var timing: CSSTimingFunction
    /// The stops as written; a missing 0% or 100% takes the element's own value, as CSS does.
    var keyframes: [CharacterKeyframe]

    var animatesOpacity: Bool { keyframes.contains { $0.opacity != nil } }

    /// The animated transform list and opacity at `progress` (0..<1) of an iteration.
    /// `underlyingOpacity` is the element's `opacity` attribute, which an implicit stop holds.
    func sample(at progress: Double, underlyingOpacity: Double) -> (transform: [CharacterTransformFunction], opacity: Double?) {
        let fades = animatesOpacity
        var stops = keyframes
        if stops.first?.offset != 0 {
            stops.insert(CharacterKeyframe(offset: 0, transform: [], opacity: fades ? underlyingOpacity : nil), at: 0)
        }
        if stops.last?.offset != 1 {
            stops.append(CharacterKeyframe(offset: 1, transform: [], opacity: fades ? underlyingOpacity : nil))
        }
        var i = 0
        while i + 2 < stops.count, stops[i + 1].offset <= progress { i += 1 }
        let a = stops[i], b = stops[i + 1]
        let span = b.offset - a.offset
        let local = span > 0 ? min(max((progress - a.offset) / span, 0), 1) : 1
        let p = timing.value(at: local)
        let transform = CharacterTransformFunction.interpolate(a.transform, b.transform, p)
        let opacity: Double? = if let oa = a.opacity, let ob = b.opacity { oa + (ob - oa) * p } else { nil }
        return (transform, opacity)
    }
}

extension CharacterMotion {
    /// The keyframes, durations and easing of `.persona-character` in `web/app/globals.css`
    /// (mirrored by `PersonaCharacterSanitizer.characterCSS`), as data. `nil` for `none`.
    var spec: CharacterMotionSpec? {
        typealias K = CharacterKeyframe
        typealias F = CharacterTransformFunction
        func k(_ offsets: [Double], _ t: [F], opacity: Double? = nil) -> [K] {
            offsets.map { K(offset: $0, transform: t, opacity: opacity) }
        }
        func spec(_ duration: Double, timing: CSSTimingFunction = .easeInOut, _ stops: [[K]]) -> CharacterMotionSpec {
            CharacterMotionSpec(duration: duration, timing: timing, keyframes: stops.flatMap { $0 }.sorted { $0.offset < $1.offset })
        }
        switch self {
        case .none:
            return nil
        case .breathe:
            return spec(4.2, [k([0.5], [.translateY(-1.2), .scaleY(1.02)])])
        case .float:
            return spec(3.8, [k([0.5], [.translateY(-3), .rotate(degrees: 1.5)])])
        case .blink:
            return spec(5.5, timing: .ease, [
                k([0, 0.44, 0.48, 1], [.scaleY(1)], opacity: 1),
                k([0.46], [.scaleY(0.12)], opacity: 0.25),
            ])
        case .glance:
            return spec(2.6, [k([0, 1], [.translateX(0)]), k([0.25], [.translateX(-2)]), k([0.7], [.translateX(2)])])
        case .tilt:
            return spec(3.2, [k([0, 1], [.rotate(degrees: 0)]), k([0.4, 0.6], [.rotate(degrees: -7), .translateY(-1)])])
        case .nod:
            return spec(1.8, [
                k([0, 1], [.translateY(0), .rotate(degrees: 0)]),
                k([0.35], [.translateY(1.8), .rotate(degrees: 4)]),
                k([0.65], [.translateY(-0.5), .rotate(degrees: -1)]),
            ])
        case .sway:
            return spec(3.4, [k([0, 1], [.rotate(degrees: 0)]), k([0.35], [.rotate(degrees: -4)]), k([0.75], [.rotate(degrees: 4)])])
        case .wag:
            return spec(2.4, [k([0, 1], [.rotate(degrees: -6)]), k([0.5], [.rotate(degrees: 8)])])
        case .wagFast:
            return spec(0.65, [k([0, 1], [.rotate(degrees: -14)]), k([0.5], [.rotate(degrees: 16)])])
        case .tap:
            return spec(0.7, [k([0.25, 0.75], [.translateY(-2), .rotate(degrees: -2)]), k([0.5], [.translateY(0), .rotate(degrees: 2)])])
        case .type:
            return spec(0.42, [
                k([0, 1], [.translateY(0)]),
                k([0.25], [.translateY(-1.6), .rotate(degrees: -1.5)]),
                k([0.75], [.translateY(-1.2), .rotate(degrees: 1.5)]),
            ])
        case .bounce:
            return spec(0.95, [k([0, 1], [.translateY(0), .scale(1)]), k([0.45], [.translateY(-3.5), .scale(1.03)])])
        case .wave:
            return spec(1.1, [k([0, 1], [.rotate(degrees: 0)]), k([0.25], [.rotate(degrees: -14)]), k([0.65], [.rotate(degrees: 10)])])
        case .scan:
            return spec(1.7, [k([0, 1], [.translateX(-2.5)]), k([0.5], [.translateX(2.5)])])
        case .orbit:
            return spec(2.4, timing: .linear, [k([1], [.rotate(degrees: 360)])])
        case .spark:
            return spec(1.2, [k([0, 1], [.scale(1)], opacity: 1), k([0.5], [.scale(0.75), .rotate(degrees: 15)], opacity: 0.35)])
        case .pulse:
            return spec(1.8, [k([0, 1], [.scale(1)], opacity: 1), k([0.5], [.scale(1.07)], opacity: 0.65)])
        case .shadow:
            return spec(4.2, [k([0.5], [.scaleX(0.84)], opacity: 0.3)])
        }
    }
}

// MARK: - Rig

/// A sanitized persona character compiled once for native drawing, with each state's animated
/// parts resolved, so a frame is only keyframe sampling and a CoreGraphics pass.
///
/// It reproduces the WebKit page `PersonaCharacterSanitizer.renderHTML` builds: every element
/// pivots about `32px 34px` of the viewBox unless it has a `data-pivot`; an animated element's CSS
/// `transform` replaces its `transform` attribute (WebKit ignores the attribute while a CSS
/// transform applies) and an animated `opacity` replaces its `opacity`; `data-show` layers that
/// don't match the state are hidden; animations start at time 0 with `animation-delay`
/// (`data-delay`), `fill-mode: none`, normal direction and infinite iterations; `currentColor`
/// is the persona's colour. `PersonaCharacterWebKitParityTests` holds the two to the same pixels.
public final class PersonaCharacterRig: Sendable {
    /// The pivot CSS gives every character element (`transform-origin: 32px 34px`).
    static let defaultOrigin = CGPoint(x: 32, y: 34)

    struct AnimatedPart: Equatable, Sendable {
        var path: String
        var spec: CharacterMotionSpec
        var origin: CGPoint
        /// Seconds; negative starts the loop part-way through, positive holds the element still.
        var delay: Double
        var duration: Double
        var underlyingOpacity: Double
    }

    struct StatePlan: Equatable, Sendable {
        var hidden: [String] = []
        var animated: [AnimatedPart] = []
    }

    public let document: MockupSVGDocument
    let plans: [CharacterState: StatePlan]

    /// `nil` when the sanitizer rejects the SVG, which the web view showed as a blank page.
    public init?(svg: String, color: String) {
        guard let root = PersonaCharacterSanitizer.sanitizeCharacterSVG(svg, prefix: "pc-").tree else { return nil }
        var elements: [(path: String, attrs: [String: String])] = []
        let tree = MockupSVGTree(root: Self.convert(root, path: "", color: PersonaCharacterSanitizer.safeHexColor(color), into: &elements))
        let document = MockupSVGDocument(trusted: tree)
        self.document = document

        var plans: [CharacterState: StatePlan] = [:]
        for state in CharacterState.allCases {
            var plan = StatePlan()
            for element in elements {
                let style = PersonaCharacterSanitizer.resolveCharacterNodeStyle(element.attrs, state: state)
                if style.hidden { plan.hidden.append(element.path) }
                guard let spec = style.motion?.spec else { continue }
                plan.animated.append(AnimatedPart(
                    path: element.path,
                    spec: spec,
                    origin: Self.origin(style.transformOrigin),
                    delay: Self.seconds(style.animationDelay),
                    duration: spec.duration * (style.speedMultiplier.flatMap(Double.init) ?? 1),
                    underlyingOpacity: document.node(at: element.path)?.style.opacity ?? 1
                ))
            }
            plans[state] = plan
        }
        self.plans = plans
    }

    /// Whether anything moves in `state`, so a view can skip its display-link timeline.
    public func animates(in state: CharacterState) -> Bool {
        !(plans[state]?.animated.isEmpty ?? true)
    }

    /// Each animated or hidden element's values `t` seconds after the animations started.
    public func overrides(for state: CharacterState, at t: TimeInterval) -> [String: MockupSVGNodeOverride] {
        guard let plan = plans[state] else { return [:] }
        var out: [String: MockupSVGNodeOverride] = [:]
        for path in plan.hidden { out[path] = MockupSVGNodeOverride(opacity: 0) }
        for part in plan.animated {
            let local = t - part.delay
            // Before a positive delay the animation doesn't apply (fill-mode none).
            guard local >= 0, part.duration > 0 else { continue }
            let progress = (local / part.duration).truncatingRemainder(dividingBy: 1)
            let sample = part.spec.sample(at: progress, underlyingOpacity: part.underlyingOpacity)
            out[part.path] = MockupSVGNodeOverride(
                transform: CharacterTransformFunction.affine(sample.transform, origin: part.origin),
                opacity: sample.opacity
            )
        }
        return out
    }

    /// Draws `state` at time `t` into a Y-down context, the viewBox fitted to `rect`.
    public func draw(state: CharacterState, at t: TimeInterval, in ctx: CGContext, rect: CGRect) {
        MockupSVGRenderer.draw(document, in: ctx, rect: rect, options: MockupSVGRenderOptions(nodeOverrides: overrides(for: state, at: t)))
    }

    // MARK: Building

    /// The sanitized node as a renderer tree, collecting every non-root element's path and rig
    /// attributes. Paths index `children` as written, which is how `MockupSVGTree` counts them.
    private static func convert(
        _ node: SanitizedSVGNode,
        path: String,
        color: String,
        into elements: inout [(path: String, attrs: [String: String])]
    ) -> MockupSVGNode {
        var attrs = node.attrs
        if path.isEmpty {
            // renderHTML's root: a fixed viewBox filling the view, coloured by the persona.
            attrs["viewBox"] = "0 0 64 64"
            attrs.removeValue(forKey: "width")
            attrs.removeValue(forKey: "height")
            attrs["color"] = color
        } else {
            elements.append((path, node.attrs))
        }
        let children = node.children.enumerated().map { i, child in
            child.tag == "#text"
                ? MockupSVGNode.text(child.text ?? "")
                : convert(child, path: MockupSVGTree.childPath(path, i), color: color, into: &elements)
        }
        return MockupSVGNode(
            element: node.tag,
            attributes: attrs.keys.sorted().map { MockupSVGAttribute(name: $0, value: attrs[$0] ?? "") },
            children: children
        )
    }

    /// `"Xpx Ypx"` from `parseCharacterPivot`, or CSS's default origin.
    private static func origin(_ css: String?) -> CGPoint {
        guard let css else { return defaultOrigin }
        let v = css.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: "px", with: "")) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : defaultOrigin
    }

    /// `"Ns"` from `parseCharacterDelay`.
    private static func seconds(_ css: String?) -> Double {
        guard var css else { return 0 }
        if css.hasSuffix("s") { css.removeLast() }
        return Double(css) ?? 0
    }
}
