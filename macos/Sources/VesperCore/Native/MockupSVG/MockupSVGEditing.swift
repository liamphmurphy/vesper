import CoreGraphics
import Foundation

public enum MockupSVGShapeKind: String, CaseIterable, Sendable {
    case rect, ellipse, line, text
}

/// The source after an edit and the element path the editor should select (nil clears it).
public struct MockupSVGEditResult: Equatable, Sendable {
    public var source: String
    public var selection: String?

    public init(source: String, selection: String?) {
        self.source = source
        self.selection = selection
    }
}

/// The native mockup editor's operations, as pure functions from source to source.
///
/// Each parses the source into a `MockupSVGTree`, changes only the nodes it is about and
/// serializes, so everything else stays byte-for-byte what the person wrote (the tree keeps
/// attribute order, comments and whitespace). Paths are `MockupSVGTree` paths. Every op returns
/// nil when it doesn't apply: an unparsable source, a path that isn't an element, or no change.
public enum MockupSVGEditing {

    // MARK: Moving and attributes

    /// Moves an element by `dx`/`dy` in its parent's user space, merging into a leading
    /// `translate(…)` so repeated drags don't grow the attribute.
    public static func translate(_ source: String, path: String, dx: Double, dy: Double) -> MockupSVGEditResult? {
        guard dx.isFinite, dy.isFinite, number(dx) != "0" || number(dy) != "0" else { return nil }
        return apply(source) { tree in
            guard !path.isEmpty, element(tree, path) != nil else { return nil }
            var ok = false
            tree.update(at: path) { ok = translate(&$0, dx: dx, dy: dy) }
            return ok ? .path(path) : nil
        }
    }

    /// Sets an attribute in place (keeping its position) or, with nil or "", removes it. The
    /// caller validates the value against the profile; this only refuses names XML can't hold.
    public static func setAttribute(_ source: String, path: String, name: String, value: String?) -> MockupSVGEditResult? {
        guard isXMLName(name) else { return nil }
        let value = value?.isEmpty == true ? nil : value
        return apply(source) { tree in
            guard element(tree, path) != nil else { return nil }
            tree.update(at: path) { $0.setAttribute(name, value) }
            return .path(path)
        }
    }

    /// Replaces the text of a `<text>` (its first `<tspan>` when it has one, as the web editor
    /// did) or of a `<tspan>`. Only the holder's text and CDATA nodes are replaced, by one text
    /// node where the first of them was; its element children and comments stay.
    public static func setText(_ source: String, path: String, text: String) -> MockupSVGEditResult? {
        apply(source) { tree in
            guard let el = element(tree, path), el.localName == "text" || el.localName == "tspan" else { return nil }
            var holder = path
            if el.localName == "text", let i = el.children.firstIndex(where: { $0.isElement && $0.localName == "tspan" }) {
                holder = MockupSVGTree.childPath(path, i)
            }
            tree.update(at: holder) { h in
                let isText: (MockupSVGNode) -> Bool = { $0.kind == .text || $0.kind == .cdata }
                // Text nodes are only removed at or after `first`, so it stays a valid insertion index.
                let first = h.children.firstIndex(where: isText) ?? 0
                h.children.removeAll(where: isText)
                if !text.isEmpty { h.children.insert(.text(text), at: first) }
            }
            return .path(path)
        }
    }

    // MARK: Structure

    /// Inserts a deep copy right after the element, offset by 16 user units, with the same
    /// leading whitespace so the source stays indented. `id` and `data-vid` are stripped from the
    /// copy and its descendants: ids must stay unique, and a canvas `data-vid` names one element.
    public static func duplicate(_ source: String, path: String) -> MockupSVGEditResult? {
        apply(source) { tree in
            guard let (parent, index) = location(of: path), var copy = element(tree, path) else { return nil }
            stripIdentity(&copy)
            guard translate(&copy, dx: 16, dy: 16) else { return nil }
            var selection = ""
            tree.update(at: parent) { p in
                var inserted = [copy]
                if index > 0, isWhitespaceText(p.children[index - 1]) { inserted.insert(p.children[index - 1], at: 0) }
                p.children.insert(contentsOf: inserted, at: index + 1)
                selection = MockupSVGTree.childPath(parent, index + inserted.count)
            }
            return .path(selection)
        }
    }

