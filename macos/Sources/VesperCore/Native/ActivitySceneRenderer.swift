import CoreGraphics
import CoreText
import Foundation

/// CoreGraphics renderer shared by SwiftUI `ActivitySceneView` and `ActivitySceneTests` bitmap snapshots.
public enum ActivitySceneRenderer {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Renders `kind` into a Y-down `CGContext` (SwiftUI `Canvas` / SVG coordinate system).
    public static func render(
        _ kind: ActivitySceneKind,
        at t: Double,
        palette: ActivityScenePalette,
        in ctx: CGContext,
        size: CGSize
    ) {
        render(kind, at: t, palette: palette, reduceMotion: false, opacity: 1, in: ctx, size: size)
    }

    /// Renders `kind` into a Y-down `CGContext` with optional `reduceMotion` and layer `opacity`.
    public static func render(
        _ kind: ActivitySceneKind,
        at t: Double,
        palette: ActivityScenePalette,
        reduceMotion: Bool = false,
        opacity: Double = 1,
        in ctx: CGContext,
        size: CGSize
    ) {
        guard size.width > 0, size.height > 0, opacity > 0.001 else { return }
        let def = ActivitySceneCatalog.definition(for: kind)
        let vb = ActivitySceneDefinition.viewBoxSize
        let scale = min(size.width / vb.width, size.height / vb.height)
        let dx = (size.width - vb.width * scale) * 0.5
        let dy = (size.height - vb.height * scale) * 0.5

        let blurRadius: Double = if !reduceMotion, let rootAnim = def.rootAnimation {
            rootAnim.pose(at: t).blur
        } else {
            0
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        let usesOuterLayer = opacity < 0.999
        if usesOuterLayer {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setAlpha(1)
        }
        defer {
            if usesOuterLayer { ctx.endTransparencyLayer() }
        }

        if blurRadius > 0.05,
           let blurred = renderBlurredBitmap(
               nodes: def.nodes,
               at: t,
               palette: palette,
               reduceMotion: reduceMotion,
               size: size,
               dx: dx,
               dy: dy,
               scale: scale,
               blurRadius: blurRadius * scale
           ) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(blurred, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
            return
        }

        ctx.translateBy(x: dx, y: dy)
        ctx.scaleBy(x: scale, y: scale)
        for node in def.nodes {
            renderNode(node, at: t, palette: palette, reduceMotion: reduceMotion, in: ctx)
        }
    }

    /// Renders `kind` into a deterministic RGBA8888 bitmap (`size.width * size.height * 4` bytes, top-down).
    public static func renderBitmap(
        _ kind: ActivitySceneKind,
        at t: Double,
        palette: ActivityScenePalette = .dark,
        reduceMotion: Bool = false,
        size: CGSize = CGSize(width: 264, height: 112)
    ) -> Data {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            render(
                kind,
                at: t,
                palette: palette,
                reduceMotion: reduceMotion,
                opacity: 1,
                in: ctx,
                size: CGSize(width: width, height: height)
            )
        }
        return Data(buffer)
    }

    // MARK: - Node Rendering

    private static func renderNode(
        _ node: SceneNode,
        at t: Double,
        palette: ActivityScenePalette,
        reduceMotion: Bool,
        in ctx: CGContext
    ) {
        switch node {
        case .viewport(let x, let y, let width, let height, let children):
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x, y: y, width: width, height: height))
            ctx.translateBy(x: x, y: y)
            for child in children {
                renderNode(child, at: t, palette: palette, reduceMotion: reduceMotion, in: ctx)
            }
            ctx.restoreGState()

        case .group(let style, let children):
            let pose = resolvedPose(for: style, at: t, palette: palette, reduceMotion: reduceMotion)
            guard pose.opacity > 0.001, abs(pose.sx) >= 1e-4, abs(pose.sy) >= 1e-4 else { return }

            ctx.saveGState()
            defer { ctx.restoreGState() }
            applyTransform(pose, origin: style.transformOrigin, node: node, in: ctx)

