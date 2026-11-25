import Foundation

/// One way a source falls outside mockup SVG profile v1.
public struct MockupSVGViolation: Equatable, Sendable {
    /// The element's path in the tree ("" for the root or a parse error).
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Mockup SVG profile v1 (`docs/dev/mockup-svg-profile.md`): the subset the native renderer draws
/// completely. The server's `ValidateMockupProfile` enforces the same rules; the shared corpus in
/// `testdata/mockup-svg/` keeps the two in step.
public enum MockupSVGProfile {
    static let svgNS = "http://www.w3.org/2000/svg"
    static let xlinkNS = "http://www.w3.org/1999/xlink"
    static let maxElements = 5000
    static let maxDepth = 32

    static let drawn: Set<String> = ["svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
                                     "text", "tspan", "image", "use"]
    static let referenced: Set<String> = ["defs", "symbol", "linearGradient", "radialGradient", "stop", "clipPath",
                                          "mask", "pattern", "marker"]
    /// Never drawn, so anything goes inside them.
    static let ignoredElements: Set<String> = ["title", "desc", "metadata"]
    static let ignoredAttributes: Set<String> = ["version", "baseProfile", "role", "focusable", "pointer-events", "xmlns"]

    public static func conforms(_ source: String) -> Bool { violations(source).isEmpty }

    public static func violations(_ source: String) -> [MockupSVGViolation] {
        let tree: MockupSVGTree
        do {
            tree = try MockupSVGTree.parse(source)
        } catch {
            return [MockupSVGViolation(path: "", message: "Not well-formed SVG: \(error.description)")]
        }
        return violations(tree)
    }

    static func violations(_ tree: MockupSVGTree) -> [MockupSVGViolation] {
        var c = Checker(tree: tree)
        c.run()
        return c.problems
    }

    // MARK: Checker

    private struct Ref {
        let path: String
        let element: String
        let attribute: String
        let id: String
        let kinds: Set<String>?
    }

    private struct Checker {
        let tree: MockupSVGTree
        var problems: [MockupSVGViolation] = []
        var ids: [String: (path: String, name: String)] = [:]
        var refs: [Ref] = []
        var elements = 0
        var reportedDepth = false

        init(tree: MockupSVGTree) { self.tree = tree }

        mutating func add(_ path: String, _ element: String, _ message: String) {
            problems.append(MockupSVGViolation(path: path, message: "<\(element)> \(message)"))
        }

        mutating func run() {
            collectIDs(tree.root, path: "", ns: Namespaces())
            let rootNS = Namespaces().entering(tree.root)
            if tree.root.localName != "svg" || rootNS.namespace(of: tree.root.name) != svgNS {
                add("", tree.root.localName, "must be <svg xmlns=\"http://www.w3.org/2000/svg\">")
                return
            }
            checkRootSize()
            walk(tree.root, path: "", depth: 1, ns: Namespaces(), isRoot: true)
            if elements > maxElements {
                add("", "svg", "has \(elements) elements; mockups are limited to \(maxElements)")
            }
            checkRefs()
            checkUseCycles()
        }

        mutating func collectIDs(_ n: MockupSVGNode, path: String, ns: Namespaces) {
            let ns = ns.entering(n)
            if Self.isIgnored(n, ns) { return }
            if let id = n.attribute("id"), ids[id] == nil { ids[id] = (path, n.localName) }
            for (i, c) in n.children.enumerated() where c.isElement {
                collectIDs(c, path: MockupSVGTree.childPath(path, i), ns: ns)
            }
        }

        static func isIgnored(_ n: MockupSVGNode, _ ns: Namespaces) -> Bool {
            ns.namespace(of: n.name) == svgNS && ignoredElements.contains(n.localName)
        }

        mutating func checkRootSize() {
            let root = tree.root
            if let vb = root.attribute("viewBox") {
                if MockupSVGValues.viewBox(vb).map({ $0.width > 0 && $0.height > 0 }) != true {
                    add("", "svg", "viewBox \"\(vb)\" needs four numbers with a positive width and height")
                }
                return
            }
            let size = { (v: String?) -> Double? in
                guard let v, case .number(let n)? = MockupSVGValues.length(v, percent: false), n > 0 else { return nil }
                return n
            }
            if size(root.attribute("width")) == nil || size(root.attribute("height")) == nil {
                add("", "svg", "needs a viewBox such as viewBox=\"0 0 1280 800\" (or numeric width and height) so it has one size")
            }
        }

