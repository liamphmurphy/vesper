import CoreGraphics
import CoreText
import Foundation

/// A conforming mockup, compiled once for drawing, geometry and hit testing.
///
/// Compiling resolves everything the renderer would otherwise redo per frame: inherited styles,
/// percentages, shape paths, `<use>` instances and text layout. The document is immutable, so one
/// can be drawn from any thread.
public final class MockupSVGDocument: @unchecked Sendable {
    public struct NotConforming: Error, Sendable {
        public let violations: [MockupSVGViolation]
    }

    public let tree: MockupSVGTree
    public let viewBox: CGRect
    public let intrinsicSize: CGSize
    let aspect: MockupSVGValues.AspectRatio
    let root: MockupSVGRenderNode
    /// Referenced elements (gradients, patterns, clip paths, masks, markers) by id.
    let definitions: [String: MockupSVGNode]
    let definitionPaths: [String: String]
    private let nodesByPath: [String: MockupSVGRenderNode]
    public let drawablePaths: [String]

    public convenience init(source: String) throws {
        let violations = MockupSVGProfile.violations(source)
        guard violations.isEmpty else { throw NotConforming(violations: violations) }
        try self.init(trusted: MockupSVGTree.parse(source))
    }

    /// Compiles a tree without the profile check, for SVG another whitelist already restricted to
    /// what the renderer draws: persona characters (`PersonaCharacterSanitizer`), whose `data-*`
    /// rig attributes and glyph `rotate` the mockup profile rejects.
    public init(trusted tree: MockupSVGTree) {
        self.tree = tree
        let r = tree.root
        let vb: CGRect
        if let raw = r.attribute("viewBox"), let parsed = MockupSVGValues.viewBox(raw) {
            vb = parsed
        } else {
            vb = CGRect(x: 0, y: 0, width: Self.number(r.attribute("width")) ?? 300, height: Self.number(r.attribute("height")) ?? 150)
        }
        viewBox = vb
        let w = Self.number(r.attribute("width")), h = Self.number(r.attribute("height"))
        // A size in percent or missing takes the viewBox's, as an <img> of the file would.
        switch (w, h) {
        case let (w?, h?): intrinsicSize = CGSize(width: w, height: h)
        case let (w?, nil): intrinsicSize = CGSize(width: w, height: w * vb.height / max(vb.width, 1))
        case let (nil, h?): intrinsicSize = CGSize(width: h * vb.width / max(vb.height, 1), height: h)
        default: intrinsicSize = vb.size
        }
        aspect = r.attribute("preserveAspectRatio").flatMap(MockupSVGValues.aspectRatio) ?? .default

        var defs: [String: MockupSVGNode] = [:]
        var defPaths: [String: String] = [:]
        func collect(_ n: MockupSVGNode, _ path: String) {
            if MockupSVGProfile.ignoredElements.contains(n.localName) { return }
            if let id = n.attribute("id"), defs[id] == nil {
                defs[id] = n
                defPaths[id] = path
            }
            for (i, c) in n.children.enumerated() where c.isElement { collect(c, MockupSVGTree.childPath(path, i)) }
        }
        collect(r, "")
        definitions = defs
        definitionPaths = defPaths

        var compiler = MockupSVGCompiler(definitions: defs, definitionPaths: defPaths, viewBox: vb)
        root = compiler.compile(r, path: "", parentStyle: .initial, parentCTM: .identity, instanceOf: nil, depth: 0)
        nodesByPath = compiler.byPath
        drawablePaths = compiler.drawable
    }

    static func number(_ raw: String?) -> Double? {
        guard let raw, case .number(let v)? = MockupSVGValues.length(raw, percent: false), v > 0 else { return nil }
        return v
    }

    func node(at path: String) -> MockupSVGRenderNode? { nodesByPath[path] }

    public func geometry(at path: String) -> MockupSVGElementGeometry? {
        guard let n = nodesByPath[path] else { return nil }
        let local = n.localBounds
        let bounds = local.isNull ? CGRect(origin: CGPoint(x: n.ctm.tx, y: n.ctm.ty), size: .zero) : local.applying(n.ctm)
        return MockupSVGElementGeometry(localBounds: local.isNull ? .zero : local, transform: n.ctm, parentTransform: n.parentCTM, bounds: bounds)
    }