            let usesLayer = pose.opacity < 0.999
            if usesLayer {
                ctx.setAlpha(pose.opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setAlpha(1)
            }
            defer {
                if usesLayer { ctx.endTransparencyLayer() }
            }
            for child in children {
                renderNode(child, at: t, palette: palette, reduceMotion: reduceMotion, in: ctx)
            }

        case .text(let x, let y, let string, let fontSize, let fontWeight, let anchor, let fill, let style):
            let pose = resolvedPose(for: style, at: t, palette: palette, reduceMotion: reduceMotion)
            guard pose.opacity > 0.001, abs(pose.sx) >= 1e-4, abs(pose.sy) >= 1e-4 else { return }

            ctx.saveGState()
            defer { ctx.restoreGState() }
            applyTransform(pose, origin: style.transformOrigin, node: node, in: ctx)

            let baseFont = CTFontCreateUIFontForLanguage(.system, CGFloat(fontSize), nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(fontSize), nil)
            let font: CTFont = if fontWeight >= 600 {
                CTFontCreateCopyWithSymbolicTraits(baseFont, CGFloat(fontSize), nil, .traitBold, .traitBold) ?? baseFont
            } else {
                baseFont
            }
            let rgba = palette.resolve(fill)
            let color = cgColor(rgba, alpha: rgba.alpha * pose.opacity)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let attrStr = NSAttributedString(string: string, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let drawX: Double = switch anchor {
            case .start: x
            case .middle: x - width * 0.5
            case .end: x - width
            }
            ctx.textMatrix = .identity
            ctx.translateBy(x: drawX, y: y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)

        case .rect, .circle, .ellipse, .line, .polyline, .polygon, .path:
            guard let style = leafStyle(for: node),
                  let path = leafPath(for: node) else { return }
            let pose = resolvedPose(for: style, at: t, palette: palette, reduceMotion: reduceMotion)
            guard pose.opacity > 0.001, abs(pose.sx) >= 1e-4, abs(pose.sy) >= 1e-4 else { return }

            ctx.saveGState()
            defer { ctx.restoreGState() }
            applyTransform(pose, origin: style.transformOrigin, node: node, in: ctx)

            if let fillRGBA = pose.fillOverride ?? style.fill.map({ palette.resolve($0) }) {
                let alpha = fillRGBA.alpha * style.fillOpacity * pose.opacity
                if alpha > 0.001 {
                    ctx.setFillColor(cgColor(fillRGBA, alpha: alpha))
                    ctx.addPath(path)
                    ctx.fillPath()
                }
            }

            if let strokeToken = style.stroke, style.strokeWidth > 0 {
                let strokeRGBA = palette.resolve(strokeToken)
                let alpha = strokeRGBA.alpha * style.strokeOpacity * pose.opacity
                if alpha > 0.001 {
                    let strokedPath: CGPath?
                    if style.pathLengthOne {
                        if pose.dashOffset >= 0.9999 {
                            strokedPath = nil
                        } else if pose.dashOffset <= 0.0001 {
                            strokedPath = path
                        } else {
                            let end = CGFloat(max(0, min(1, 1 - pose.dashOffset)))
                            strokedPath = SVGPathParser.trimmedPath(path, from: 0, to: end)
                        }
                        ctx.setLineDash(phase: 0, lengths: [])
                    } else {
                        strokedPath = path
                        if let dash = style.dashArray, !dash.isEmpty {
                            ctx.setLineDash(phase: CGFloat(pose.dashOffset), lengths: dash.map { CGFloat($0) })
                        } else {
                            ctx.setLineDash(phase: 0, lengths: [])
                        }
                    }

                    if let strokedPath {
                        ctx.setStrokeColor(cgColor(strokeRGBA, alpha: alpha))
                        ctx.setLineWidth(style.strokeWidth)
                        ctx.setLineCap(cgLineCap(style.lineCap))
                        ctx.setLineJoin(cgLineJoin(style.lineJoin))
                        ctx.addPath(strokedPath)
                        ctx.strokePath()
                    }
                }
            }
        }
    }

    private static func resolvedPose(
        for style: SceneStyle,
        at t: Double,
        palette: ActivityScenePalette,
        reduceMotion: Bool
    ) -> MotionPose {
        let base = MotionPose(
            transform: style.baseTransform,
            opacity: style.opacity,
            dashOffset: style.baseDashOffset
        )
        guard !reduceMotion, let anim = style.animation else { return base }
        return anim.pose(
            at: t,
            base: base,
            baseFill: style.fill.map { palette.resolve($0) },
            palette: palette
        )
    }