    /// Removes the element and the whitespace-only text node right before it (its indentation).
    /// Refuses the root, and an element whose id (or a descendant's) is still referenced from
    /// the rest of the document, since the profile rejects references to missing ids.
    public static func delete(_ source: String, path: String) -> MockupSVGEditResult? {
        apply(source) { tree in
            guard let (parent, index) = location(of: path), let removed = element(tree, path) else { return nil }
            tree.update(at: parent) { p in
                p.children.remove(at: index)
                if index > 0, isWhitespaceText(p.children[index - 1]) { p.children.remove(at: index - 1) }
            }
            var ids = Set<String>()
            collectIDs(removed, into: &ids)
            var refs = Set<String>()
            collectReferences(tree.root, into: &refs)
            return ids.isDisjoint(with: refs) ? .cleared : nil
        }
    }

    public static func bringForward(_ source: String, path: String) -> MockupSVGEditResult? {
        reorder(source, path: path, .forward)
    }

    public static func sendBackward(_ source: String, path: String) -> MockupSVGEditResult? {
        reorder(source, path: path, .backward)
    }

    public static func bringToFront(_ source: String, path: String) -> MockupSVGEditResult? {
        reorder(source, path: path, .front)
    }

    public static func sendToBack(_ source: String, path: String) -> MockupSVGEditResult? {
        reorder(source, path: path, .back)
    }

    /// Appends a shape to the root with the web editor's defaults, centred on `center` (the
    /// viewBox centre when nil), indented like the root's last element and placed before the
    /// whitespace that closes the root so `</svg>` keeps its own line.
    public static func insert(_ source: String, kind: MockupSVGShapeKind, center: CGPoint?) -> MockupSVGEditResult? {
        if let center, !center.x.isFinite || !center.y.isFinite { return nil }
        return apply(source) { tree in
            let vb = viewBox(of: tree.root)
            // `(v + 0.5).rounded(.down)` is JS `Math.round`: halves go up, also below zero.
            let cx = center.map { Double($0.x) } ?? (Double(vb.midX) + 0.5).rounded(.down)
            let cy = center.map { Double($0.y) } ?? (Double(vb.midY) + 0.5).rounded(.down)
            let element = newShape(kind, cx: cx, cy: cy)
            let children = tree.root.children
            var indent = "\n  "
            if let last = children.lastIndex(where: \.isElement), last > 0, isWhitespaceText(children[last - 1]) {
                indent = children[last - 1].text
            }
            var at = children.count
            if let tail = children.last, isWhitespaceText(tail) { at -= 1 }
            tree.root.children.insert(contentsOf: [.text(indent), element], at: at)
            return .path(MockupSVGTree.childPath("", at + 1))
        }
    }

    // MARK: Resize

    /// Resizes an element from bbox `old` to bbox `new`, both in the element's own user space
    /// (before its `transform`). Geometry attributes are rewritten where the element has them;
    /// paths, groups and the rest get a scale-and-offset `matrix(…)` at the END of their
    /// transform list: SVG applies the rightmost transform first, so that is where a map in the
    /// element's own space belongs. A trailing matrix is merged rather than stacked, and a leading
    /// `translate` (from `translate`) stays first, so neither grows over repeated edits.
    public static func resize(_ source: String, path: String, from old: CGRect, to new: CGRect) -> MockupSVGEditResult? {
        let o = old.standardized, n = new.standardized
        guard [o.minX, o.minY, o.width, o.height, n.minX, n.minY, n.width, n.height].allSatisfy(\.isFinite) else { return nil }
        let map = AxisMap(old: o, new: n)
        return apply(source) { tree in
            guard !path.isEmpty, element(tree, path) != nil else { return nil }
            let vb = viewBox(of: tree.root)
            var ok = false
            tree.update(at: path) { ok = resize(&$0, map, n, vb) }
            return ok ? .path(path) : nil
        }
    }

    // MARK: Numbers