        mutating func walk(_ n: MockupSVGNode, path: String, depth: Int, ns parent: Namespaces, isRoot: Bool) {
            elements += 1
            let ns = parent.entering(n)
            let name = n.localName
            if depth > maxDepth, !reportedDepth {
                reportedDepth = true
                add(path, name, "is nested \(depth) deep; mockups are limited to \(maxDepth) levels")
            }
            guard ns.namespace(of: n.name) == svgNS else {
                add(path, name, "isn't an SVG element; use only SVG elements in the SVG namespace")
                return
            }
            if ignoredElements.contains(name) { return }
            if name == "svg", !isRoot {
                add(path, name, "can't be nested; use <g transform=\"translate(x y)\"> or <symbol> with <use>")
            } else if name == "style" {
                add(path, name, "isn't allowed in mockups; use presentation attributes such as fill=\"#fff\" on the elements")
            } else if !drawn.contains(name), !referenced.contains(name) {
                add(path, name, "isn't supported in mockups (\(Self.hint(name)))")
            }
            for a in n.attributes { checkAttribute(a, element: n, path: path, ns: ns) }
            for (i, c) in n.children.enumerated() where c.isElement {
                walk(c, path: MockupSVGTree.childPath(path, i), depth: depth + 1, ns: ns, isRoot: false)
            }
        }

        static func hint(_ name: String) -> String {
            if name == "filter" || name.hasPrefix("fe") { return "filters aren't drawn; use solid fills, gradients or opacity" }
            if name.hasPrefix("animate") || name == "set" { return "a mockup is a still picture" }
            if name == "a" { return "links don't draw; use the shapes directly" }
            if name == "textPath" { return "put text on a straight line with <text x y>" }
            if name == "foreignObject" { return "draw it with SVG shapes and <text>" }
            return "use only the elements listed in the mockup SVG profile"
        }

        mutating func checkAttribute(_ a: MockupSVGAttribute, element n: MockupSVGNode, path: String, ns: Namespaces) {
            let el = n.localName
            if a.name.hasPrefix("xmlns:") || a.name == "xmlns" { return }
            if let colon = a.name.firstIndex(of: ":") {
                let prefix = String(a.name[..<colon]), local = String(a.name[a.name.index(after: colon)...])
                if prefix == "xml" {
                    if local == "space" || local == "lang" { return }
                    add(path, el, "attribute \(a.name) isn't supported")
                } else if ns.prefixes[prefix] == xlinkNS, local == "href" {
                    checkHref(a.value, element: n, path: path)
                } else {
                    add(path, el, "attribute \(a.name) isn't supported in mockups")
                }
                return
            }
            let name = a.name
            if ignoredAttributes.contains(name) || name.hasPrefix("aria-") || name.hasPrefix("data-") { return }
            switch name {
            case "class", "style":
                add(path, el, "attribute \(name) isn't allowed in mockups; use presentation attributes such as fill=\"#fff\" or stroke-width=\"2\"")
                return
            case "href":
                checkHref(a.value, element: n, path: path)
                return
            default:
                break
            }
            guard let rule = Self.rules[name] else {
                add(path, el, "attribute \(name) isn't supported in mockups")
                return
            }
            let v = a.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch rule {
            case .check(let ok, let hint):
                if !ok(v) { add(path, el, "\(name)=\"\(a.value)\": \(hint)") }
            case .paint:
                guard let p = MockupSVGValues.paint(v) else {
                    add(path, el, "\(name)=\"\(a.value)\": \(Self.colorHint), none or url(#gradient)")
                    return
                }
                if case .url(let id, _) = p {
                    refs.append(Ref(path: path, element: el, attribute: name, id: id, kinds: ["linearGradient", "radialGradient", "pattern"]))
                }
            case .reference(let kind):
                guard let id = MockupSVGValues.reference(v) else {
                    add(path, el, "\(name)=\"\(a.value)\": use none or url(#id) pointing at a <\(kind)>")
                    return
                }
                if !id.isEmpty { refs.append(Ref(path: path, element: el, attribute: name, id: id, kinds: [kind])) }
            }
        }

        mutating func checkHref(_ raw: String, element n: MockupSVGNode, path: String) {
            let el = n.localName
            switch el {
            case "image":
                if MockupSVGValues.imageData(raw) == nil {
                    add(path, el, "href must be a data:image/png, jpeg, gif or webp base64 URI")
                }
            case "use":
                if let id = MockupSVGValues.fragment(raw) {
                    refs.append(Ref(path: path, element: el, attribute: "href", id: id, kinds: nil))
                } else {
                    add(path, el, "href must point at an element in this file, like href=\"#card\"")
                }
            case "linearGradient", "radialGradient":
                if let id = MockupSVGValues.fragment(raw) {
                    refs.append(Ref(path: path, element: el, attribute: "href", id: id, kinds: ["linearGradient", "radialGradient"]))
                } else {
                    add(path, el, "href must point at another gradient, like href=\"#base\"")
                }
            default:
                add(path, el, "attribute href isn't supported here; only <use>, <image> and gradients take one")
            }
        }