    private static func applyTransform(
        _ pose: MotionPose,
        origin: SceneTransformOrigin,
        node: SceneNode,
        in ctx: CGContext
    ) {
        if pose.tx != 0 || pose.ty != 0 {
            ctx.translateBy(x: pose.tx, y: pose.ty)
        }
        guard pose.rot != 0 || pose.sx != 1 || pose.sy != 1 else { return }
        let pivot = resolveOrigin(origin, for: node)
        if pivot.x != 0 || pivot.y != 0 { ctx.translateBy(x: pivot.x, y: pivot.y) }
        if pose.rot != 0 { ctx.rotate(by: pose.rot * .pi / 180) }
        if pose.sx != 1 || pose.sy != 1 { ctx.scaleBy(x: pose.sx, y: pose.sy) }
        if pivot.x != 0 || pivot.y != 0 { ctx.translateBy(x: -pivot.x, y: -pivot.y) }
    }

    private static func resolveOrigin(_ origin: SceneTransformOrigin, for node: SceneNode) -> CGPoint {
        switch origin {
        case .zero:
            return .zero
        case .point(let x, let y):
            return CGPoint(x: x, y: y)
        case .center, .leftCenter, .centerBottom, .leftBottom:
            let bbox = node.boundingBox
            guard !bbox.isNull else { return .zero }
            switch origin {
            case .center: return CGPoint(x: bbox.midX, y: bbox.midY)
            case .leftCenter: return CGPoint(x: bbox.minX, y: bbox.midY)
            case .centerBottom: return CGPoint(x: bbox.midX, y: bbox.maxY)
            case .leftBottom: return CGPoint(x: bbox.minX, y: bbox.maxY)
            default: return .zero
            }
        }
    }

    private static func leafStyle(for node: SceneNode) -> SceneStyle? {
        switch node {
        case .rect(_, _, _, _, _, _, let style),
             .circle(_, _, _, let style),
             .ellipse(_, _, _, _, let style),
             .line(_, _, _, _, let style),
             .polyline(_, let style),
             .polygon(_, let style),
             .path(_, let style):
            return style
        default:
            return nil
        }
    }