    public func hitTest(_ point: CGPoint) -> String? {
        var hit: String?
        func visit(_ n: MockupSVGRenderNode) {
            guard n.style.display, !n.isDefinition else { return }
            if let id = n.clipPath, let clip = MockupSVGClip.path(for: id, node: n, document: self) {
                guard clip.path.contains(point.applying(n.ctm.inverted()), using: clip.rule) else { return }
            }
            if n.isDrawable, n.contains(point.applying(n.ctm.inverted())) {
                hit = n.targetPath
            }
            for c in n.children { visit(c) }
        }
        visit(root)
        return hit
    }
}

public struct MockupSVGElementGeometry: Equatable, Sendable {
    /// The element's geometry bounding box in its own user space, before its `transform`.
    public var localBounds: CGRect
    /// Element user space to root user space: its transform and every ancestor's.
    public var transform: CGAffineTransform
    /// The parent's user space to root user space.
    public var parentTransform: CGAffineTransform
    /// `localBounds` through `transform`, axis-aligned, in root user space (no stroke).
    public var bounds: CGRect

    public init(localBounds: CGRect, transform: CGAffineTransform, parentTransform: CGAffineTransform, bounds: CGRect) {
        self.localBounds = localBounds
        self.transform = transform
        self.parentTransform = parentTransform
        self.bounds = bounds
    }
}

// MARK: - Computed style

struct MockupSVGStyle: @unchecked Sendable {
    typealias Paint = MockupSVGValues.Paint
    typealias RGBA = MockupSVGValues.RGBA

    // Inherited
    var fill: Paint = .color(.rgba(.black))
    var fillOpacity = 1.0
    var fillRule: CGPathFillRule = .winding
    var stroke: Paint = .none
    var strokeWidth = 1.0
    var strokeOpacity = 1.0
    var dashArray: [Double] = []
    var dashOffset = 0.0
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var miterLimit = 4.0
    var color: RGBA = .black
    var visible = true
    var clipRule: CGPathFillRule = .winding
    var markerStart = ""
    var markerMid = ""
    var markerEnd = ""
    var fontFamily = "Times"
    var fontSize = 16.0
    var fontWeight = 400
    var italic = false
    var textAnchor = "start"
    var baseline = "auto"
    var letterSpacing = 0.0
    // Not inherited
    var display = true
    var opacity = 1.0
    var underline = false
    var lineThrough = false

    static let initial = MockupSVGStyle()

    /// The style of a child: inherited properties carry over, the rest reset.
    func inherited() -> MockupSVGStyle {
        var s = self
        s.display = true
        s.opacity = 1
        return s
    }

    /// A concrete colour for `c` with `opacity`, resolving `currentColor`.
    func resolve(_ c: MockupSVGValues.Color, opacity: Double) -> CGColor {
        let rgba: RGBA = switch c {
        case .rgba(let v): v
        case .currentColor: color
        }
        return CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a * opacity)
    }
}

// MARK: - Render nodes

/// A compiled element: what to draw and where.
final class MockupSVGRenderNode: @unchecked Sendable {
    enum Shape {
        case path(CGPath)
        case text(MockupSVGTextLayout)
        case image(CGImage, viewport: CGRect, aspect: MockupSVGValues.AspectRatio)
        case none
    }

    let path: String
    /// The element hit testing and geometry report: a `<use>` for its instance, a `<text>` for its spans.
    let targetPath: String
    let element: MockupSVGNode
    let style: MockupSVGStyle
    /// Its `transform` (and for `<use>`, the x/y offset), mapping its space into its parent's.
    let transform: CGAffineTransform
    /// The `<use>` x/y offset alone, kept when a `MockupSVGNodeOverride` replaces the `transform`.
    let offset: CGAffineTransform
    /// The path of the tree element it was compiled from: its own path, or for an instance under a
    /// `<use>`, the referenced element's, so overrides reach every instance as CSS reaches clones.
    let sourcePath: String
    /// Element space to root user space.
    let ctm: CGAffineTransform
    let parentCTM: CGAffineTransform
    let shape: Shape
    let children: [MockupSVGRenderNode]
    /// Inside defs, symbol, clipPath, mask, marker or pattern: drawn only by reference.
    let isDefinition: Bool
    let clipPath: String?
    let mask: String?
    /// A symbol instance's viewport clip, in the node's space.
    let clipRect: CGRect?
    var localBounds: CGRect