        mutating func checkRefs() {
            for r in refs {
                guard let target = ids[r.id] else {
                    add(r.path, r.element, "\(r.attribute) points at #\(r.id), which isn't in this file")
                    continue
                }
                if let kinds = r.kinds, !kinds.contains(target.name) {
                    add(r.path, r.element, "\(r.attribute) points at <\(target.name) id=\"\(r.id)\">, which isn't a \(kinds.sorted().joined(separator: " or "))")
                }
            }
        }

        /// Following element→child and use→target edges, a cycle means drawing never ends.
        mutating func checkUseCycles() {
            var state: [String: Int] = [:] // 1 active, 2 done
            var reported = false
            func targets(_ path: String) -> [String] {
                guard let n = tree.node(at: path) else { return [] }
                var out = n.children.enumerated().filter { $0.element.isElement }.map { MockupSVGTree.childPath(path, $0.offset) }
                if n.localName == "use", let raw = n.attribute("href") ?? n.attributes.first(where: { $0.name.hasSuffix(":href") })?.value,
                   let id = MockupSVGValues.fragment(raw), let t = ids[id] {
                    out.append(t.path)
                }
                return out
            }
            var stack: [(path: String, next: [String], i: Int)] = [("", targets(""), 0)]
            state[""] = 1
            while !stack.isEmpty, !reported {
                let top = stack.count - 1
                if stack[top].i == stack[top].next.count {
                    state[stack[top].path] = 2
                    stack.removeLast()
                    continue
                }
                let child = stack[top].next[stack[top].i]
                stack[top].i += 1
                switch state[child] {
                case 1:
                    let from = stack[top].path
                    add(from, tree.node(at: from)?.localName ?? "use", "makes a cycle: it uses an element that contains it; point <use> at a separate element in <defs>")
                    reported = true
                case 2:
                    continue
                default:
                    state[child] = 1
                    stack.append((child, targets(child), 0))
                }
            }
        }

        // MARK: Rules

        enum Rule: Sendable {
            case check(@Sendable (String) -> Bool, String)
            case paint
            case reference(String)
        }

        static let colorHint = "use #rgb, #rrggbb, rgb(), hsl(), a CSS colour name, transparent or currentColor"

