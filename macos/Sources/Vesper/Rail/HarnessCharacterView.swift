import SwiftUI

/// Animated harness characters drawn on a 64x64 grid for the chat composer's status strip and
/// usage button. Reduce Motion freezes the pose at t = 0.
struct HarnessCharacterView: View {
    enum Kind { case robot, comet, jet }

    let kind: Kind
    let working: Bool
    var size: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// nil for a harness without a character (the caller keeps the avatar).
    static func kind(for harness: String) -> Kind? {
        switch harness {
        case "claude-code": .robot
        case "codex": .comet
        case "antigravity": .jet
        default: nil
        }
    }

    nonisolated static func color(for kind: Kind) -> Color {
        switch kind {
        case .robot: Color(hex: 0xF2A97E)
        case .comet: Color(hex: 0xB09AEF)
        case .jet: Color(hex: 0x78BFDE)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvas in
                let scale = min(canvas.width, canvas.height) / 64
                var c = ctx
                c.scaleBy(x: scale, y: scale)
                CharacterDrawing.draw(kind, working: working, t: t, in: &c)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Motion

/// A CSS animation's per-property state: translate, rotate (degrees), scale and opacity.
struct Pose: Equatable {
    var tx = 0.0, ty = 0.0, rot = 0.0, sx = 1.0, sy = 1.0, opacity = 1.0

    func mixed(with o: Pose, _ f: Double) -> Pose {
        Pose(tx: tx + (o.tx - tx) * f, ty: ty + (o.ty - ty) * f, rot: rot + (o.rot - rot) * f,
             sx: sx + (o.sx - sx) * f, sy: sy + (o.sy - sy) * f, opacity: opacity + (o.opacity - opacity) * f)
    }
}

enum Easing {
    case linear, ease, easeInOut, steps2

    func apply(_ x: Double) -> Double {
        switch self {
        case .linear: x
        case .ease: Self.bezier(0.25, 0.1, 0.25, 1, x)
        case .easeInOut: Self.bezier(0.42, 0, 0.58, 1, x)
        case .steps2: (x * 2).rounded(.down) / 2
        }
    }

    /// CSS cubic-bezier(x1, y1, x2, y2) solved for y at time x.
    private static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        func at(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {
            s = (lo + hi) / 2
            if at(x1, x2, s) < x { lo = s } else { hi = s }
        }
        return at(y1, y2, s)
    }
}

/// A CSS @keyframes animation: `frames` are (offset 0...1, pose); an implicit 0% and 100% frame
/// is `base`. The timing function applies to each interval, as in CSS.
struct CSSAnimation {
    var duration: Double
    var delay = 0.0
    var easing: Easing = .ease
    var alternate = false
    var base = Pose()
    var frames: [(Double, Pose)]

    func pose(at t: Double) -> Pose {
        var p = ((t - delay) / duration).truncatingRemainder(dividingBy: alternate ? 2 : 1)
        if p < 0 { p += alternate ? 2 : 1 }
        if alternate, p >= 1 { p = 2 - p }
        var all = frames
        if all.first?.0 != 0 { all.insert((0, base), at: 0) }
        if all.last?.0 != 1 { all.append((1, base)) }
        for i in 1..<all.count where p <= all[i].0 || i == all.count - 1 {
            let (a, b) = (all[i - 1], all[i])
            let f = b.0 > a.0 ? (p - a.0) / (b.0 - a.0) : 1
            return a.1.mixed(with: b.1, easing.apply(min(max(f, 0), 1)))
        }
        return base
    }
}

/// The keyframes of globals.css, by name.
private enum Motion {
    static let blink = CSSAnimation(duration: 6, easing: .ease, frames: [
        (0.42, Pose()), (0.44, Pose(opacity: 0.1)), (0.46, Pose()),
    ])
    static let breathe = CSSAnimation(duration: 4.8, easing: .easeInOut, frames: [(0.5, Pose(ty: -1))])
    static let tap = CSSAnimation(duration: 0.65, easing: .easeInOut, frames: [
        (0.25, Pose(ty: -2, rot: -2)), (0.5, Pose(ty: 0, rot: 2)), (0.75, Pose(ty: -2, rot: -2)),
    ])
    static let leg = CSSAnimation(duration: 0.65, easing: .easeInOut, frames: [(0.5, Pose(ty: -3))])
    static let legB = CSSAnimation(duration: 0.65, delay: -0.325, easing: .easeInOut, frames: [(0.5, Pose(ty: -3))])
    static func float(_ duration: Double) -> CSSAnimation {
        CSSAnimation(duration: duration, easing: .easeInOut, frames: [(0.5, Pose(ty: -3, rot: 2))])
    }
    static let comet = CSSAnimation(duration: 1.5, easing: .easeInOut, frames: [(0.5, Pose(tx: 2, ty: -2, rot: 7))])
    static let orbit = CSSAnimation(duration: 2, easing: .linear, frames: [(1, Pose(rot: 360))])
    static let boost = CSSAnimation(duration: 0.7, easing: .easeInOut, frames: [(0.5, Pose(ty: -3))])
    static let flame = CSSAnimation(duration: 0.22, easing: .easeInOut, alternate: true, frames: [(1, Pose(sy: 1.13))])
    static let shadow = CSSAnimation(duration: 4, easing: .easeInOut, base: Pose(opacity: 0.25), frames: [(0.5, Pose(sx: 0.8, opacity: 0.3))])
    static let twinkle = CSSAnimation(duration: 1.3, easing: .steps2, frames: [(0.5, Pose(opacity: 0.25))])
}

// MARK: - Drawing

private enum CharacterDrawing {
    static let pivot = CGPoint(x: 32, y: 34)

    /// `pose` as CSS `transform: translate() rotate() scale()` about 32,34.
    static func apply(_ pose: Pose, to c: inout GraphicsContext) {
        c.translateBy(x: pose.tx, y: pose.ty)
        c.translateBy(x: pivot.x, y: pivot.y)
        c.rotate(by: .degrees(pose.rot))
        c.scaleBy(x: pose.sx, y: pose.sy)
        c.translateBy(x: -pivot.x, y: -pivot.y)
    }

    /// Draws `body` with the pose's transform and opacity on a copy of the context.
    static func group(_ pose: Pose, _ c: inout GraphicsContext, _ body: (inout GraphicsContext) -> Void) {
        var g = c
        apply(pose, to: &g)
        g.opacity = c.opacity * pose.opacity
        body(&g)
    }

    static func rect(_ c: inout GraphicsContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ color: Color) {
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(color))
    }

    static func ellipse(_ c: inout GraphicsContext, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ color: Color) {
        c.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(color))
    }

    static func stroke(_ c: inout GraphicsContext, _ path: Path, _ color: Color, _ width: Double, round: Bool) {
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt))
    }

    static func draw(_ kind: HarnessCharacterView.Kind, working: Bool, t: Double, in c: inout GraphicsContext) {
        let color = HarnessCharacterView.color(for: kind)
        let blink = Motion.blink.pose(at: t)
        let shadow = Motion.shadow.pose(at: t)
        func shadowEllipse(cy: Double, rx: Double, ry: Double) {
            group(shadow, &c) { ellipse(&$0, 32, cy, rx, ry, .black) }
        }
        switch kind {
        case .robot:
            shadowEllipse(cy: 58, rx: 17, ry: 3)
            let legA = working ? Motion.leg.pose(at: t) : Pose()
            let legB = working ? Motion.legB.pose(at: t) : Pose()
            for (x, y, w, h, pose) in [(15.0, 43.0, 6.0, 11.0, legA), (25, 43, 5, 12, legB), (35, 43, 5, 12, legA), (44, 43, 6, 11, legB)] {
                group(pose, &c) { rect(&$0, x, y, w, h, 2, color) }
            }
            let body = working ? Motion.tap.pose(at: t) : Motion.breathe.pose(at: t)
            group(body, &c) { b in
                rect(&b, 7, 28, 7, 12, 3, color)
                rect(&b, 50, 28, 7, 12, 3, color)
                rect(&b, 12, 20, 40, 27, 6, color)
                var stem = Path(); stem.move(to: CGPoint(x: 32, y: 20)); stem.addLine(to: CGPoint(x: 32, y: 14))
                stroke(&b, stem, color, 3, round: false)
                if working {
                    group(Motion.twinkle.pose(at: t), &b) { ellipse(&$0, 32, 12, 3, 3, Color(hex: 0xFFD6A0)) }
                }
                group(blink, &b) { e in
                    rect(&e, 22, 29, 4, 6, 1.5, Color(hex: 0x30202B))
                    rect(&e, 39, 29, 4, 6, 1.5, Color(hex: 0x30202B))
                }
                var mouth = Path(); mouth.move(to: CGPoint(x: 29, y: 39))
                mouth.addQuadCurve(to: CGPoint(x: 37, y: 38), control: CGPoint(x: 33, y: 42))
                stroke(&b, mouth, Color(hex: 0x70443D), 1.5, round: true)
            }
        case .comet:
            shadowEllipse(cy: 58, rx: 15, ry: 2.5)
            if working {
                var trail = Path()
                for (a, b) in [((8.0, 43.0), (3.0, 50.0)), ((13, 48), (9, 54)), ((7, 35), (2, 39))] {
                    trail.move(to: CGPoint(x: a.0, y: a.1)); trail.addLine(to: CGPoint(x: b.0, y: b.1))
                }
                var g = c; g.opacity = 0.4
                stroke(&g, trail, color, 3, round: true)
            }
            let body = working ? Motion.comet.pose(at: t) : Motion.float(5).pose(at: t)
            group(body, &c) { b in
                var star = Path()
                star.move(to: CGPoint(x: 32, y: 10))
                for (cx, cy, x, y) in [(35.0, 24.0, 48.0, 18.0), (42, 29, 55, 34), (42, 35, 45, 49), (34, 42, 26, 54),
                                       (24, 40, 11, 43), (20, 32, 10, 24), (24, 25, 32, 10)] {
                    star.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
                }
                star.closeSubpath()
                b.fill(star, with: .color(color))
                group(blink, &b) { e in
                    ellipse(&e, 28, 31, 2, 3, Color(hex: 0x30213F))
                    ellipse(&e, 39, 31, 2, 3, Color(hex: 0x30213F))
                }
                var mouth = Path(); mouth.move(to: CGPoint(x: 31, y: 37))
                mouth.addQuadCurve(to: CGPoint(x: 37, y: 36), control: CGPoint(x: 34, y: 40))
                stroke(&b, mouth, Color(hex: 0x65467F), 1.5, round: true)
            }
            if working {
                group(Motion.orbit.pose(at: t), &c) { o in
                    let light = Color(hex: 0xDEC9FF)
                    ellipse(&o, 55, 15, 2, 2, light)
                    var plus = Path()
                    plus.move(to: CGPoint(x: 11, y: 9)); plus.addLine(to: CGPoint(x: 11, y: 15))
                    plus.move(to: CGPoint(x: 8, y: 12)); plus.addLine(to: CGPoint(x: 14, y: 12))
                    stroke(&o, plus, light, 1.5, round: false)
                }
            }
        case .jet:
            shadowEllipse(cy: 59, rx: 15, ry: 2.5)
            let body = working ? Motion.boost.pose(at: t) : Motion.float(4).pose(at: t)
            group(body, &c) { b in
                if working {
                    group(Motion.flame.pose(at: t), &b) { x in
                        var flame = Path()
                        flame.move(to: CGPoint(x: 23, y: 45)); flame.addQuadCurve(to: CGPoint(x: 26, y: 59), control: CGPoint(x: 20, y: 56))
                        flame.addQuadCurve(to: CGPoint(x: 28, y: 45), control: CGPoint(x: 31, y: 52))
                        flame.move(to: CGPoint(x: 36, y: 45)); flame.addQuadCurve(to: CGPoint(x: 39, y: 59), control: CGPoint(x: 33, y: 56))
                        flame.addQuadCurve(to: CGPoint(x: 41, y: 45), control: CGPoint(x: 44, y: 52))
                        x.fill(flame, with: .color(Color(hex: 0x94D5F4)))
                        var core = Path()
                        for (a, m, z) in [(25.0, 26.0, 28.0), (37, 39, 41)] {
                            core.move(to: CGPoint(x: a, y: 45)); core.addLine(to: CGPoint(x: m, y: 54))
                            core.addLine(to: CGPoint(x: z, y: 45)); core.closeSubpath()
                        }
                        x.fill(core, with: .color(Color(hex: 0xFFCB9F)))
                    }
                }
                rect(&b, 11, 26, 8, 21, 4, Color(hex: 0x4B85AD))
                rect(&b, 45, 26, 8, 21, 4, Color(hex: 0x4B85AD))
                rect(&b, 18, 14, 28, 34, 14, color)
                rect(&b, 21, 25, 22, 13, 6, Color(hex: 0x21485E))
                group(blink, &b) { e in
                    ellipse(&e, 28, 31, 1.8, 2.4, Color(hex: 0xBDEAFF))
                    ellipse(&e, 37, 31, 1.8, 2.4, Color(hex: 0xBDEAFF))
                }
                rect(&b, 22, 44, 7, 7, 3, color)
                rect(&b, 35, 44, 7, 7, 3, color)
                ellipse(&b, 32, 42, 1.3, 1.3, Color(hex: 0xD0EFFF))
            }
        }
    }
}