    init(path: String, targetPath: String, element: MockupSVGNode, style: MockupSVGStyle, transform: CGAffineTransform,
         ctm: CGAffineTransform, parentCTM: CGAffineTransform, shape: Shape, children: [MockupSVGRenderNode],
         isDefinition: Bool, clipPath: String?, mask: String?, clipRect: CGRect?,
         offset: CGAffineTransform = .identity, sourcePath: String? = nil) {
        self.path = path
        self.targetPath = targetPath
        self.element = element
        self.style = style
        self.transform = transform
        self.offset = offset
        self.sourcePath = sourcePath ?? path
        self.ctm = ctm
        self.parentCTM = parentCTM
        self.shape = shape
        self.children = children
        self.isDefinition = isDefinition
        self.clipPath = clipPath
        self.mask = mask
        self.clipRect = clipRect
        localBounds = .null
        localBounds = computeBounds()
    }

    var isDrawable: Bool {
        if case .none = shape { return false }
        return true
    }

    var cgPath: CGPath? {
        if case .path(let p) = shape { return p }
        return nil
    }

    private func computeBounds() -> CGRect {
        switch shape {
        case .path(let p):
            return p.isEmpty ? .null : p.boundingBoxOfPath
        case .text(let t):
            return t.bounds
        case .image(_, let viewport, _):
            return viewport
        case .none:
            var r = CGRect.null
            for c in children where c.style.display && !c.isDefinition {
                let b = c.localBounds
                if !b.isNull { r = r.union(b.applying(c.transform)) }
            }
            if let clipRect, !r.isNull { r = r.intersection(clipRect) }
            return r
        }
    }

    /// Whether `p` (in this node's space) is on its painted area.
    func contains(_ p: CGPoint) -> Bool {
        guard style.visible else { return false }
        switch shape {
        case .path(let path):
            if case .none = style.fill {} else if path.contains(p, using: style.fillRule) { return true }
            if case .none = style.stroke { return false }
            let w = max(style.strokeWidth, 3) // a hairline is still clickable
            return path.copy(strokingWithWidth: w, lineCap: style.lineCap, lineJoin: style.lineJoin, miterLimit: style.miterLimit).contains(p)
        case .text(let t):
            return t.lineRects.contains { $0.insetBy(dx: -1, dy: -1).contains(p) }
        case .image(_, let viewport, _):
            return viewport.contains(p)
        case .none:
            return false
        }
    }
}

// MARK: - Compiler

struct MockupSVGCompiler {
    let definitions: [String: MockupSVGNode]
    let definitionPaths: [String: String]
    let viewBox: CGRect
    var byPath: [String: MockupSVGRenderNode] = [:]
    var drawable: [String] = []

    static let definitionElements: Set<String> = ["defs", "symbol", "clipPath", "mask", "marker", "pattern", "linearGradient", "radialGradient"]
    static let maxUseDepth = 8

    init(definitions: [String: MockupSVGNode], definitionPaths: [String: String] = [:], viewBox: CGRect) {
        self.definitions = definitions
        self.definitionPaths = definitionPaths
        self.viewBox = viewBox
    }

