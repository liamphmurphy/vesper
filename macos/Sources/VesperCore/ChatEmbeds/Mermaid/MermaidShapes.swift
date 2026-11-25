import CoreGraphics
import Foundation

/// Flowchart node shapes (also used for state-diagram pseudo-states): how big each is around its
/// label, its outline for clipping edge ends, and how it's drawn with profile-v1 elements (no arc
/// commands in paths, so curves are cubic Béziers).
enum MermaidShape: Equatable {
    case rect, round, stadium, subroutine, cylinder, circle, doubleCircle, rhombus, hexagon
    case leanRight, leanLeft, trapezoid, trapezoidAlt, asymmetric

    static let padX = 16.0
    static let padY = 10.0
    static let cylinderRY = 7.0

    /// The bounding box for a label of `text` size.
    func size(text: CGSize) -> CGSize {
        let w = text.width, h = text.height
        switch self {
        case .rect, .round:
            return CGSize(width: w + Self.padX * 2, height: h + Self.padY * 2)
        case .stadium:
            let bh = h + Self.padY * 2
            return CGSize(width: w + Self.padX * 2 + bh / 2, height: bh)
        case .subroutine:
            return CGSize(width: w + Self.padX * 2 + 16, height: h + Self.padY * 2)
        case .cylinder:
            return CGSize(width: w + Self.padX * 2, height: h + Self.padY * 2 + Self.cylinderRY * 2)
        case .circle:
            let d = max(w, h) + Self.padY * 2 + 4
            return CGSize(width: d, height: d)
        case .doubleCircle:
            let d = max(w, h) + Self.padY * 2 + 14
            return CGSize(width: d, height: d)
        case .rhombus:
            // A label box w×h fits a rhombus W×H when w/W + h/H ≤ 1; keep the rhombus fairly flat.
            let bh = max(h * 2 + 12, 52)
            let bw = (w + 16) / (1 - (h + 4) / bh)
            return CGSize(width: max(bw, bh), height: bh)
        case .hexagon:
            let bh = h + Self.padY * 2
            return CGSize(width: w + Self.padX * 2 + bh / 2, height: bh)
        case .leanRight, .leanLeft, .asymmetric:
            let bh = h + Self.padY * 2
            return CGSize(width: w + Self.padX * 2 + bh * 0.5, height: bh)
        case .trapezoid, .trapezoidAlt:
            let bh = h + Self.padY * 2
            return CGSize(width: w + Self.padX * 2 + bh, height: bh)
        }
    }

    /// Where the label's centre sits relative to the box centre.
    func textOffset(in r: CGRect) -> CGPoint {
        switch self {
        case .cylinder: CGPoint(x: 0, y: Self.cylinderRY / 2)
        case .asymmetric: CGPoint(x: r.height * 0.125, y: 0)
        default: .zero
        }
    }

    /// The outline edges are clipped to, or nil when the bounding box is the outline.
    func outline(_ r: CGRect) -> [CGPoint]? {
        let x = r.minX, y = r.minY, w = r.width, h = r.height
        switch self {
        case .rect, .round, .subroutine, .cylinder:
            return nil
        case .rhombus:
            return [CGPoint(x: x + w / 2, y: y), CGPoint(x: x + w, y: y + h / 2), CGPoint(x: x + w / 2, y: y + h), CGPoint(x: x, y: y + h / 2)]
        case .hexagon:
            let s = h / 4
            return [CGPoint(x: x + s, y: y), CGPoint(x: x + w - s, y: y), CGPoint(x: x + w, y: y + h / 2),
                    CGPoint(x: x + w - s, y: y + h), CGPoint(x: x + s, y: y + h), CGPoint(x: x, y: y + h / 2)]
        case .leanRight, .leanLeft, .trapezoid, .trapezoidAlt, .asymmetric:
            return polygon(r)
        case .circle, .doubleCircle, .stadium:
            // Polygonal approximations are close enough to land an arrow tip on the curve.
            return (0..<48).map { k in
                let t = Double(k) / 48 * 2 * .pi
                if self == .stadium {
                    let rr = h / 2
                    let cx = cos(t) >= 0 ? x + w - rr : x + rr
                    return CGPoint(x: cx + rr * cos(t), y: y + h / 2 + rr * sin(t))
                }
                return CGPoint(x: r.midX + w / 2 * cos(t), y: r.midY + h / 2 * sin(t))
            }
        }
    }