    private static func leafPath(for node: SceneNode) -> CGPath? {
        switch node {
        case .rect(let x, let y, let width, let height, let rx, let ry, _):
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let crx = min(rx, width * 0.5)
            let cry = min(ry ?? rx, height * 0.5)
            if crx > 0 || cry > 0 {
                return CGPath(roundedRect: rect, cornerWidth: crx, cornerHeight: cry, transform: nil)
            }
            return CGPath(rect: rect, transform: nil)
        case .circle(let cx, let cy, let r, _):
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
        case .ellipse(let cx, let cy, let rx, let ry, _):
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
        case .line(let x1, let y1, let x2, let y2, _):
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x2, y: y2))
            return p
        case .polyline(let pts, _), .polygon(let pts, _):
            guard let first = pts.first else { return nil }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: first.x, y: first.y))
            for pt in pts.dropFirst() {
                p.addLine(to: CGPoint(x: pt.x, y: pt.y))
            }
            if case .polygon = node { p.closeSubpath() }
            return p
        case .path(let d, _):
            return SVGPathParser.parse(d)
        default:
            return nil
        }
    }

    private static func cgLineCap(_ cap: SceneLineCap) -> CGLineCap {
        switch cap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }

    private static func cgLineJoin(_ join: SceneLineJoin) -> CGLineJoin {
        switch join {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }

    private static func cgColor(_ rgba: RGBA, alpha: Double) -> CGColor {
        CGColor(
            colorSpace: srgb,
            components: [
                CGFloat(rgba.red),
                CGFloat(rgba.green),
                CGFloat(rgba.blue),
                CGFloat(min(max(alpha, 0), 1)),
            ]
        ) ?? CGColor(gray: 1, alpha: CGFloat(alpha))
    }

    // MARK: - 3-Pass Box Blur for `scene-focus`

    private static func renderBlurredBitmap(
        nodes: [SceneNode],
        at t: Double,
        palette: ActivityScenePalette,
        reduceMotion: Bool,
        size: CGSize,
        dx: Double,
        dy: Double,
        scale: Double,
        blurRadius: Double
    ) -> CGImage? {
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        let radius = max(1, Int((blurRadius * 0.85).rounded()))
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let tmp = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            tmp.translateBy(x: 0, y: CGFloat(height))
            tmp.scaleBy(x: 1, y: -1)
            tmp.translateBy(x: dx, y: dy)
            tmp.scaleBy(x: scale, y: scale)
            for node in nodes {
                renderNode(node, at: t, palette: palette, reduceMotion: reduceMotion, in: tmp)
            }
            return true
        }
        guard drew else { return nil }

        var scratch = [UInt8](repeating: 0, count: buffer.count)
        for _ in 0..<3 {
            boxBlurHorizontal(src: buffer, dst: &scratch, width: width, height: height, radius: radius)
            boxBlurVertical(src: scratch, dst: &buffer, width: width, height: height, radius: radius)
        }

        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func boxBlurHorizontal(src: [UInt8], dst: inout [UInt8], width: Int, height: Int, radius: Int) {
        let window = radius * 2 + 1
        let half = window / 2
        for y in 0..<height {
            let rowStart = y * width * 4
            var rSum = 0, gSum = 0, bSum = 0, aSum = 0
            for dx in -radius...radius {
                let x = min(max(dx, 0), width - 1)
                let idx = rowStart + x * 4
                rSum += Int(src[idx])
                gSum += Int(src[idx + 1])
                bSum += Int(src[idx + 2])
                aSum += Int(src[idx + 3])
            }
            for x in 0..<width {
                let outIdx = rowStart + x * 4
                dst[outIdx] = UInt8((rSum + half) / window)
                dst[outIdx + 1] = UInt8((gSum + half) / window)
                dst[outIdx + 2] = UInt8((bSum + half) / window)
                dst[outIdx + 3] = UInt8((aSum + half) / window)

                let subX = max(x - radius, 0)
                let addX = min(x + radius + 1, width - 1)
                let subIdx = rowStart + subX * 4
                let addIdx = rowStart + addX * 4
                rSum += Int(src[addIdx]) - Int(src[subIdx])
                gSum += Int(src[addIdx + 1]) - Int(src[subIdx + 1])
                bSum += Int(src[addIdx + 2]) - Int(src[subIdx + 2])
                aSum += Int(src[addIdx + 3]) - Int(src[subIdx + 3])
            }
        }
    }

    private static func boxBlurVertical(src: [UInt8], dst: inout [UInt8], width: Int, height: Int, radius: Int) {
        let window = radius * 2 + 1
        let half = window / 2
        let stride = width * 4
        for x in 0..<width {
            let colOffset = x * 4
            var rSum = 0, gSum = 0, bSum = 0, aSum = 0
            for dy in -radius...radius {
                let y = min(max(dy, 0), height - 1)
                let idx = y * stride + colOffset
                rSum += Int(src[idx])
                gSum += Int(src[idx + 1])
                bSum += Int(src[idx + 2])
                aSum += Int(src[idx + 3])
            }
            for y in 0..<height {
                let outIdx = y * stride + colOffset
                dst[outIdx] = UInt8((rSum + half) / window)
                dst[outIdx + 1] = UInt8((gSum + half) / window)
                dst[outIdx + 2] = UInt8((bSum + half) / window)
                dst[outIdx + 3] = UInt8((aSum + half) / window)

                let subY = max(y - radius, 0)
                let addY = min(y + radius + 1, height - 1)
                let subIdx = subY * stride + colOffset
                let addIdx = addY * stride + colOffset
                rSum += Int(src[addIdx]) - Int(src[subIdx])
                gSum += Int(src[addIdx + 1]) - Int(src[subIdx + 1])
                bSum += Int(src[addIdx + 2]) - Int(src[subIdx + 2])
                aSum += Int(src[addIdx + 3]) - Int(src[subIdx + 3])
            }
        }
    }
}