    /// `instanceOf` is the `<use>` path an instance subtree reports as its target.
    /// `sourcePath` is the tree path of `n` when it differs from `path` (inside an instance).
    mutating func compile(_ n: MockupSVGNode, path: String, parentStyle: MockupSVGStyle, parentCTM: CGAffineTransform,
                          instanceOf: String?, depth: Int, inDefinition: Bool = false,
                          sourcePath: String? = nil) -> MockupSVGRenderNode {
        let name = n.localName
        let source = sourcePath ?? path
        var style = parentStyle.inherited()
        Self.apply(n, to: &style, viewBox: viewBox)
        let isDefinition = inDefinition || Self.definitionElements.contains(name)
        var transform = n.attribute("transform").flatMap(MockupSVGValues.transform) ?? .identity
        var shape: MockupSVGRenderNode.Shape = .none
        var children: [MockupSVGRenderNode] = []
        var clipRect: CGRect?
        let target = instanceOf ?? path

        switch name {
        case "rect", "circle", "ellipse", "line", "polyline", "polygon", "path":
            shape = .path(Self.shapePath(n, viewBox: viewBox))
        case "image":
            let vp = CGRect(x: len(n, "x", \.width), y: len(n, "y", \.height), width: len(n, "width", \.width), height: len(n, "height", \.height))
            if let raw = n.attribute("href") ?? n.attributes.first(where: { $0.name.hasSuffix(":href") })?.value,
               let data = MockupSVGValues.imageData(raw), let img = MockupSVGImages.decode(data), vp.width > 0, vp.height > 0 {
                shape = .image(img, viewport: vp, aspect: n.attribute("preserveAspectRatio").flatMap(MockupSVGValues.aspectRatio) ?? .default)
            }
        case "text":
            shape = .text(MockupSVGTextLayout(n, style: style, viewBox: viewBox))
        default:
            break
        }
        let ctm = transform.concatenating(parentCTM)

        if name == "use" {
            let x = len(n, "x", \.width), y = len(n, "y", \.height)
            let offset = CGAffineTransform(translationX: x, y: y)
            transform = offset.concatenating(transform)
            let useCTM = transform.concatenating(parentCTM)
            if depth < Self.maxUseDepth,
               let raw = n.attribute("href") ?? n.attributes.first(where: { $0.name.hasSuffix(":href") })?.value,
               let id = MockupSVGValues.fragment(raw), let ref = definitions[id] {
                let refSource = definitionPaths[id]
                if ref.localName == "symbol" {
                    let w = n.attribute("width").flatMap { MockupSVGValues.length($0, percent: true) }?.resolve(viewBox.width) ?? viewBox.width
                    let h = n.attribute("height").flatMap { MockupSVGValues.length($0, percent: true) }?.resolve(viewBox.height) ?? viewBox.height
                    // The symbol inherits from the use; opacity and the other non-inherited
                    // properties stay on the use, or they'd apply twice.
                    var symStyle = style.inherited()
                    Self.apply(ref, to: &symStyle, viewBox: viewBox)
                    var mapping = CGAffineTransform.identity
                    if let vb = ref.attribute("viewBox").flatMap(MockupSVGValues.viewBox), vb.width > 0, vb.height > 0 {
                        let ar = ref.attribute("preserveAspectRatio").flatMap(MockupSVGValues.aspectRatio) ?? .default
                        mapping = ar.transform(viewBox: vb, into: CGRect(x: 0, y: 0, width: w, height: h))
                    }
                    clipRect = CGRect(x: 0, y: 0, width: w, height: h)
                    let inner = mapping.concatenating(useCTM)
                    var kids: [MockupSVGRenderNode] = []
                    for (i, c) in ref.children.enumerated() where c.isElement {
                        let k = compile(c, path: "\(path)#\(i)", parentStyle: symStyle, parentCTM: inner, instanceOf: target, depth: depth + 1,
                                        sourcePath: refSource.map { MockupSVGTree.childPath($0, i) })
                        kids.append(k)
                    }
                    children = [MockupSVGRenderNode(path: "\(path)#symbol", targetPath: target, element: ref, style: symStyle, transform: mapping,
                                                    ctm: inner, parentCTM: useCTM, shape: .none, children: kids, isDefinition: false,
                                                    clipPath: nil, mask: nil, clipRect: nil, sourcePath: refSource)]
                } else {
                    children = [compile(ref, path: "\(path)#0", parentStyle: style, parentCTM: useCTM, instanceOf: target, depth: depth + 1,
                                        sourcePath: refSource)]
                }
            }
            let node = MockupSVGRenderNode(path: path, targetPath: target, element: n, style: style, transform: transform, ctm: useCTM,
                                           parentCTM: parentCTM, shape: .none, children: children, isDefinition: isDefinition,
                                           clipPath: Self.ref(n, "clip-path"), mask: Self.ref(n, "mask"), clipRect: clipRect,
                                           offset: offset, sourcePath: source)
            register(node, instance: instanceOf != nil, drawable: !isDefinition)
            return node
        }

        // Text content belongs to the layout; definitions are compiled so references can draw them.
        if name != "text", !MockupSVGProfile.ignoredElements.contains(name) {
            for (i, c) in n.children.enumerated() where c.isElement {
                if MockupSVGProfile.ignoredElements.contains(c.localName) { continue }
                children.append(compile(c, path: instanceOf == nil ? MockupSVGTree.childPath(path, i) : "\(path).\(i)",
                                        parentStyle: style, parentCTM: ctm, instanceOf: instanceOf, depth: depth,
                                        inDefinition: isDefinition, sourcePath: MockupSVGTree.childPath(source, i)))
            }
        }
        let node = MockupSVGRenderNode(path: path, targetPath: target, element: n, style: style, transform: transform, ctm: ctm,
                                       parentCTM: parentCTM, shape: shape, children: children, isDefinition: isDefinition,
                                       clipPath: Self.ref(n, "clip-path"), mask: Self.ref(n, "mask"), clipRect: nil,
                                       sourcePath: source)
        let isShape = node.isDrawable
        register(node, instance: instanceOf != nil, drawable: isShape && !isDefinition)
        return node
    }