    private func polygon(_ r: CGRect) -> [CGPoint] {
        let x = r.minX, y = r.minY, w = r.width, h = r.height
        switch self {
        case .leanRight:
            let s = h * 0.5
            return [CGPoint(x: x + s, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w - s, y: y + h), CGPoint(x: x, y: y + h)]
        case .leanLeft:
            let s = h * 0.5
            return [CGPoint(x: x, y: y), CGPoint(x: x + w - s, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x + s, y: y + h)]
        case .trapezoid:
            let s = h * 0.5
            return [CGPoint(x: x + s, y: y), CGPoint(x: x + w - s, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
        case .trapezoidAlt:
            let s = h * 0.5
            return [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w - s, y: y + h), CGPoint(x: x + s, y: y + h)]
        case .asymmetric:
            let s = h * 0.25
            return [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h), CGPoint(x: x + s, y: y + h / 2)]
        default:
            return []
        }
    }

    func draw(_ svg: inout MermaidSVG, _ r: CGRect, fill: String, stroke: String, width: Double, dash: String?) {
        switch self {
        case .rect:
            svg.rect(r, fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
        case .round:
            svg.rect(r, rx: 8, fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
        case .stadium:
            svg.rect(r, rx: r.height / 2, fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
        case .subroutine:
            svg.rect(r, fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
            svg.line(CGPoint(x: r.minX + 8, y: r.minY), CGPoint(x: r.minX + 8, y: r.maxY), stroke: stroke, width: width)
            svg.line(CGPoint(x: r.maxX - 8, y: r.minY), CGPoint(x: r.maxX - 8, y: r.maxY), stroke: stroke, width: width)
        case .cylinder:
            let ry = Self.cylinderRY, a = r.width / 2, cx = r.midX
            let top = r.minY + ry, bottom = r.maxY - ry
            let n = MermaidSVG.num
            let body = "M\(n(r.minX)),\(n(top)) " + Self.halfEllipse(cx: cx, cy: top, a: a, b: ry, upper: true)
                + " L\(n(r.maxX)),\(n(bottom)) " + Self.halfEllipse(cx: cx, cy: bottom, a: a, b: ry, upper: false, reversed: true) + " Z"
            svg.path(body, fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
            svg.path("M\(n(r.minX)),\(n(top)) " + Self.halfEllipse(cx: cx, cy: top, a: a, b: ry, upper: false), stroke: stroke, strokeWidth: width)
        case .circle:
            svg.add("circle", [("cx", MermaidSVG.num(r.midX)), ("cy", MermaidSVG.num(r.midY)), ("r", MermaidSVG.num(r.width / 2)),
                               ("fill", fill), ("stroke", stroke), ("stroke-width", MermaidSVG.num(width)), ("stroke-dasharray", dash)])
        case .doubleCircle:
            svg.add("circle", [("cx", MermaidSVG.num(r.midX)), ("cy", MermaidSVG.num(r.midY)), ("r", MermaidSVG.num(r.width / 2)),
                               ("fill", fill), ("stroke", stroke), ("stroke-width", MermaidSVG.num(width)), ("stroke-dasharray", dash)])
            svg.add("circle", [("cx", MermaidSVG.num(r.midX)), ("cy", MermaidSVG.num(r.midY)), ("r", MermaidSVG.num(r.width / 2 - 5)),
                               ("fill", "none"), ("stroke", stroke), ("stroke-width", MermaidSVG.num(width))])
        default:
            svg.polygon(outline(r) ?? [], fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
        }
    }

    /// Half an ellipse as two cubic quarter arcs, from the left end to the right end (or reversed).
    static func halfEllipse(cx: Double, cy: Double, a: Double, b: Double, upper: Bool, reversed: Bool = false) -> String {
        let k = 0.5523, n = MermaidSVG.num
        let s = upper ? -1.0 : 1.0
        if !reversed {
            return "C\(n(cx - a)),\(n(cy + s * k * b)) \(n(cx - k * a)),\(n(cy + s * b)) \(n(cx)),\(n(cy + s * b)) "
                + "C\(n(cx + k * a)),\(n(cy + s * b)) \(n(cx + a)),\(n(cy + s * k * b)) \(n(cx + a)),\(n(cy))"
        }
        return "C\(n(cx + a)),\(n(cy + s * k * b)) \(n(cx + k * a)),\(n(cy + s * b)) \(n(cx)),\(n(cy + s * b)) "
            + "C\(n(cx - k * a)),\(n(cy + s * b)) \(n(cx - a)),\(n(cy + s * k * b)) \(n(cx - a)),\(n(cy))"
    }
}
