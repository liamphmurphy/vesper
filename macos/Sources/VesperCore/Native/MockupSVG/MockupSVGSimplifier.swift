import CoreGraphics
import Foundation

/// A source brought into mockup SVG profile v1 by `MockupSVGSimplifier`.
public struct MockupSVGSimplified: Equatable, Sendable {
    /// The conforming SVG: the source itself when `isUnchanged`.
    public var svg: String
    /// What couldn't be kept, human-readable and without repeats, in the order first met:
    /// `"<filter>"`, `"filter"` (an attribute), `"CSS rule 'a:hover'"`, `"CSS property 'animation'"`.
    public var dropped: [String]
    /// The source already conformed and is returned as written.
    public var isUnchanged: Bool

    public init(svg: String, dropped: [String], isUnchanged: Bool) {
        self.svg = svg
        self.dropped = dropped
        self.isUnchanged = isUnchanged
    }
}

/// Best-effort conversion of an arbitrary SVG (a chat `svg-image` block, a mockup saved before the
/// profile existed) into mockup SVG profile v1, so the native renderer can draw it without WebKit.
///
/// CSS goes through the normalizer's cascade in lenient mode: what it can't convert is dropped
/// rather than refused. Then each profile violation is repaired where something can be kept (an
/// `<a>` becomes a `<g>`, a nested `<svg>` a transformed `<g>`, `xlink:href` with an undeclared
/// prefix becomes `href`, units become px, a frozen `<animate>` leaves its final value) and
/// otherwise the element or attribute is removed. A removed id takes the references to it next
/// round, so this repeats until the profile passes or a round changes nothing.
public enum MockupSVGSimplifier {
    /// Each round removes at least one thing, and a reference chain rarely runs deeper than this.
    static let maxRounds = 16

    /// nil when the source doesn't parse or can't be made to conform (no size, too deep, too many
    /// elements).
    public static func simplify(_ source: String) -> MockupSVGSimplified? {
        if MockupSVGProfile.conforms(source) { return MockupSVGSimplified(svg: source, dropped: [], isUnchanged: true) }
        guard var tree = try? MockupSVGTree.parse(source) else { return nil }
        var css = MockupSVGCSS(strict: false)
        do {
            _ = try css.apply(to: &tree)
        } catch {
            // Lenient mode records unconvertible CSS instead of throwing.
            return nil
        }
        var repair = Repair(dropped: css.dropped)
        for _ in 0..<maxRounds {
            let violations = MockupSVGProfile.violations(tree)
            if violations.isEmpty {
                return MockupSVGSimplified(svg: tree.serialized(), dropped: repair.dropped, isUnchanged: false)
            }
            guard repair.run(&tree, violations) else { return nil }
        }
        return nil
    }

    private struct Repair {
        var dropped: [String]

        mutating func note(_ label: String) {
            if !dropped.contains(label) { dropped.append(label) }
        }

        /// One round of repairs; false when none applied.
        mutating func run(_ tree: inout MockupSVGTree, _ violations: [MockupSVGViolation]) -> Bool {
            var elementPaths: [String] = []
            for v in violations where v.kind == .element && !v.path.isEmpty && !elementPaths.contains(v.path) {
                elementPaths.append(v.path)
            }
            // An element inside another being repaired is re-checked next round, once its
            // ancestor's fate (removed or rewritten) is settled.
            let pending = Set(elementPaths)
            let targets = elementPaths.filter { !Self.ancestors(of: $0).contains(where: pending.contains) }
            var changed = false

            // Attributes first: changing them moves no path.
            for v in violations {
                guard case .attribute(let name) = v.kind,
                      !targets.contains(where: { v.path == $0 || v.path.hasPrefix($0 + ".") }) else { continue }
                var label: String?
                tree.update(at: v.path) { n in
                    if let result = Self.fixAttribute(&n, name) {
                        changed = true
                        label = result
                    }
                }
                if let label, !label.isEmpty { note(label) }
            }

            // Last path first, so removing one never moves another still to do.
            let ordered = targets.sorted { a, b in
                (MockupSVGTree.indices(of: b) ?? []).lexicographicallyPrecedes(MockupSVGTree.indices(of: a) ?? [])
            }
            for path in ordered {
                if fixElement(&tree, at: path) { changed = true }
            }
            return changed
        }