    private mutating func register(_ node: MockupSVGRenderNode, instance: Bool, drawable isDrawable: Bool) {
        guard !instance else { return }
        byPath[node.path] = node
        if isDrawable { drawable.append(node.path) }
    }

    private func len(_ n: MockupSVGNode, _ name: String, _ axis: KeyPath<CGSize, CGFloat>) -> Double {
        guard let raw = n.attribute(name), let l = MockupSVGValues.length(raw, percent: true) else { return 0 }
        return l.resolve(viewBox.size[keyPath: axis])
    }

    static func ref(_ n: MockupSVGNode, _ name: String) -> String? {
        guard let raw = n.attribute(name), let id = MockupSVGValues.reference(raw), !id.isEmpty else { return nil }
        return id
    }

    /// Applies an element's presentation attributes over the inherited style.
    static func apply(_ n: MockupSVGNode, to s: inout MockupSVGStyle, viewBox: CGRect) {
        let diag = (viewBox.width * viewBox.width + viewBox.height * viewBox.height).squareRoot() / 2.squareRoot()
        func a(_ name: String) -> String? { n.attribute(name)?.trimmingCharacters(in: .whitespaces) }
        func unit(_ name: String) -> Double? {
            a(name).flatMap { MockupSVGValues.length($0, percent: true) }.map { min(max($0.fraction, 0), 1) }
        }
        if let v = a("color").flatMap(MockupSVGValues.color), case .rgba(let c) = v { s.color = c }
        if let v = a("fill").flatMap(MockupSVGValues.paint) { s.fill = v }
        if let v = unit("fill-opacity") { s.fillOpacity = v }
        if let v = a("fill-rule") { s.fillRule = v == "evenodd" ? .evenOdd : .winding }
        if let v = a("stroke").flatMap(MockupSVGValues.paint) { s.stroke = v }
        if let v = a("stroke-width").flatMap({ MockupSVGValues.length($0, percent: true) }) { s.strokeWidth = max(v.resolve(diag), 0) }
        if let v = unit("stroke-opacity") { s.strokeOpacity = v }
        if let v = a("stroke-dasharray").flatMap(MockupSVGValues.dashArray) { s.dashArray = v }
        if let v = a("stroke-dashoffset").flatMap({ MockupSVGValues.length($0, percent: false) }) { s.dashOffset = v.resolve(diag) }
        switch a("stroke-linecap") {
        case "round": s.lineCap = .round
        case "square": s.lineCap = .square
        case "butt": s.lineCap = .butt
        default: break
        }
        switch a("stroke-linejoin") {
        case "round": s.lineJoin = .round
        case "bevel": s.lineJoin = .bevel
        case "miter": s.lineJoin = .miter
        default: break
        }
        if let v = a("stroke-miterlimit").flatMap(MockupSVGValues.number) { s.miterLimit = max(v, 1) }
        if let v = a("visibility") { s.visible = v == "visible" }
        if let v = a("clip-rule") { s.clipRule = v == "evenodd" ? .evenOdd : .winding }
        if let v = a("marker-start").flatMap(MockupSVGValues.reference) { s.markerStart = v }
        if let v = a("marker-mid").flatMap(MockupSVGValues.reference) { s.markerMid = v }
        if let v = a("marker-end").flatMap(MockupSVGValues.reference) { s.markerEnd = v }
        if let v = a("font-family"), !v.isEmpty { s.fontFamily = v }
        if let v = a("font-size").flatMap({ MockupSVGValues.length($0, percent: false) }) { s.fontSize = max(v.resolve(0), 0) }
        if let v = a("font-weight").flatMap(MockupSVGValues.fontWeight) {
            switch v {
            case "normal": s.fontWeight = 400
            case "bold": s.fontWeight = 700
            // CSS Fonts' relative weights.
            case "bolder": s.fontWeight = s.fontWeight < 350 ? 400 : s.fontWeight < 550 ? 700 : 900
            case "lighter": s.fontWeight = s.fontWeight < 550 ? 100 : s.fontWeight < 750 ? 400 : 700
            default: s.fontWeight = Int(v) ?? 400
            }
        }
        if let v = a("font-style") { s.italic = v != "normal" }
        if let v = a("text-anchor") { s.textAnchor = v }
        if let v = a("dominant-baseline") { s.baseline = v }
        if let v = a("letter-spacing") { s.letterSpacing = v == "normal" ? 0 : MockupSVGValues.length(v, percent: false)?.resolve(0) ?? 0 }
        if let v = a("text-decoration") {
            s.underline = v == "underline"
            s.lineThrough = v == "line-through"
        }
        if a("display") == "none" { s.display = false }
        if let v = unit("opacity") { s.opacity = v }
    }

