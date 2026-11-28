import CoreGraphics
import QuartzCore
import SwiftUI
import VesperCore

/// Animated harness characters drawn on a 64x64 grid for the chat composer's status strip and
/// usage button via `CADisplayLink` at native ProMotion refresh rates (120Hz active, 30Hz Low Power).
/// Reduce Motion, occluded/hidden hosts, backgrounded app (when idle), and Low Power Mode (when
/// idle) freeze the pose at t = 0 with no display link running.
struct HarnessCharacterView: View {
    enum Kind: Hashable { case robot, comet, jet }

    let kind: Kind
    let working: Bool
    var size: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowVisible) private var windowVisible

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
        let power = AppPowerState.shared
        let context = power.animationContext(
            reduceMotion: reduceMotion,
            windowVisible: windowVisible
        )
        let animate = AnimationPolicy.shouldAnimate(working: working, context: context)
        let frameRate = AnimationPolicy.displayLinkFrameRate(working: working, lowPowerMode: power.isLowPowerMode)
        let redrawToken: Int = {
            var hasher = Hasher()
            hasher.combine(kind)
            hasher.combine(working)
            return hasher.finalize()
        }()
        let characterKind = kind
        let isWorking = working

        DisplayLinkCanvasView(
            isAnimating: animate,
            frameRateProfile: frameRate,
            redrawToken: redrawToken
        ) { cg, canvasSize, timestamp in
            let scale = min(canvasSize.width, canvasSize.height) / 64
            let dx = (canvasSize.width - 64 * scale) * 0.5
            let dy = (canvasSize.height - 64 * scale) * 0.5
            cg.saveGState()
            cg.translateBy(x: dx, y: dy)
            cg.scaleBy(x: scale, y: scale)
            CharacterDrawing.draw(characterKind, working: isWorking, t: animate ? timestamp : 0, in: cg)
            cg.restoreGState()
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
    let duration: Double
    let delay: Double
    let easing: Easing
    let alternate: Bool
    let base: Pose
    let resolvedFrames: [(Double, Pose)]

    init(
        duration: Double,
        delay: Double = 0.0,
        easing: Easing = .ease,
        alternate: Bool = false,
        base: Pose = Pose(),
        frames: [(Double, Pose)]
    ) {
        self.duration = duration
        self.delay = delay
        self.easing = easing
        self.alternate = alternate
        self.base = base
        var all = frames
        if all.first?.0 != 0 { all.insert((0, base), at: 0) }
        if all.last?.0 != 1 { all.append((1, base)) }
        self.resolvedFrames = all
    }

    func pose(at t: Double) -> Pose {
        var p = ((t - delay) / duration).truncatingRemainder(dividingBy: alternate ? 2 : 1)
        if p < 0 { p += alternate ? 2 : 1 }
        if alternate, p >= 1 { p = 2 - p }
        for i in 1..<resolvedFrames.count where p <= resolvedFrames[i].0 || i == resolvedFrames.count - 1 {
            let (a, b) = (resolvedFrames[i - 1], resolvedFrames[i])
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

// MARK: - CoreGraphics Drawing (Y-down 64x64 viewBox)

private enum CharacterDrawing {
    static let pivot = CGPoint(x: 32, y: 34)

    private static let colorBlack = cgColor(0x000000)
    private static let colorRobot = cgColor(0xF2A97E)
    private static let colorRobotSpark = cgColor(0xFFD6A0)
    private static let colorRobotEye = cgColor(0x30202B)
    private static let colorRobotMouth = cgColor(0x70443D)
    private static let colorComet = cgColor(0xB09AEF)
    private static let colorCometEye = cgColor(0x30213F)
    private static let colorCometMouth = cgColor(0x65467F)
    private static let colorCometLight = cgColor(0xDEC9FF)
    private static let colorJet = cgColor(0x78BFDE)
    private static let colorJetFlame = cgColor(0x94D5F4)
    private static let colorJetCore = cgColor(0xFFCB9F)
    private static let colorJetWing = cgColor(0x4B85AD)
    private static let colorJetVisor = cgColor(0x21485E)
    private static let colorJetEye = cgColor(0xBDEAFF)
    private static let colorJetDot = cgColor(0xD0EFFF)

    private static func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func bodyColor(for kind: HarnessCharacterView.Kind) -> CGColor {
        switch kind {
        case .robot: colorRobot
        case .comet: colorComet
        case .jet: colorJet
        }
    }

    /// Draws `body` with the pose's transform and multiplied alpha on a saved graphics state.
    private static func group(
        _ pose: Pose,
        alpha: CGFloat,
        in ctx: CGContext,
        _ body: (CGContext, CGFloat) -> Void
    ) {
        let nextAlpha = alpha * CGFloat(pose.opacity)
        ctx.saveGState()
        ctx.translateBy(x: pose.tx, y: pose.ty)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: pose.rot * .pi / 180)
        ctx.scaleBy(x: pose.sx, y: pose.sy)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        ctx.setAlpha(nextAlpha)
        body(ctx, nextAlpha)
        ctx.restoreGState()
    }

    private static func rect(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: CGColor) {
        let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private static func ellipse(_ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat, round: Bool) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(round ? .round : .butt)
        ctx.addPath(path)
        ctx.strokePath()
    }

    static func draw(_ kind: HarnessCharacterView.Kind, working: Bool, t: Double, in ctx: CGContext) {
        let color = bodyColor(for: kind)
        let blink = Motion.blink.pose(at: t)
        let shadow = Motion.shadow.pose(at: t)
        func shadowEllipse(cy: CGFloat, rx: CGFloat, ry: CGFloat) {
            group(shadow, alpha: 1, in: ctx) { c, _ in ellipse(c, 32, cy, rx, ry, colorBlack) }
        }
        switch kind {
        case .robot:
            shadowEllipse(cy: 58, rx: 17, ry: 3)
            let legA = working ? Motion.leg.pose(at: t) : Pose()
            let legB = working ? Motion.legB.pose(at: t) : Pose()
            for (x, y, w, h, pose) in [(CGFloat(15), CGFloat(43), CGFloat(6), CGFloat(11), legA),
                                       (25, 43, 5, 12, legB),
                                       (35, 43, 5, 12, legA),
                                       (44, 43, 6, 11, legB)] {
                group(pose, alpha: 1, in: ctx) { c, _ in rect(c, x, y, w, h, 2, color) }
            }
            let body = working ? Motion.tap.pose(at: t) : Motion.breathe.pose(at: t)
            group(body, alpha: 1, in: ctx) { b, alpha in
                rect(b, 7, 28, 7, 12, 3, color)
                rect(b, 50, 28, 7, 12, 3, color)
                rect(b, 12, 20, 40, 27, 6, color)
                let stem = CGMutablePath()
                stem.move(to: CGPoint(x: 32, y: 20))
                stem.addLine(to: CGPoint(x: 32, y: 14))
                stroke(b, stem, color, 3, round: false)
                if working {
                    group(Motion.twinkle.pose(at: t), alpha: alpha, in: b) { c, _ in
                        ellipse(c, 32, 12, 3, 3, colorRobotSpark)
                    }
                }
                group(blink, alpha: alpha, in: b) { e, _ in
                    rect(e, 22, 29, 4, 6, 1.5, colorRobotEye)
                    rect(e, 39, 29, 4, 6, 1.5, colorRobotEye)
                }
                let mouth = CGMutablePath()
                mouth.move(to: CGPoint(x: 29, y: 39))
                mouth.addQuadCurve(to: CGPoint(x: 37, y: 38), control: CGPoint(x: 33, y: 42))
                stroke(b, mouth, colorRobotMouth, 1.5, round: true)
            }

        case .comet:
            shadowEllipse(cy: 58, rx: 15, ry: 2.5)
            if working {
                let trail = CGMutablePath()
                for (a, b) in [((CGFloat(8), CGFloat(43)), (CGFloat(3), CGFloat(50))),
                               ((13, 48), (9, 54)),
                               ((7, 35), (2, 39))] {
                    trail.move(to: CGPoint(x: a.0, y: a.1))
                    trail.addLine(to: CGPoint(x: b.0, y: b.1))
                }
                ctx.saveGState()
                ctx.setAlpha(0.4)
                stroke(ctx, trail, color, 3, round: true)
                ctx.restoreGState()
            }
            let body = working ? Motion.comet.pose(at: t) : Motion.float(5).pose(at: t)
            group(body, alpha: 1, in: ctx) { b, alpha in
                let star = CGMutablePath()
                star.move(to: CGPoint(x: 32, y: 10))
                for (cx, cy, x, y) in [(CGFloat(35), CGFloat(24), CGFloat(48), CGFloat(18)),
                                       (42, 29, 55, 34),
                                       (42, 35, 45, 49),
                                       (34, 42, 26, 54),
                                       (24, 40, 11, 43),
                                       (20, 32, 10, 24),
                                       (24, 25, 32, 10)] {
                    star.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
                }
                star.closeSubpath()
                b.setFillColor(color)
                b.addPath(star)
                b.fillPath()
                group(blink, alpha: alpha, in: b) { e, _ in
                    ellipse(e, 28, 31, 2, 3, colorCometEye)
                    ellipse(e, 39, 31, 2, 3, colorCometEye)
                }
                let mouth = CGMutablePath()
                mouth.move(to: CGPoint(x: 31, y: 37))
                mouth.addQuadCurve(to: CGPoint(x: 37, y: 36), control: CGPoint(x: 34, y: 40))
                stroke(b, mouth, colorCometMouth, 1.5, round: true)
            }
            if working {
                group(Motion.orbit.pose(at: t), alpha: 1, in: ctx) { o, _ in
                    ellipse(o, 55, 15, 2, 2, colorCometLight)
                    let plus = CGMutablePath()
                    plus.move(to: CGPoint(x: 11, y: 9))
                    plus.addLine(to: CGPoint(x: 11, y: 15))
                    plus.move(to: CGPoint(x: 8, y: 12))
                    plus.addLine(to: CGPoint(x: 14, y: 12))
                    stroke(o, plus, colorCometLight, 1.5, round: false)
                }
            }

        case .jet:
            shadowEllipse(cy: 59, rx: 15, ry: 2.5)
            let body = working ? Motion.boost.pose(at: t) : Motion.float(4).pose(at: t)
            group(body, alpha: 1, in: ctx) { b, alpha in
                if working {
                    group(Motion.flame.pose(at: t), alpha: alpha, in: b) { x, _ in
                        let flame = CGMutablePath()
                        flame.move(to: CGPoint(x: 23, y: 45))
                        flame.addQuadCurve(to: CGPoint(x: 26, y: 59), control: CGPoint(x: 20, y: 56))
                        flame.addQuadCurve(to: CGPoint(x: 28, y: 45), control: CGPoint(x: 31, y: 52))
                        flame.move(to: CGPoint(x: 36, y: 45))
                        flame.addQuadCurve(to: CGPoint(x: 39, y: 59), control: CGPoint(x: 33, y: 56))
                        flame.addQuadCurve(to: CGPoint(x: 41, y: 45), control: CGPoint(x: 44, y: 52))
                        x.setFillColor(colorJetFlame)
                        x.addPath(flame)
                        x.fillPath()
                        let core = CGMutablePath()
                        for (a, m, z) in [(CGFloat(25), CGFloat(26), CGFloat(28)), (37, 39, 41)] {
                            core.move(to: CGPoint(x: a, y: 45))
                            core.addLine(to: CGPoint(x: m, y: 54))
                            core.addLine(to: CGPoint(x: z, y: 45))
                            core.closeSubpath()
                        }
                        x.setFillColor(colorJetCore)
                        x.addPath(core)
                        x.fillPath()
                    }
                }
                rect(b, 11, 26, 8, 21, 4, colorJetWing)
                rect(b, 45, 26, 8, 21, 4, colorJetWing)
                rect(b, 18, 14, 28, 34, 14, color)
                rect(b, 21, 25, 22, 13, 6, colorJetVisor)
                group(blink, alpha: alpha, in: b) { e, _ in
                    ellipse(e, 28, 31, 1.8, 2.4, colorJetEye)
                    ellipse(e, 37, 31, 1.8, 2.4, colorJetEye)
                }
                rect(b, 22, 44, 7, 7, 3, color)
                rect(b, 35, 44, 7, 7, 3, color)
                ellipse(b, 32, 42, 1.3, 1.3, colorJetDot)
            }
        }
    }
}