    /// The one number format every op writes: the shortest decimal with at most `fractionDigits`
    /// fraction digits, no trailing zeros, no exponent and never "-0" (16, 16.5, 0.33, -2).
    public static func number(_ value: Double, fractionDigits: Int = 2) -> String {
        guard value.isFinite else { return "0" }
        let scale = pow(10, Double(fractionDigits))
        // Past 2^53 a Double has no fraction digits, and scaling would only lose integer precision.
        let rounded = abs(value) >= 0x1p53 ? value : (value * scale).rounded() / scale
        if rounded == 0 { return "0" }
        var out = String(format: "%.\(fractionDigits)f", rounded)
        if out.contains(".") {
            while out.hasSuffix("0") { out.removeLast() }
            if out.hasSuffix(".") { out.removeLast() }
        }
        return out
    }

    // MARK: - Internals

    private enum Selection {
        case path(String)
        case cleared
    }

    private static func apply(_ source: String, _ body: (inout MockupSVGTree) -> Selection?) -> MockupSVGEditResult? {
        guard let original = try? MockupSVGTree.parse(source) else { return nil }
        var tree = original
        guard let selection = body(&tree), tree != original else { return nil }
        switch selection {
        case .path(let p): return MockupSVGEditResult(source: tree.serialized(), selection: p)
        case .cleared: return MockupSVGEditResult(source: tree.serialized(), selection: nil)
        }
    }

    private static func element(_ tree: MockupSVGTree, _ path: String) -> MockupSVGNode? {
        guard let n = tree.node(at: path), n.isElement else { return nil }
        return n
    }

    /// The parent path and child index of a non-root path.
    private static func location(of path: String) -> (parent: String, index: Int)? {
        guard let parent = MockupSVGTree.parentPath(of: path), let index = MockupSVGTree.indices(of: path)?.last else { return nil }
        return (parent, index)
    }

    private static func isWhitespaceText(_ n: MockupSVGNode) -> Bool {
        n.kind == .text && n.text.allSatisfy(\.isWhitespace)
    }

    private static func isXMLName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == ":" || first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            $0 == ":" || $0 == "_" || $0 == "-" || $0 == "." || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func stripIdentity(_ n: inout MockupSVGNode) {
        guard n.isElement else { return }
        n.setAttribute("id", nil)
        n.setAttribute("data-vid", nil)
        for i in n.children.indices { stripIdentity(&n.children[i]) }
    }

    private static func collectIDs(_ n: MockupSVGNode, into ids: inout Set<String>) {
        if let id = n.attribute("id") { ids.insert(id) }
        for c in n.children where c.isElement { collectIDs(c, into: &ids) }
    }

    /// Ids named by `href="#id"` and `url(#id)` anywhere in the subtree.
    private static func collectReferences(_ n: MockupSVGNode, into refs: inout Set<String>) {
        for a in n.attributes {
            if a.name == "href" || a.name == "xlink:href", a.value.hasPrefix("#") {
                refs.insert(String(a.value.dropFirst()))
            }
            var rest = a.value[...]
            while let open = rest.range(of: "url("), let close = rest[open.upperBound...].firstIndex(of: ")") {
                let target = rest[open.upperBound..<close].trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'"))
                if target.hasPrefix("#") { refs.insert(String(target.dropFirst())) }
                rest = rest[rest.index(after: close)...]
            }
        }
        for c in n.children where c.isElement { collectReferences(c, into: &refs) }
    }

    // MARK: Reordering

    private enum Reorder {
        case forward, backward, front, back
    }

    private static func reorder(_ source: String, path: String, _ mode: Reorder) -> MockupSVGEditResult? {
        apply(source) { tree in
            guard let (parent, index) = location(of: path), element(tree, path) != nil else { return nil }
            var moved: Int?
            tree.update(at: parent) { moved = move(&$0.children, index, mode) }
            return moved.map { .path(MockupSVGTree.childPath(parent, $0)) }
        }
    }

    /// Where an element's unit starts: the element plus the whitespace and comments right before
    /// it. Moving whole units keeps indentation and a comment labelling an element attached to
    /// it, and makes forward-then-backward an exact inverse.
    private static func unitStart(_ c: [MockupSVGNode], _ index: Int) -> Int {
        var s = index
        while s > 0, c[s - 1].kind == .comment || isWhitespaceText(c[s - 1]) { s -= 1 }
        return s
    }