        static func ancestors(of path: String) -> [String] {
            var out: [String] = []
            var p = path
            while let parent = MockupSVGTree.parentPath(of: p) {
                out.append(parent)
                p = parent
            }
            return out
        }

        // MARK: Attributes

        /// Repairs or removes the attribute: nil when it's already gone, "" when it was repaired
        /// without loss, otherwise what was dropped.
        static func fixAttribute(_ n: inout MockupSVGNode, _ name: String) -> String? {
            guard let i = n.attributes.firstIndex(where: { $0.name == name }) else { return nil }
            let value = n.attributes[i].value
            // Pasted SVGs often use xlink:href without declaring xlink; plain href means the same.
            if name.hasSuffix(":href"), n.attribute("href") == nil {
                n.attributes[i].name = "href"
                return ""
            }
            if let fixed = repairedValue(name, value, element: n.localName), fixed != value {
                n.attributes[i].value = fixed
                let wasList = value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).count > 1
                return wasList && ["x", "y", "dx", "dy"].contains(name) ? "per-character \(name) positions" : ""
            }
            n.attributes.remove(at: i)
            return name
        }

        static let lengthAttributes: Set<String> = ["x", "y", "width", "height", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr",
                                                    "x1", "y1", "x2", "y2", "dx", "dy", "stroke-width", "stroke-dashoffset",
                                                    "font-size", "letter-spacing", "markerWidth", "markerHeight", "refX", "refY"]

