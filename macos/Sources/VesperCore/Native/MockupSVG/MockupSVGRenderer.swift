import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct MockupSVGRenderOptions: Sendable {
    /// Elements (by path) not drawn, with their descendants.
    public var hiddenPaths: Set<String>
    /// When set, only these elements (and their descendants) are drawn, still under their
    /// ancestors' transforms, opacity, clips and masks: the editor's layer for a dragged element.
    public var onlyPaths: Set<String>?
    public var background: CGColor?

    public init(hiddenPaths: Set<String> = [], onlyPaths: Set<String>? = nil, background: CGColor? = nil) {
        self.hiddenPaths = hiddenPaths
        self.onlyPaths = onlyPaths
        self.background = background
    }
}

/// Draws conforming mockups with CoreGraphics: the renderer behind the editor, the viewer, the
/// review screen and approval snapshots (docs/dev/mockup-svg-profile.md).
public enum MockupSVGRenderer {
    /// Sent with approval snapshots so the server knows what drew them.
    public static let identifier = "vesper-native/1"

    /// Draws into a Y-down context, mapping the viewBox into `rect` by the root's preserveAspectRatio.
    public static func draw(_ doc: MockupSVGDocument, in ctx: CGContext, rect: CGRect, options: MockupSVGRenderOptions = .init()) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let bg = options.background {
            ctx.setFillColor(bg)
            ctx.fill(rect)
        }
        ctx.clip(to: rect)
        ctx.concatenate(doc.aspect.transform(viewBox: doc.viewBox, into: rect))
        var r = MockupSVGDrawer(doc: doc, options: options)
        r.draw(doc.root, in: ctx, filtering: options.onlyPaths != nil)
    }

    public static func makeImage(_ doc: MockupSVGDocument, scale: CGFloat, options: MockupSVGRenderOptions = .init()) -> CGImage? {
        let w = Int((doc.intrinsicSize.width * scale).rounded()), h = Int((doc.intrinsicSize.height * scale).rounded())
        guard w > 0, h > 0, let ctx = bitmapContext(width: w, height: h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(doc, in: ctx, rect: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)), options: options)
        return ctx.makeImage()
    }

    public static func pngData(_ doc: MockupSVGDocument, scale: CGFloat, background: CGColor?) -> Data? {
        guard let image = makeImage(doc, scale: scale, options: MockupSVGRenderOptions(background: background)) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

// MARK: - Drawing

struct MockupSVGDrawer {
    let doc: MockupSVGDocument
    let options: MockupSVGRenderOptions
    /// Guards against reference cycles through masks and patterns.
    var depth = 0

    init(doc: MockupSVGDocument, options: MockupSVGRenderOptions) {
        self.doc = doc
        self.options = options
    }

    /// `filtering`: an ancestor of an `onlyPaths` element, drawn only for its descendants.
    mutating func draw(_ n: MockupSVGRenderNode, in ctx: CGContext, filtering: Bool) {
        guard n.style.display, !n.isDefinition, !options.hiddenPaths.contains(n.path) else { return }
        var filtering = filtering
        if filtering, let only = options.onlyPaths {
            if only.contains(n.path) {
                filtering = false
            } else if !(n.path.isEmpty || only.contains { $0.hasPrefix(n.path + ".") }) {
                return
            }
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(n.transform)
        if let clipRect = n.clipRect { ctx.clip(to: clipRect) }
        if let id = n.clipPath {
            guard let clip = MockupSVGClip.path(for: id, node: n, document: doc) else { return }
            ctx.addPath(clip.path)
            ctx.clip(using: clip.rule)
        }
        let group = n.style.opacity < 0.999 || n.mask != nil
        if group {
            ctx.setAlpha(n.style.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if let id = n.mask, !applyMask(id, node: n, in: ctx) {
            if group { ctx.endTransparencyLayer() }
            return
        }
        if !filtering { drawShape(n, in: ctx) }
        for c in n.children { draw(c, in: ctx, filtering: filtering) }
        if group { ctx.endTransparencyLayer() }
    }

    mutating func drawShape(_ n: MockupSVGRenderNode, in ctx: CGContext) {
        guard n.style.visible else { return }
        switch n.shape {
        case .path(let path):
            guard !path.isEmpty else { return }
            fill(path, style: n.style, bbox: n.localBounds, in: ctx)
            stroke(path, style: n.style, bbox: n.localBounds, in: ctx)
            MockupSVGMarkers.draw(for: n, path: path, renderer: &self, in: ctx)
        case .text(let layout):
            drawText(layout, bbox: n.localBounds, in: ctx)
        case .image(let image, let viewport, let aspect):
            drawImage(image, viewport: viewport, aspect: aspect, in: ctx)
        case .none:
            break
        }
    }

    // MARK: Paint

    mutating func fill(_ path: CGPath, style s: MockupSVGStyle, bbox: CGRect, in ctx: CGContext) {
        paint(s.fill, opacity: s.fillOpacity, style: s, bbox: bbox, in: ctx) { ctx in
            ctx.addPath(path)
            return .fill(s.fillRule)
        }
    }

    mutating func stroke(_ path: CGPath, style s: MockupSVGStyle, bbox: CGRect, in ctx: CGContext) {
        guard s.strokeWidth > 0 else { return }
        paint(s.stroke, opacity: s.strokeOpacity, style: s, bbox: bbox, in: ctx) { ctx in
            ctx.addPath(path)
            ctx.setLineWidth(s.strokeWidth)
            ctx.setLineCap(s.lineCap)
            ctx.setLineJoin(s.lineJoin)
            ctx.setMiterLimit(s.miterLimit)
            // An odd dash list repeats to make it even; all zeros means a solid line.
            var dashes = s.dashArray
            if dashes.count % 2 == 1 { dashes += dashes }
            if !dashes.isEmpty, dashes.contains(where: { $0 > 0 }) {
                ctx.setLineDash(phase: s.dashOffset, lengths: dashes.map { CGFloat($0) })
            }
            return .stroke
        }
    }

    enum Op {
        case fill(CGPathFillRule)
        case stroke
    }

    /// Paints what `build` adds to the context with `p`. A gradient or pattern paints through a
    /// clip of the filled or stroked shape.
    mutating func paint(_ p: MockupSVGValues.Paint, opacity: Double, style s: MockupSVGStyle, bbox: CGRect,
                        in ctx: CGContext, build: (CGContext) -> Op) {
        switch p {
        case .none:
            return
        case .color(let c):
            ctx.saveGState()
            let op = build(ctx)
            switch op {
            case .fill(let rule):
                ctx.setFillColor(s.resolve(c, opacity: opacity))
                ctx.fillPath(using: rule)
            case .stroke:
                ctx.setStrokeColor(s.resolve(c, opacity: opacity))
                ctx.strokePath()
            }
            ctx.restoreGState()
        case .url(let id, let fallback):
            guard let server = doc.definitions[id], let drawn = paintServerApplies(server, bbox: bbox) else {
                if case .color(let c)? = fallback { paint(.color(c), opacity: opacity, style: s, bbox: bbox, in: ctx, build: build) }
                return
            }
            guard drawn else { return }
            ctx.saveGState()
            switch build(ctx) {
            case .fill(let rule): ctx.clip(using: rule)
            case .stroke:
                ctx.replacePathWithStrokedPath()
                ctx.clip()
            }
            ctx.setAlpha(opacity)
            if server.localName == "pattern" {
                MockupSVGPatterns.draw(server, bbox: bbox, renderer: &self, in: ctx)
            } else {
                MockupSVGGradients.draw(server, bbox: bbox, document: doc, style: s, in: ctx)
            }
            ctx.restoreGState()
        }
    }

    /// nil: the reference can't paint (fallback applies); false: it paints nothing (an empty bbox).
    func paintServerApplies(_ server: MockupSVGNode, bbox: CGRect) -> Bool? {
        switch server.localName {
        case "linearGradient", "radialGradient":
            let units = MockupSVGGradients.attribute("gradientUnits", of: server, in: doc) ?? "objectBoundingBox"
            if units == "objectBoundingBox", bbox.isNull || bbox.width <= 0 || bbox.height <= 0 { return false }
            return true
        case "pattern":
            return true
        default:
            return nil
        }
    }

    // MARK: Text

    func drawText(_ layout: MockupSVGTextLayout, bbox: CGRect, in ctx: CGContext) {
        for run in layout.runs {
            let s = run.style
            guard s.visible else { continue }
            for (paintValue, opacity, isStroke) in [(s.fill, s.fillOpacity, false), (s.stroke, s.strokeOpacity, true)] {
                if case .none = paintValue { continue }
                if isStroke, s.strokeWidth <= 0 { continue }
                ctx.saveGState()
                switch paintValue {
                case .color(let c):
                    let color = s.resolve(c, opacity: opacity)
                    if isStroke {
                        ctx.setStrokeColor(color)
                        ctx.setLineWidth(s.strokeWidth)
                        ctx.setTextDrawingMode(.stroke)
                    } else {
                        ctx.setFillColor(color)
                        ctx.setTextDrawingMode(.fill)
                    }
                    drawLine(run, in: ctx)
                    if !isStroke { drawDecorations(run, color: color, in: ctx) }
                case .url(let id, let fallback):
                    if let server = doc.definitions[id], server.localName != "pattern", paintServerApplies(server, bbox: bbox) == true {
                        ctx.setTextDrawingMode(isStroke ? .strokeClip : .clip)
                        if isStroke { ctx.setLineWidth(s.strokeWidth) }
                        drawLine(run, in: ctx)
                        ctx.setAlpha(opacity)
                        MockupSVGGradients.draw(server, bbox: bbox, document: doc, style: s, in: ctx)
                    } else if case .color(let c)? = fallback {
                        ctx.setFillColor(s.resolve(c, opacity: opacity))
                        ctx.setStrokeColor(s.resolve(c, opacity: opacity))
                        ctx.setTextDrawingMode(isStroke ? .stroke : .fill)
                        drawLine(run, in: ctx)
                    }
                case .none:
                    break
                }
                ctx.restoreGState()
            }
        }
    }

    private func drawLine(_ run: MockupSVGTextLayout.Run, in ctx: CGContext) {
        ctx.saveGState()
        // Glyphs draw Y-up; flip about the baseline.
        ctx.translateBy(x: run.origin.x, y: run.origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(run.line, ctx)
        ctx.restoreGState()
    }

    private func drawDecorations(_ run: MockupSVGTextLayout.Run, color: CGColor, in ctx: CGContext) {
        let s = run.style
        guard s.underline || s.lineThrough else { return }
        let thickness = max(CTFontGetUnderlineThickness(run.font), 1)
        ctx.setFillColor(color)
        if s.underline {
            let y = run.origin.y - CTFontGetUnderlinePosition(run.font)
            ctx.fill(CGRect(x: run.origin.x, y: y - thickness / 2, width: run.width, height: thickness))
        }
        if s.lineThrough {
            let y = run.origin.y - CTFontGetXHeight(run.font) / 2
            ctx.fill(CGRect(x: run.origin.x, y: y - thickness / 2, width: run.width, height: thickness))
        }
    }

    // MARK: Images

    func drawImage(_ image: CGImage, viewport: CGRect, aspect: MockupSVGValues.AspectRatio, in ctx: CGContext) {
        let natural = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let t = aspect.transform(viewBox: natural, into: viewport)
        ctx.saveGState()
        ctx.clip(to: viewport)
        ctx.concatenate(t)
        // CGImage draws Y-up.
        ctx.translateBy(x: 0, y: natural.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: natural)
        ctx.restoreGState()
    }

    // MARK: Masks

    /// Clips `ctx` to the luminance of mask `id` (SVG 1.1 masks: luminance times alpha).
    mutating func applyMask(_ id: String, node n: MockupSVGRenderNode, in ctx: CGContext) -> Bool {
        guard depth < 4, let mask = doc.definitions[id], mask.localName == "mask" else { return false }
        let bbox = n.localBounds
        let units = mask.attribute("maskUnits") ?? "objectBoundingBox"
        let contentUnits = mask.attribute("maskContentUnits") ?? "userSpaceOnUse"
        func l(_ name: String, _ def: String) -> MockupSVGValues.Length {
            MockupSVGValues.length(mask.attribute(name) ?? def, percent: true) ?? .number(0)
        }
        let region: CGRect
        if units == "userSpaceOnUse" {
            let vb = doc.viewBox
            region = CGRect(x: l("x", "-10%").resolve(vb.width), y: l("y", "-10%").resolve(vb.height),
                            width: l("width", "120%").resolve(vb.width), height: l("height", "120%").resolve(vb.height))
        } else {
            guard !bbox.isNull, bbox.width > 0, bbox.height > 0 else { return false }
            region = CGRect(x: bbox.minX + l("x", "-10%").fraction * bbox.width, y: bbox.minY + l("y", "-10%").fraction * bbox.height,
                            width: l("width", "120%").fraction * bbox.width, height: l("height", "120%").fraction * bbox.height)
        }
        guard region.width > 0, region.height > 0 else { return false }
        let device = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, min(4, (abs(device.a * device.d - device.b * device.c)).squareRoot()))
        let w = Int((region.width * scale).rounded(.up)), h = Int((region.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h <= 64_000_000, let mctx = MockupSVGRenderer.bitmapContext(width: w, height: h) else { return false }
        mctx.translateBy(x: 0, y: CGFloat(h))
        mctx.scaleBy(x: scale, y: -scale)
        mctx.translateBy(x: -region.minX, y: -region.minY)
        if contentUnits == "objectBoundingBox", !bbox.isNull {
            mctx.concatenate(CGAffineTransform(a: bbox.width, b: 0, c: 0, d: bbox.height, tx: bbox.minX, ty: bbox.minY))
        }
        var inner = MockupSVGDrawer(doc: doc, options: MockupSVGRenderOptions())
        inner.depth = depth + 1
        guard let maskNode = MockupSVGDefinitionNodes.node(for: id, in: doc) else { return false }
        for c in maskNode.children { inner.drawDefinitionChild(c, in: mctx) }
        guard let rgba = mctx.makeImage(), let luminance = MockupSVGMaskImage.luminance(of: rgba) else { return false }
        // clip(to:mask:) places an image's first row at the rect's maxY, which is the bottom in a
        // Y-down space: flip about the region for the clip only (the flip is its own inverse).
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: region.minY + region.maxY)
        ctx.concatenate(flip)
        ctx.clip(to: region, mask: luminance)
        ctx.concatenate(flip)
        return true
    }

    /// Draws a child of a referenced element (mask, pattern, marker) as ordinary content.
    mutating func drawDefinitionChild(_ n: MockupSVGRenderNode, in ctx: CGContext) {
        guard n.style.display else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(n.transform)
        if let clipRect = n.clipRect { ctx.clip(to: clipRect) }
        if let id = n.clipPath, let clip = MockupSVGClip.path(for: id, node: n, document: doc) {
            ctx.addPath(clip.path)
            ctx.clip(using: clip.rule)
        }
        let group = n.style.opacity < 0.999
        if group {
            ctx.setAlpha(n.style.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawShape(n, in: ctx)
        for c in n.children { drawDefinitionChild(c, in: ctx) }
        if group { ctx.endTransparencyLayer() }
    }
}

// MARK: - Definitions as render nodes

/// The compiled subtree of a referenced element. Definitions are compiled with the document (they
/// sit in the render tree marked `isDefinition`), so masks, patterns and markers draw from them.
enum MockupSVGDefinitionNodes {
    static func node(for id: String, in doc: MockupSVGDocument) -> MockupSVGRenderNode? {
        guard let path = doc.definitionPaths[id] else { return nil }
        return doc.node(at: path)
    }
}

// MARK: - Clip paths

enum MockupSVGClip {
    struct Clip {
        let path: CGPath
        let rule: CGPathFillRule
    }

    /// The clip of `clipPath#id` applied to `n`, in `n`'s space.
    static func path(for id: String, node n: MockupSVGRenderNode, document doc: MockupSVGDocument) -> Clip? {
        guard let clipNode = MockupSVGDefinitionNodes.node(for: id, in: doc), clipNode.element.localName == "clipPath" else { return nil }
        var units = CGAffineTransform.identity
        if clipNode.element.attribute("clipPathUnits") == "objectBoundingBox" {
            let b = n.localBounds
            guard !b.isNull, b.width > 0, b.height > 0 else { return nil }
            units = CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY)
        }
        let out = CGMutablePath()
        var rule: CGPathFillRule?
        for c in clipNode.children where c.style.display && c.style.visible {
            let t = c.transform.concatenating(clipNode.transform).concatenating(units)
            switch c.shape {
            case .path(let p):
                out.addPath(p, transform: t)
            case .text(let layout):
                for r in layout.runs { out.addRect(r.rect, transform: t) }
            default:
                continue
            }
            // One CG clip takes one rule; the first child's clip-rule speaks for all.
            if rule == nil { rule = c.style.clipRule }
        }
        return Clip(path: out, rule: rule ?? .winding)
    }
}

// MARK: - Gradients

enum MockupSVGGradients {
    /// An attribute of a gradient, inherited through its href chain.
    static func attribute(_ name: String, of g: MockupSVGNode, in doc: MockupSVGDocument) -> String? {
        var current: MockupSVGNode? = g
        var seen = Set<String>()
        while let n = current {
            if let v = n.attribute(name) { return v }
            guard let raw = n.attribute("href") ?? n.attributes.first(where: { $0.name.hasSuffix(":href") })?.value,
                  let id = MockupSVGValues.fragment(raw), seen.insert(id).inserted,
                  let next = doc.definitions[id], next.localName.hasSuffix("Gradient") else { return nil }
            current = next
        }
        return nil
    }

    /// The first gradient in the href chain with stops supplies them.
    static func stops(of g: MockupSVGNode, in doc: MockupSVGDocument, style: MockupSVGStyle) -> [(Double, CGColor)] {
        var current: MockupSVGNode? = g
        var seen = Set<String>()
        while let n = current {
            let stops = n.elementChildren.filter { $0.localName == "stop" }
            if !stops.isEmpty {
                var out: [(Double, CGColor)] = []
                var last = 0.0
                for s in stops {
                    var off = s.attribute("offset").flatMap { MockupSVGValues.length($0, percent: true) }?.fraction ?? 0
                    off = max(min(max(off, 0), 1), last)
                    last = off
                    let color = s.attribute("stop-color").flatMap(MockupSVGValues.color) ?? .rgba(.black)
                    let opacity = s.attribute("stop-opacity").flatMap { MockupSVGValues.length($0, percent: true) }.map { min(max($0.fraction, 0), 1) } ?? 1
                    var st = style
                    if let c = s.attribute("color").flatMap(MockupSVGValues.color), case .rgba(let v) = c { st.color = v }
                    out.append((off, st.resolve(color, opacity: opacity)))
                }
                return out
            }
            guard let raw = n.attribute("href") ?? n.attributes.first(where: { $0.name.hasSuffix(":href") })?.value,
                  let id = MockupSVGValues.fragment(raw), seen.insert(id).inserted,
                  let next = doc.definitions[id], next.localName.hasSuffix("Gradient") else { return [] }
            current = next
        }
        return []
    }

    /// Fills the current clip with the gradient for a shape with bounding box `bbox`.
    static func draw(_ g: MockupSVGNode, bbox: CGRect, document doc: MockupSVGDocument, style: MockupSVGStyle, in ctx: CGContext) {
        let stops = stops(of: g, in: doc, style: style)
        guard !stops.isEmpty else { return }
        if stops.count == 1 {
            ctx.setFillColor(stops[0].1)
            ctx.fill(ctx.boundingBoxOfClipPath)
            return
        }
        let bboxUnits = (attribute("gradientUnits", of: g, in: doc) ?? "objectBoundingBox") == "objectBoundingBox"
        let vb = doc.viewBox
        func l(_ name: String, _ def: String, _ base: Double) -> Double {
            let v = MockupSVGValues.length(attribute(name, of: g, in: doc) ?? def, percent: true) ?? .number(0)
            return bboxUnits ? v.fraction : v.resolve(base)
        }
        if bboxUnits {
            ctx.concatenate(CGAffineTransform(a: bbox.width, b: 0, c: 0, d: bbox.height, tx: bbox.minX, ty: bbox.minY))
        }
        if let t = attribute("gradientTransform", of: g, in: doc).flatMap(MockupSVGValues.transform) { ctx.concatenate(t) }
        let spread = attribute("spreadMethod", of: g, in: doc) ?? "pad"
        // The clip's extent in gradient space, to know how many cycles reflect/repeat need.
        let area = ctx.boundingBoxOfClipPath
        let diag = (vb.width * vb.width + vb.height * vb.height).squareRoot() / 2.squareRoot()

        if g.localName == "linearGradient" {
            let p1 = CGPoint(x: l("x1", "0%", vb.width), y: l("y1", "0%", vb.height))
            let p2 = CGPoint(x: l("x2", "100%", vb.width), y: l("y2", "0%", vb.height))
            let dx = p2.x - p1.x, dy = p2.y - p1.y
            let len2 = dx * dx + dy * dy
            guard len2 > 1e-12 else {
                ctx.setFillColor(stops.last!.1)
                ctx.fill(area)
                return
            }
            // Project the clip's corners to find the range of t to cover.
            let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                           CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)]
            let ts = corners.map { (($0.x - p1.x) * dx + ($0.y - p1.y) * dy) / len2 }
            let (lo, hi) = spread == "pad" ? (0.0, 1.0) : (floor(ts.min()!), ceil(ts.max()!))
            guard let gradient = makeGradient(stops, spread: spread, from: lo, to: hi) else { return }
            let start = CGPoint(x: p1.x + dx * lo, y: p1.y + dy * lo), end = CGPoint(x: p1.x + dx * hi, y: p1.y + dy * hi)
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            let c = CGPoint(x: l("cx", "50%", vb.width), y: l("cy", "50%", vb.height))
            let r = l("r", "50%", diag)
            guard r > 0 else {
                ctx.setFillColor(stops.last!.1)
                ctx.fill(area)
                return
            }
            var f = CGPoint(x: attribute("fx", of: g, in: doc) != nil ? l("fx", "50%", vb.width) : c.x,
                            y: attribute("fy", of: g, in: doc) != nil ? l("fy", "50%", vb.height) : c.y)
            let fr = max(l("fr", "0%", diag), 0)
            // SVG 1.1 pulls a focal point outside the circle back onto it.
            let fd = hypot(f.x - c.x, f.y - c.y)
            if fd > r * 0.999 {
                let k = r * 0.999 / fd
                f = CGPoint(x: c.x + (f.x - c.x) * k, y: c.y + (f.y - c.y) * k)
            }
            var cycles = 1.0
            if spread != "pad" {
                let far = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                           CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)]
                    .map { hypot($0.x - f.x, $0.y - f.y) }.max() ?? r
                cycles = max(1, ceil((far + fd) / r) + 1)
            }
            guard let gradient = makeGradient(stops, spread: spread, from: 0, to: cycles) else { return }
            let endCenter = CGPoint(x: f.x + (c.x - f.x) * cycles, y: f.y + (c.y - f.y) * cycles)
            ctx.drawRadialGradient(gradient, startCenter: f, startRadius: fr, endCenter: endCenter, endRadius: r * cycles,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// A CGGradient covering t in [lo, hi]: the stops once for pad, repeated or mirrored per cycle otherwise.
    static func makeGradient(_ stops: [(Double, CGColor)], spread: String, from lo: Double, to hi: Double) -> CGGradient? {
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        let span = hi - lo
        let cycles = max(1, Int((span).rounded()))
        guard cycles <= 512 else { return nil }
        for k in 0..<cycles {
            let cycle = Int(lo) + k
            let mirrored = spread == "reflect" && abs(cycle) % 2 == 1
            let ordered = mirrored ? stops.reversed().map { (1 - $0.0, $0.1) } : stops
            for (off, color) in ordered {
                locations.append(CGFloat((Double(k) + off) / Double(cycles)))
                colors.append(color)
            }
        }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
    }
}

// MARK: - Patterns

enum MockupSVGPatterns {
    /// Fills the current clip with the pattern tile, drawn once into a bitmap and tiled.
    static func draw(_ p: MockupSVGNode, bbox: CGRect, renderer: inout MockupSVGDrawer, in ctx: CGContext) {
        let doc = renderer.doc
        guard renderer.depth < 4, let id = p.attribute("id"), let node = MockupSVGDefinitionNodes.node(for: id, in: doc) else { return }
        let bboxUnits = (p.attribute("patternUnits") ?? "objectBoundingBox") == "objectBoundingBox"
        let contentBBox = (p.attribute("patternContentUnits") ?? "userSpaceOnUse") == "objectBoundingBox"
        let vb = doc.viewBox
        func l(_ name: String, _ base: Double, _ bboxBase: Double) -> Double {
            let v = MockupSVGValues.length(p.attribute(name) ?? "0", percent: true) ?? .number(0)
            return bboxUnits ? v.fraction * bboxBase : v.resolve(base)
        }
        if bboxUnits, bbox.isNull || bbox.width <= 0 || bbox.height <= 0 { return }
        var tile = CGRect(x: l("x", vb.width, bbox.width), y: l("y", vb.height, bbox.height),
                          width: l("width", vb.width, bbox.width), height: l("height", vb.height, bbox.height))
        if bboxUnits { tile.origin.x += bbox.minX; tile.origin.y += bbox.minY }
        guard tile.width > 0, tile.height > 0 else { return }
        if let t = p.attribute("patternTransform").flatMap(MockupSVGValues.transform) { ctx.concatenate(t) }

        let device = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(2, min(8, (abs(device.a * device.d - device.b * device.c)).squareRoot()))
        let w = max(1, Int((tile.width * scale).rounded())), h = max(1, Int((tile.height * scale).rounded()))
        guard w * h <= 16_000_000, let tctx = MockupSVGRenderer.bitmapContext(width: w, height: h) else { return }
        tctx.translateBy(x: 0, y: CGFloat(h))
        tctx.scaleBy(x: CGFloat(w) / tile.width, y: -CGFloat(h) / tile.height)
        if let vbRaw = p.attribute("viewBox"), let pvb = MockupSVGValues.viewBox(vbRaw), pvb.width > 0, pvb.height > 0 {
            let ar = p.attribute("preserveAspectRatio").flatMap(MockupSVGValues.aspectRatio) ?? .default
            tctx.concatenate(ar.transform(viewBox: pvb, into: CGRect(origin: .zero, size: tile.size)))
        } else if contentBBox {
            tctx.concatenate(CGAffineTransform(a: bbox.width, b: 0, c: 0, d: bbox.height, tx: 0, ty: 0))
        }
        var inner = MockupSVGDrawer(doc: doc, options: MockupSVGRenderOptions())
        inner.depth = renderer.depth + 1
        for c in node.children { inner.drawDefinitionChild(c, in: tctx) }
        guard let image = tctx.makeImage() else { return }
        // draw(_:in:byTiling:) tiles from the rect's origin across the clip; flip about the tile
        // so each image draws upright (CGImage is Y-up) on the same grid.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: tile.minY * 2 + tile.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: tile, byTiling: true)
        ctx.restoreGState()
    }
}

// MARK: - Markers

enum MockupSVGMarkers {
    struct Vertex {
        let point: CGPoint
        let angle: Double // degrees
    }

    static func draw(for n: MockupSVGRenderNode, path: CGPath, renderer: inout MockupSVGDrawer, in ctx: CGContext) {
        let s = n.style
        guard ["path", "line", "polyline", "polygon"].contains(n.element.localName),
              !s.markerStart.isEmpty || !s.markerMid.isEmpty || !s.markerEnd.isEmpty else { return }
        let verts = vertices(path)
        guard !verts.isEmpty else { return }
        for (i, v) in verts.enumerated() {
            let id = i == 0 ? s.markerStart : i == verts.count - 1 ? s.markerEnd : s.markerMid
            guard !id.isEmpty else { continue }
            drawMarker(id, at: v, isStart: i == 0, strokeWidth: s.strokeWidth, renderer: &renderer, in: ctx)
        }
    }

    static func drawMarker(_ id: String, at v: Vertex, isStart: Bool, strokeWidth: Double, renderer: inout MockupSVGDrawer, in ctx: CGContext) {
        let doc = renderer.doc
        guard renderer.depth < 4, let m = doc.definitions[id], m.localName == "marker",
              let node = MockupSVGDefinitionNodes.node(for: id, in: doc) else { return }
        func l(_ name: String, _ def: Double) -> Double {
            m.attribute(name).flatMap { MockupSVGValues.length($0, percent: false) }?.resolve(0) ?? def
        }
        let mw = l("markerWidth", 3), mh = l("markerHeight", 3)
        guard mw > 0, mh > 0 else { return }
        var angle = 0.0
        switch m.attribute("orient") ?? "0" {
        case "auto": angle = v.angle
        case "auto-start-reverse": angle = isStart ? v.angle + 180 : v.angle
        case let raw: angle = MockupSVGValues.number(raw.hasSuffix("deg") ? String(raw.dropLast(3)) : raw) ?? 0
        }
        let units = (m.attribute("markerUnits") ?? "strokeWidth") == "strokeWidth" ? strokeWidth : 1
        var content = CGAffineTransform.identity
        if let raw = m.attribute("viewBox"), let vb = MockupSVGValues.viewBox(raw), vb.width > 0, vb.height > 0 {
            let ar = m.attribute("preserveAspectRatio").flatMap(MockupSVGValues.aspectRatio) ?? .default
            content = ar.transform(viewBox: vb, into: CGRect(x: 0, y: 0, width: mw, height: mh))
        }
        let ref = CGPoint(x: l("refX", 0), y: l("refY", 0)).applying(content)
        ctx.saveGState()
        ctx.translateBy(x: v.point.x, y: v.point.y)
        ctx.rotate(by: angle * .pi / 180)
        ctx.scaleBy(x: units, y: units)
        ctx.translateBy(x: -ref.x, y: -ref.y)
        // A marker's viewport clips its content (overflow: hidden).
        ctx.clip(to: CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.concatenate(content)
        var inner = renderer
        inner.depth += 1
        for c in node.children { inner.drawDefinitionChild(c, in: ctx) }
        ctx.restoreGState()
    }

    /// The path's vertices with their marker angles: the outgoing direction at the start, the
    /// incoming at the end, and the bisector in between.
    static func vertices(_ path: CGPath) -> [Vertex] {
        var points: [CGPoint] = []
        var inDir: [CGPoint?] = []
        var outDir: [CGPoint?] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        func push(_ p: CGPoint, in i: CGPoint?) {
            points.append(p)
            inDir.append(i)
            outDir.append(nil)
        }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]
                start = current
                push(current, in: nil)
            case .addLineToPoint:
                let p = e.points[0]
                outDir[outDir.count - 1] = CGPoint(x: p.x - current.x, y: p.y - current.y)
                push(p, in: CGPoint(x: p.x - current.x, y: p.y - current.y))
                current = p
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                outDir[outDir.count - 1] = CGPoint(x: c.x - current.x, y: c.y - current.y)
                push(p, in: CGPoint(x: p.x - c.x, y: p.y - c.y))
                current = p
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                outDir[outDir.count - 1] = CGPoint(x: c1.x - current.x, y: c1.y - current.y)
                push(p, in: CGPoint(x: p.x - c2.x, y: p.y - c2.y))
                current = p
            case .closeSubpath:
                if current != start {
                    outDir[outDir.count - 1] = CGPoint(x: start.x - current.x, y: start.y - current.y)
                    push(start, in: CGPoint(x: start.x - current.x, y: start.y - current.y))
                }
                current = start
            @unknown default:
                break
            }
        }
        func deg(_ v: CGPoint) -> Double { atan2(v.y, v.x) * 180 / .pi }
        return points.indices.map { i in
            let a: Double
            switch (inDir[i], outDir[i]) {
            case let (i?, o?):
                let ai = deg(i), ao = deg(o)
                var d = ao - ai
                if d > 180 { d -= 360 }
                if d < -180 { d += 360 }
                a = ai + d / 2
            case let (i?, nil): a = deg(i)
            case let (nil, o?): a = deg(o)
            default: a = 0
            }
            return Vertex(point: points[i], angle: a)
        }
    }
}

// MARK: - Mask image

enum MockupSVGMaskImage {
    /// A grayscale image whose value is luminance × alpha of `rgba` (premultiplied sRGB).
    static func luminance(of rgba: CGImage) -> CGImage? {
        let w = rgba.width, h = rgba.height
        guard let src = MockupSVGRenderer.bitmapContext(width: w, height: h) else { return nil }
        src.draw(rgba, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = src.data else { return nil }
        let bpr = src.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        var gray = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4
                // Premultiplied channels already carry alpha: luminance × alpha in one step.
                let l = 0.2125 * Double(px[o]) + 0.7154 * Double(px[o + 1]) + 0.0721 * Double(px[o + 2])
                gray[y * w + x] = UInt8(min(255, max(0, l.rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