    /// Moves the unit of the element at `index`; returns the element's new index.
    private static func move(_ c: inout [MockupSVGNode], _ index: Int, _ mode: Reorder) -> Int? {
        let elements = c.indices.filter { c[$0].isElement }
        guard let pos = elements.firstIndex(of: index) else { return nil }
        var target: Int
        switch mode {
        case .forward, .front:
            guard pos + 1 < elements.count else { return nil }
            target = (mode == .forward ? elements[pos + 1] : elements[elements.count - 1]) + 1
        case .backward, .back:
            guard pos > 0 else { return nil }
            target = unitStart(c, mode == .backward ? elements[pos - 1] : elements[0])
        }
        let start = unitStart(c, index)
        let unit = Array(c[start...index])
        c.removeSubrange(start...index)
        if target > index { target -= unit.count }
        c.insert(contentsOf: unit, at: target)
        return target + unit.count - 1
    }

    // MARK: Insertion

    private static func newShape(_ kind: MockupSVGShapeKind, cx: Double, cy: Double) -> MockupSVGNode {
        let a = { (name: String, value: String) in MockupSVGAttribute(name: name, value: value) }
        switch kind {
        case .rect:
            return MockupSVGNode(element: "rect", attributes: [
                a("x", number(cx - 80)), a("y", number(cy - 50)), a("width", "160"), a("height", "100"),
                a("rx", "6"), a("fill", "#F3F4F6"), a("stroke", "#9CA3AF"),
            ])
        case .ellipse:
            return MockupSVGNode(element: "ellipse", attributes: [
                a("cx", number(cx)), a("cy", number(cy)), a("rx", "80"), a("ry", "50"),
                a("fill", "#F3F4F6"), a("stroke", "#9CA3AF"),
            ])
        case .line:
            return MockupSVGNode(element: "line", attributes: [
                a("x1", number(cx - 80)), a("y1", number(cy)), a("x2", number(cx + 80)), a("y2", number(cy)),
                a("stroke", "#9CA3AF"), a("stroke-width", "2"),
            ])
        case .text:
            return MockupSVGNode(element: "text", attributes: [
                a("x", number(cx - 24)), a("y", number(cy)), a("fill", "#111827"),
                a("font-size", "16"), a("font-family", "sans-serif"),
            ], children: [.text("Text")])
        }
    }