        /// A value the profile accepts meaning (nearly) the same, when there is one.
        static func repairedValue(_ name: String, _ value: String, element: String) -> String? {
            let v = MockupSVGCSS.trim(value)
            if ["transform", "gradientTransform", "patternTransform"].contains(name) {
                let fixed = v.replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "deg", with: "")
                return MockupSVGValues.transform(fixed) != nil ? fixed : nil
            }
            guard lengthAttributes.contains(name) else { return nil }
            // Per-character positions: keep the first, which places the run.
            if ["x", "y", "dx", "dy"].contains(name), element == "text" || element == "tspan" {
                let items = v.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                if items.count > 1, let first = items.first, MockupSVGValues.length(String(first), percent: true) != nil {
                    return String(first)
                }
            }
            return pixels(v).map(format)
        }

        /// Absolute CSS units, and em/rem at the 16px default, in px.
        static func pixels(_ v: String) -> Double? {
            let units: [(String, Double)] = [("rem", 16), ("em", 16), ("pt", 4.0 / 3), ("pc", 16), ("mm", 96 / 25.4),
                                             ("cm", 96 / 2.54), ("in", 96), ("q", 96 / 101.6)]
            let lower = v.lowercased()
            for (unit, scale) in units where lower.hasSuffix(unit) {
                guard let n = MockupSVGValues.number(String(lower.dropLast(unit.count))) else { return nil }
                return n * scale
            }
            return nil
        }

        static func format(_ v: Double) -> String {
            let rounded = (v * 1000).rounded() / 1000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }

        // MARK: Elements

        mutating func fixElement(_ tree: inout MockupSVGTree, at path: String) -> Bool {
            guard let n = tree.node(at: path), let parentPath = MockupSVGTree.parentPath(of: path),
                  let index = MockupSVGTree.indices(of: path)?.last else { return false }
            let isSVG = Self.namespace(of: path, in: tree) == MockupSVGProfile.svgNS
            switch isSVG ? n.localName : "" {
            case "a":
                note("<a> links")
                return tree.update(at: path) { n in
                    Self.rename(&n, to: "g")
                    n.attributes.removeAll { a in
                        a.name == "href" || a.name.hasSuffix(":href")
                            || ["target", "download", "rel", "hreflang", "type", "referrerpolicy", "ping"].contains(a.name)
                    }
                }
            case "switch":
                note("<switch>")
                return tree.update(at: path) { n in
                    Self.rename(&n, to: "g")
                    n.attributes.removeAll { ["requiredFeatures", "requiredExtensions", "systemLanguage"].contains($0.name) }
                    // A renderer draws the first child whose conditions hold; with none, that's the first.
                    if let first = n.children.firstIndex(where: \.isElement) {
                        n.children = n.children.enumerated().filter { !$0.element.isElement || $0.offset == first }.map(\.element)
                    }
                }
            case "svg":
                note("nested <svg> clipping")
                return tree.update(at: path) { n in Self.flattenNestedSVG(&n) }
            case "textPath":
                note("<textPath>")
                return tree.update(at: path) { n in n = .text(n.textContent) }
            case "animate", "set":
                Self.freeze(n, into: &tree, parentPath: parentPath)
                fallthrough
            default:
                note(isSVG ? "<\(n.localName)>" : "<\(n.name)>")
                return tree.update(at: parentPath) { parent in MockupSVGCSS.removeChild(at: index, of: &parent) }
            }
        }

        /// The namespace of the element at `path`, from the declarations on it and its ancestors.
        static func namespace(of path: String, in tree: MockupSVGTree) -> String? {
            guard let indices = MockupSVGTree.indices(of: path) else { return nil }
            var ns = MockupSVGProfile.Namespaces().entering(tree.root)
            var n = tree.root
            for i in indices {
                n = n.children[i]
                ns = ns.entering(n)
            }
            return ns.namespace(of: n.name)
        }

        static func rename(_ n: inout MockupSVGNode, to local: String) {
            if let colon = n.name.lastIndex(of: ":") {
                n.name = String(n.name[...colon]) + local
            } else {
                n.name = local
            }
        }

        /// A still picture shows where a frozen animation ends: fade-ins start at opacity 0.
        static func freeze(_ animation: MockupSVGNode, into tree: inout MockupSVGTree, parentPath: String) {
            guard animation.attribute("fill") == "freeze", animation.attribute("repeatCount") != "indefinite",
                  let attribute = animation.attribute("attributeName"), !attribute.contains(":") else { return }
            let final = animation.attribute("to")
                ?? animation.attribute("values")?.split(separator: ";").last.map { MockupSVGCSS.trim(String($0)) }
            guard let final, !final.isEmpty else { return }
            tree.update(at: parentPath) { $0.setAttribute(attribute, final) }
        }

        /// A nested viewport becomes a group with its placement and viewBox scaling as a transform;
        /// only its clipping is lost.
        static func flattenNestedSVG(_ n: inout MockupSVGNode) {
            func number(_ name: String) -> Double? {
                guard let raw = n.attribute(name), case .number(let v)? = MockupSVGValues.length(raw, percent: false) else { return nil }
                return v
            }
            var transforms: [String] = n.attribute("transform").map { [$0] } ?? []
            let x = number("x") ?? 0, y = number("y") ?? 0
            if x != 0 || y != 0 { transforms.append("translate(\(format(x)) \(format(y)))") }
            if let vb = n.attribute("viewBox").flatMap(MockupSVGValues.viewBox), vb.width > 0, vb.height > 0 {
                let w = number("width") ?? vb.width, h = number("height") ?? vb.height
                var sx = w / vb.width, sy = h / vb.height
                var tx = 0.0, ty = 0.0
                if n.attribute("preserveAspectRatio").map({ MockupSVGCSS.trim($0).hasPrefix("none") }) != true {
                    // The default, xMidYMid meet.
                    let s = min(sx, sy)
                    sx = s
                    sy = s
                    tx = (w - vb.width * s) / 2
                    ty = (h - vb.height * s) / 2
                }
                let e = tx - vb.minX * sx, f = ty - vb.minY * sy
                if sx != 1 || sy != 1 || e != 0 || f != 0 {
                    transforms.append("matrix(\(format(sx)) 0 0 \(format(sy)) \(format(e)) \(format(f)))")
                }
            }
            let viewport: Set<String> = ["x", "y", "width", "height", "viewBox", "preserveAspectRatio", "transform"]
            n.attributes.removeAll { viewport.contains($0.name) }
            if !transforms.isEmpty { n.attributes.append(MockupSVGAttribute(name: "transform", value: transforms.joined(separator: " "))) }
            rename(&n, to: "g")
        }
    }
}

public extension MockupSVGDocument {
    /// The source compiled for drawing after `MockupSVGSimplifier` brought it into the profile,
    /// with what had to be dropped; nil when it can't be.
    static func simplified(_ source: String) -> (document: MockupSVGDocument, dropped: [String])? {
        guard let s = MockupSVGSimplifier.simplify(source), let document = try? MockupSVGDocument(source: s.svg) else { return nil }
        return (document, s.dropped)
    }
}