        static let rules: [String: Rule] = {
            let pct: Rule = .check({ MockupSVGValues.length($0, percent: true) != nil }, "use a number or px (or %)")
            let len: Rule = .check({ MockupSVGValues.length($0, percent: false) != nil }, "use a number or px")
            let unit: Rule = .check({ MockupSVGValues.length($0, percent: true) != nil }, "use a number from 0 to 1 (or a percentage)")
            let num: Rule = .check({ MockupSVGValues.number($0) != nil }, "use a number")
            let xform: Rule = .check({ MockupSVGValues.transform($0) != nil }, "use matrix(), translate(), scale(), rotate(), skewX() or skewY() with numbers")
            let color: Rule = .check({ MockupSVGValues.color($0) != nil }, Checker.colorHint)
            func enumeration(_ values: [String]) -> Rule {
                .check({ Set(values).contains($0) }, "use one of " + values.joined(separator: ", "))
            }
            let units = enumeration(["userSpaceOnUse", "objectBoundingBox"])
            var r: [String: Rule] = [
                "id": .check({ $0.range(of: #"^[A-Za-z_][\w.:-]*$"#, options: .regularExpression) != nil }, "ids start with a letter or _ and contain letters, digits, _ . : or -"),
                "viewBox": .check({ MockupSVGValues.viewBox($0).map { $0.width > 0 && $0.height > 0 } == true }, "use four numbers with a positive width and height, like 0 0 1280 800"),
                "preserveAspectRatio": .check({ MockupSVGValues.aspectRatio($0) != nil }, "use none or xMidYMid (any x/y Min/Mid/Max) with optional meet or slice"),
                "rx": .check({ $0 == "auto" || MockupSVGValues.length($0, percent: true) != nil }, "use a number, px, % or auto"),
                "dx": len, "dy": len,
                "points": .check({ MockupSVGValues.points($0) != nil }, "use pairs of numbers, like 0,0 10,20"),
                "d": .check({ MockupSVGPathData.isValid($0) }, "isn't valid path data; use M L H V C S Q T A Z with their numbers"),
                "transform": xform, "gradientTransform": xform, "patternTransform": xform,
                "fill": .paint, "stroke": .paint,
                "fill-opacity": unit, "stroke-opacity": unit, "opacity": unit, "stop-opacity": unit, "offset": unit,
                "fill-rule": enumeration(["nonzero", "evenodd"]), "clip-rule": enumeration(["nonzero", "evenodd"]),
                "stroke-width": len, "stroke-dashoffset": len,
                "stroke-dasharray": .check({ MockupSVGValues.dashArray($0) != nil }, "use none or a list of non-negative lengths, like 4 2"),
                "stroke-linecap": enumeration(["butt", "round", "square"]),
                "stroke-linejoin": enumeration(["miter", "round", "bevel"]),
                "stroke-miterlimit": num,
                "color": color, "stop-color": color,
                "display": enumeration(["inline", "block", "none"]),
                "visibility": enumeration(["visible", "hidden", "collapse"]),
                "clip-path": .reference("clipPath"), "mask": .reference("mask"),
                "marker-start": .reference("marker"), "marker-mid": .reference("marker"), "marker-end": .reference("marker"),
                "clipPathUnits": units, "maskUnits": units, "maskContentUnits": units, "gradientUnits": units,
                "patternUnits": units, "patternContentUnits": units,
                "spreadMethod": enumeration(["pad", "reflect", "repeat"]),
                "markerWidth": len, "markerHeight": len, "refX": len, "refY": len,
                "markerUnits": enumeration(["strokeWidth", "userSpaceOnUse"]),
                "orient": .check({ $0 == "auto" || $0 == "auto-start-reverse" || MockupSVGValues.number($0.hasSuffix("deg") ? String($0.dropLast(3)) : $0) != nil }, "use auto, auto-start-reverse or an angle in degrees"),
                "font-family": .check({ !$0.isEmpty }, "name a font family, like Inter, sans-serif"),
                "font-size": len,
                "font-weight": .check({ MockupSVGValues.fontWeight($0) != nil }, "use normal, bold, bolder, lighter or 100 to 900"),
                "font-style": enumeration(["normal", "italic", "oblique"]),
                "text-anchor": enumeration(["start", "middle", "end"]),
                "dominant-baseline": enumeration(["auto", "alphabetic", "middle", "central", "hanging"]),
                "letter-spacing": .check({ $0 == "normal" || MockupSVGValues.length($0, percent: false) != nil }, "use normal or a number"),
                "text-decoration": enumeration(["none", "underline", "line-through"]),
            ]
            for name in ["x", "y", "width", "height", "cx", "cy", "r", "fx", "fy", "fr", "x1", "y1", "x2", "y2"] { r[name] = pct }
            r["ry"] = r["rx"]
            return r
        }()
    }

    /// In-scope namespace declarations, enough to tell SVG elements and xlink attributes apart.
    struct Namespaces {
        var defaultNS: String?
        var prefixes: [String: String] = ["xml": "http://www.w3.org/XML/1998/namespace"]

        func entering(_ n: MockupSVGNode) -> Namespaces {
            var next = self
            for a in n.attributes {
                if a.name == "xmlns" { next.defaultNS = a.value }
                else if a.name.hasPrefix("xmlns:") { next.prefixes[String(a.name.dropFirst(6))] = a.value }
            }
            return next
        }

        func namespace(of qualified: String) -> String? {
            guard let colon = qualified.firstIndex(of: ":") else { return defaultNS }
            return prefixes[String(qualified[..<colon])]
        }
    }
}

/// SVG path data grammar: every command with whole groups of arguments, arc flags as 0 or 1,
/// starting with a moveto. Empty data is valid and draws nothing.
enum MockupSVGPathData {
    static func isValid(_ d: String) -> Bool {
        let arity: [UInt8: Int] = [0x4D: 2, 0x4C: 2, 0x48: 1, 0x56: 1, 0x43: 6, 0x53: 4, 0x51: 4, 0x54: 2, 0x41: 7, 0x5A: 0]
        var s = MockupSVGValues.Scanner(d)
        s.skipSpace()
        var first = true
        while !s.atEnd {
            s.skipCommaSpace()
            guard let c = s.peek() else { break }
            let upper = c & ~0x20
            guard (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A), let n = arity[upper] else { return false }
            if first, upper != 0x4D { return false }
            first = false
            s.i += 1
            if n == 0 { continue }
            var groups = 0
            while true {
                s.skipCommaSpace()
                guard let next = s.peek() else { break }
                let isLetter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
                if isLetter, next != 0x65, next != 0x45 { break }
                for k in 0..<n {
                    s.skipCommaSpace()
                    if upper == 0x41, k == 3 || k == 4 {
                        guard s.flag() != nil else { return false }
                    } else {
                        guard s.number() != nil else { return false }
                    }
                }
                groups += 1
            }
            if groups == 0 { return false }
        }
        return true
    }
}