    /// The root's viewBox as the web editor's `viewBoxOf` read it: `viewBox`, else
    /// `0 0 width height`, else 1280×800.
    private static func viewBox(of root: MockupSVGNode) -> CGRect {
        let parts = (root.attribute("viewBox") ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { Double($0) }
        if parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 {
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        func side(_ name: String, _ fallback: Double) -> Double {
            guard let l = root.attribute(name).flatMap(parseLength), !l.percent, l.value > 0 else { return fallback }
            return l.value
        }
        return CGRect(x: 0, y: 0, width: side("width", 1280), height: side("height", 800))
    }

    // MARK: Transforms

    private struct TransformItem {
        var name: String
        var args: [Double]
        var range: Range<String.Index>
    }

    /// Splits a transform list into its functions, keeping each one's range so the untouched
    /// rest of the attribute can be kept as written. Nil when the list doesn't parse.
    private static func parseTransform(_ s: String) -> [TransformItem]? {
        var items: [TransformItem] = []
        var i = s.startIndex
        func skip(commas: Bool) {
            while i < s.endIndex, s[i].isWhitespace || (commas && s[i] == ",") { i = s.index(after: i) }
        }
        while true {
            skip(commas: true)
            guard i < s.endIndex else { return items }
            let start = i
            while i < s.endIndex, s[i].isLetter { i = s.index(after: i) }
            let name = String(s[start..<i])
            skip(commas: false)
            guard !name.isEmpty, i < s.endIndex, s[i] == "(" else { return nil }
            guard let close = s[i...].firstIndex(of: ")") else { return nil }
            let raw = s[s.index(after: i)..<close].split(whereSeparator: { $0.isWhitespace || $0 == "," })
            let args = raw.compactMap { Double($0) }
            guard args.count == raw.count else { return nil }
            i = s.index(after: close)
            items.append(TransformItem(name: name, args: args, range: start..<i))
        }
    }

    private static func trimSeparators(_ s: Substring) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
    }

    /// The web editor's `translateEl`: add to a leading translate or prepend one, drop it when it
    /// becomes `0 0`, and drop the attribute when nothing is left. False when it can't parse.
    private static func translate(_ n: inout MockupSVGNode, dx: Double, dy: Double) -> Bool {
        let current = n.attribute("transform") ?? ""
        guard let items = parseTransform(current) else { return false }
        var tx = dx, ty = dy
        var rest = trimSeparators(current[...])
        if let first = items.first, first.name == "translate", (1...2).contains(first.args.count) {
            tx += first.args[0]
            ty += first.args.count == 2 ? first.args[1] : 0
            rest = trimSeparators(current[first.range.upperBound...])
        }
        let lead = number(tx) == "0" && number(ty) == "0" ? "" : "translate(\(number(tx)) \(number(ty)))"
        let next = [lead, rest].filter { !$0.isEmpty }.joined(separator: " ")
        n.setAttribute("transform", next.isEmpty ? nil : next)
        return true
    }

    /// Appends `map` as a trailing `matrix(…)`, composed into a trailing matrix already there.
    /// The linear coefficients keep 4 fraction digits: they are ratios, and 2 digits would put a
    /// 1000-unit element off by up to 5 units.
    private static func appendScale(_ n: inout MockupSVGNode, _ map: AxisMap) -> Bool {
        let current = n.attribute("transform") ?? ""
        guard let items = parseTransform(current) else { return false }
        var m = [map.sx, 0, 0, map.sy, map.ex, map.ey]
        var prefix = trimSeparators(current[...])
        if let last = items.last, last.name == "matrix", last.args.count == 6 {
            let p = last.args
            m = [p[0] * m[0], p[1] * m[0], p[2] * m[3], p[3] * m[3],
                 p[0] * m[4] + p[2] * m[5] + p[4], p[1] * m[4] + p[3] * m[5] + p[5]]
            prefix = trimSeparators(current[..<last.range.lowerBound])
        }
        let linear = m[0..<4].map { number($0, fractionDigits: 4) }
        let offset = m[4...].map { number($0) }
        let identity = linear == ["1", "0", "0", "1"] && offset == ["0", "0"]
        let matrix = identity ? "" : "matrix(\((linear + offset).joined(separator: " ")))"
        let next = [prefix, matrix].filter { !$0.isEmpty }.joined(separator: " ")
        n.setAttribute("transform", next.isEmpty ? nil : next)
        return true
    }

    // MARK: Geometry

    /// The affine map from one bbox to another, per axis. A zero-size axis can't scale, so it
    /// only moves.
    private struct AxisMap {
        var sx: Double, sy: Double, ex: Double, ey: Double

        init(old: CGRect, new: CGRect) {
            sx = old.width > 0 ? Double(new.width / old.width) : 1
            sy = old.height > 0 ? Double(new.height / old.height) : 1
            ex = Double(new.minX) - Double(old.minX) * sx
            ey = Double(new.minY) - Double(old.minY) * sy
        }

        func x(_ v: Double) -> Double { v * sx + ex }
        func y(_ v: Double) -> Double { v * sy + ey }
    }

    /// Which viewBox side a percentage is relative to.
    private enum Axis {
        case x, y, diagonal
    }

    private static func parseLength(_ raw: String) -> (value: Double, percent: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var percent = false
        if s.hasSuffix("%") {
            percent = true
            s.removeLast()
        } else if s.hasSuffix("px") {
            s.removeLast(2)
        }
        guard let v = Double(s), v.isFinite else { return nil }
        return (v, percent)
    }

    /// An attribute's value in user units (0 when absent, nil when it doesn't parse).
    private static func length(_ n: MockupSVGNode, _ name: String, _ axis: Axis, _ vb: CGRect) -> Double? {
        guard let raw = n.attribute(name) else { return 0 }
        guard let l = parseLength(raw) else { return nil }
        guard l.percent else { return l.value }
        let base: Double = switch axis {
        case .x: Double(vb.width)
        case .y: Double(vb.height)
        case .diagonal: (Double(vb.width * vb.width + vb.height * vb.height) / 2).squareRoot()
        }
        return l.value / 100 * base
    }

    /// Writes a length only when it changes, so a percentage or `px` the resize didn't move stays
    /// as written.
    private static func setLength(_ n: inout MockupSVGNode, _ name: String, _ value: Double, _ axis: Axis, _ vb: CGRect) {
        if let current = length(n, name, axis, vb), number(current) == number(value) { return }
        n.setAttribute(name, number(value))
    }

    private static func resize(_ n: inout MockupSVGNode, _ map: AxisMap, _ to: CGRect, _ vb: CGRect) -> Bool {
        let (x, y, w, h) = (Double(to.minX), Double(to.minY), Double(to.width), Double(to.height))
        switch n.localName {
        case "rect", "image":
            setBox(&n, x, y, w, h, vb)
        case "use" where n.attribute("width") != nil || n.attribute("height") != nil:
            setBox(&n, x, y, w, h, vb)
        case "ellipse":
            setLength(&n, "cx", x + w / 2, .x, vb)
            setLength(&n, "cy", y + h / 2, .y, vb)
            setLength(&n, "rx", w / 2, .x, vb)
            setLength(&n, "ry", h / 2, .y, vb)
        case "circle":
            setLength(&n, "cx", x + w / 2, .x, vb)
            setLength(&n, "cy", y + h / 2, .y, vb)
            setLength(&n, "r", min(w, h) / 2, .diagonal, vb)
        case "line":
            for (px, py) in [("x1", "y1"), ("x2", "y2")] {
                guard let ox = length(n, px, .x, vb), let oy = length(n, py, .y, vb) else { return false }
                setLength(&n, px, map.x(ox), .x, vb)
                setLength(&n, py, map.y(oy), .y, vb)
            }
        case "polyline", "polygon":
            let raw = (n.attribute("points") ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," })
            let values = raw.compactMap { Double($0) }
            guard values.count == raw.count, values.count.isMultiple(of: 2) else { return false }
            let points = stride(from: 0, to: values.count, by: 2).map {
                "\(number(map.x(values[$0]))),\(number(map.y(values[$0 + 1])))"
            }
            n.setAttribute("points", points.joined(separator: " "))
        case "text" where n.attribute("font-size").flatMap(parseLength).map { !$0.percent } == true:
            return resizeText(&n, map, vb, isRoot: true)
        default:
            // Paths, groups, `use` without a size and text whose size is inherited.
            return appendScale(&n, map)
        }
        return true
    }

    private static func setBox(_ n: inout MockupSVGNode, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ vb: CGRect) {
        setLength(&n, "x", x, .x, vb)
        setLength(&n, "y", y, .y, vb)
        setLength(&n, "width", w, .x, vb)
        setLength(&n, "height", h, .y, vb)
    }

    /// Moves a text's anchor and scales its font size by the height ratio, and does the same for
    /// tspans that position or size themselves, so a multi-line label resizes as one.
    private static func resizeText(_ n: inout MockupSVGNode, _ map: AxisMap, _ vb: CGRect, isRoot: Bool) -> Bool {
        // The text's own x/y default to 0 and always move; a tspan without them follows its text.
        for (name, axis) in [("x", Axis.x), ("y", Axis.y)] where isRoot || n.attribute(name) != nil {
            guard let v = length(n, name, axis, vb) else { return false }
            setLength(&n, name, axis == .x ? map.x(v) : map.y(v), axis, vb)
        }
        for (name, scale) in [("dx", map.sx), ("dy", map.sy), ("font-size", map.sy)] where n.attribute(name) != nil {
            guard let v = n.attribute(name).flatMap(parseLength), !v.percent else { return false }
            setLength(&n, name, v.value * scale, .x, vb)
        }
        for i in n.children.indices where n.children[i].isElement && n.children[i].localName == "tspan" {
            guard resizeText(&n.children[i], map, vb, isRoot: false) else { return false }
        }
        return true
    }
}