    /// The geometry of a basic shape or path, in its own user space.
    static func shapePath(_ n: MockupSVGNode, viewBox vb: CGRect) -> CGPath {
        let diag = (vb.width * vb.width + vb.height * vb.height).squareRoot() / 2.squareRoot()
        func l(_ name: String, _ base: Double) -> Double? {
            n.attribute(name).flatMap { MockupSVGValues.length($0, percent: true) }?.resolve(base)
        }
        let p = CGMutablePath()
        switch n.localName {
        case "rect":
            let x = l("x", vb.width) ?? 0, y = l("y", vb.height) ?? 0
            let w = l("width", vb.width) ?? 0, h = l("height", vb.height) ?? 0
            guard w > 0, h > 0 else { return p }
            // rx/ry: a missing or auto one takes the other's value; both clamp to half the side.
            var rx = n.attribute("rx") == "auto" ? nil : l("rx", vb.width)
            var ry = n.attribute("ry") == "auto" ? nil : l("ry", vb.height)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let crx = min(max(rx ?? 0, 0), w / 2), cry = min(max(ry ?? 0, 0), h / 2)
            if crx > 0, cry > 0 {
                p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: crx, cornerHeight: cry)
            } else {
                p.addRect(CGRect(x: x, y: y, width: w, height: h))
            }
        case "circle":
            let r = l("r", diag) ?? 0
            if r > 0 { p.addEllipse(in: CGRect(x: (l("cx", vb.width) ?? 0) - r, y: (l("cy", vb.height) ?? 0) - r, width: 2 * r, height: 2 * r)) }
        case "ellipse":
            var rx = n.attribute("rx") == "auto" ? nil : l("rx", vb.width)
            var ry = n.attribute("ry") == "auto" ? nil : l("ry", vb.height)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            if let rx, let ry, rx > 0, ry > 0 {
                p.addEllipse(in: CGRect(x: (l("cx", vb.width) ?? 0) - rx, y: (l("cy", vb.height) ?? 0) - ry, width: 2 * rx, height: 2 * ry))
            }
        case "line":
            p.move(to: CGPoint(x: l("x1", vb.width) ?? 0, y: l("y1", vb.height) ?? 0))
            p.addLine(to: CGPoint(x: l("x2", vb.width) ?? 0, y: l("y2", vb.height) ?? 0))
        case "polyline", "polygon":
            if let pts = n.attribute("points").flatMap(MockupSVGValues.points), pts.count >= 2 {
                p.addLines(between: pts)
                if n.localName == "polygon" { p.closeSubpath() }
            }
        case "path":
            if let d = n.attribute("d") { return SVGPathParser.parse(d) }
        default:
            break
        }
        return p
    }
}
