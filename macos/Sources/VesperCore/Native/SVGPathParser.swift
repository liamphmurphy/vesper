import CoreGraphics
import Foundation
import os

/// Pure SVG path `d` parser (`M/m`, `L/l`, `H/h`, `V/v`, `C/c`, `S/s`, `Q/q`, `T/t`, `A/a`, `Z/z`)
/// and exact arc-length trimmer for `pathLength=1` `stroke-dashoffset` animations.
public enum SVGPathParser {
    private struct SendablePathBox: @unchecked Sendable {
        let path: CGPath
    }

    private static let cache = OSAllocatedUnfairLock<[String: SendablePathBox]>(initialState: [:])

    /// Parses an SVG `d` string into an immutable `CGPath`, caching by source string.
    public static func parse(_ d: String) -> CGPath {
        if let hit = cache.withLock({ $0[d] }) { return hit.path }
        let raw = parseUncached(d)
        let box = SendablePathBox(path: raw.copy() ?? raw)
        cache.withLock { $0[d] = box }
        return box.path
    }

    /// Parses an SVG `d` string without touching the shared cache.
    public static func parseUncached(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicCP: CGPoint?
        var lastQuadCP: CGPoint?
        var prevCommand: Character?
        var command: Character?

        while true {
            scanner.skipSeparators()
            if let cmd = scanner.peekCommand() {
                scanner.advance()
                command = cmd
            } else if let currentCmd = command, scanner.hasNumberStart() {
                // Repeated implicit coordinates; `M`/`m` turn into `L`/`l`.
                if currentCmd == "M" { command = "L" }
                else if currentCmd == "m" { command = "l" }
            } else {
                break
            }

            guard let active = command else { break }

            switch active {
            case "M", "m":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let pt = active == "m" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: pt)
                current = pt
                subpathStart = pt
                lastCubicCP = nil
                lastQuadCP = nil
                prevCommand = active

            case "L", "l":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let pt = active == "l" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: pt)
                current = pt
                lastCubicCP = nil
                lastQuadCP = nil
                prevCommand = active

            case "H", "h":
                guard let x = scanner.readNumber() else {
                    command = nil
                    break
                }
                let pt = CGPoint(x: active == "h" ? current.x + x : x, y: current.y)
                path.addLine(to: pt)
                current = pt
                lastCubicCP = nil
                lastQuadCP = nil
                prevCommand = active

            case "V", "v":
                guard let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let pt = CGPoint(x: current.x, y: active == "v" ? current.y + y : y)
                path.addLine(to: pt)
                current = pt
                lastCubicCP = nil
                lastQuadCP = nil
                prevCommand = active

            case "C", "c":
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let rel = active == "c"
                let cp1 = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let cp2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: cp1, control2: cp2)
                current = end
                lastCubicCP = cp2
                lastQuadCP = nil
                prevCommand = active

            case "S", "s":
                guard let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let cp1: CGPoint = if let prev = prevCommand, "CcSs".contains(prev), let last = lastCubicCP {
                    CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    current
                }
                let rel = active == "s"
                let cp2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: cp1, control2: cp2)
                current = end
                lastCubicCP = cp2
                lastQuadCP = nil
                prevCommand = active

            case "Q", "q":
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let rel = active == "q"
                let cp = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: cp)
                current = end
                lastQuadCP = cp
                lastCubicCP = nil
                prevCommand = active

            case "T", "t":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let cp: CGPoint = if let prev = prevCommand, "QqTt".contains(prev), let last = lastQuadCP {
                    CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    current
                }
                let end = active == "t" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: cp)
                current = end
                lastQuadCP = cp
                lastCubicCP = nil
                prevCommand = active

            case "A", "a":
                guard let rx = scanner.readNumber(), let ry = scanner.readNumber(),
                      let rot = scanner.readNumber(),
                      let largeArc = scanner.readFlag(), let sweep = scanner.readFlag(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else {
                    command = nil
                    break
                }
                let end = active == "a" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                appendArc(
                    to: path,
                    from: current,
                    to: end,
                    rx: rx,
                    ry: ry,
                    xAxisRotation: rot,
                    largeArc: largeArc,
                    sweep: sweep
                )
                current = end
                lastCubicCP = nil
                lastQuadCP = nil
                prevCommand = active

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicCP = nil
                lastQuadCP = nil
                prevCommand = active
                command = nil

            default:
                command = nil
            }
        }
        return path
    }

    /// Total arc length across all subpaths in `path`.
    public static func totalLength(_ path: CGPath) -> CGFloat {
        flattenSegments(path).reduce(0) { $0 + $1.length }
    }

    /// Trims `path` by normalized `[start, end]` (`0...1`) over its combined length.
    public static func trimmedPath(_ path: CGPath, from start: CGFloat, to end: CGFloat) -> CGPath {
        let s = max(0, min(1, start))
        let e = max(0, min(1, end))
        if e <= s { return CGMutablePath() }
        if s <= 0 && e >= 1 { return path }

        let segments = flattenSegments(path)
        let total = segments.reduce(CGFloat(0)) { $0 + $1.length }
        guard total > 1e-6 else { return CGMutablePath() }

        let startDist = s * total
        let endDist = e * total
        let out = CGMutablePath()
        var acc: CGFloat = 0
        var cursor: CGPoint?

        for seg in segments {
            let nextAcc = acc + seg.length
            defer { acc = nextAcc }
            if seg.length <= 1e-7 || nextAcc <= startDist || acc >= endDist {
                continue
            }
            let localStart = max(0, startDist - acc)
            let localEnd = min(seg.length, endDist - acc)
            let u0 = seg.parameter(forDistance: localStart)
            let u1 = seg.parameter(forDistance: localEnd)
            guard u1 > u0 else { continue }
            seg.appendSlice(from: u0, to: u1, into: out, cursor: &cursor)
        }
        return out
    }

    // MARK: - Elliptical Arc Conversion (W3C SVG 1.1 F.6.5 / F.6.6)

    private static func appendArc(
        to path: CGMutablePath,
        from p0: CGPoint,
        to p1: CGPoint,
        rx rawRx: CGFloat,
        ry rawRy: CGFloat,
        xAxisRotation: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if abs(p0.x - p1.x) < 1e-9 && abs(p0.y - p1.y) < 1e-9 { return }
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        if rx < 1e-9 || ry < 1e-9 {
            path.addLine(to: p1)
            return
        }

        let phi = Double(xAxisRotation) * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = Double(p0.x - p1.x) * 0.5
        let dy2 = Double(p0.y - p1.y) * 0.5
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        var rxd = Double(rx)
        var ryd = Double(ry)
        let lambda = (x1p * x1p) / (rxd * rxd) + (y1p * y1p) / (ryd * ryd)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rxd *= scale
            ryd *= scale
            rx = CGFloat(rxd)
            ry = CGFloat(ryd)
        }

        let rx2 = rxd * rxd
        let ry2 = ryd * ryd
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p
        let num = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let den = rx2 * y1p2 + ry2 * x1p2
        let factor = (den > 0 ? sqrt(num / den) : 0) * (largeArc == sweep ? -1.0 : 1.0)
        let cxp = factor * (rxd * y1p / ryd)
        let cyp = factor * (-ryd * x1p / rxd)

        let cx = cosPhi * cxp - sinPhi * cyp + Double(p0.x + p1.x) * 0.5
        let cy = sinPhi * cxp + cosPhi * cyp + Double(p0.y + p1.y) * 0.5

        func vectorAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let cosVal = len > 0 ? min(1, max(-1, dot / len)) : 1
            let sign = (ux * vy - uy * vx) < 0 ? -1.0 : 1.0
            return sign * acos(cosVal)
        }

        let ux = (x1p - cxp) / rxd
        let uy = (y1p - cyp) / ryd
        let vx = (-x1p - cxp) / rxd
        let vy = (-y1p - cyp) / ryd

        let theta1 = vectorAngle(1, 0, ux, uy)
        var dTheta = vectorAngle(ux, uy, vx, vy)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi * 0.5))))
        let delta = dTheta / Double(segments)
        let alpha = (4.0 / 3.0) * tan(delta * 0.25)

        func mapPoint(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: cx + cosPhi * rxd * x - sinPhi * ryd * y,
                y: cy + sinPhi * rxd * x + cosPhi * ryd * y
            )
        }

        for i in 0..<segments {
            let t1 = theta1 + Double(i) * delta
            let t2 = t1 + delta
            let x1 = cos(t1), y1 = sin(t1)
            let x2 = cos(t2), y2 = sin(t2)
            let cp1 = mapPoint(x1 - alpha * y1, y1 + alpha * x1)
            let cp2 = mapPoint(x2 + alpha * y2, y2 - alpha * x2)
            let end = i == segments - 1 ? p1 : mapPoint(x2, y2)
            path.addCurve(to: end, control1: cp1, control2: cp2)
        }
    }

    // MARK: - Path Flattening & Trimming

    private enum Segment {
        case line(CGPoint, CGPoint, CGFloat)
        case quad(CGPoint, CGPoint, CGPoint, [CGFloat])
        case cubic(CGPoint, CGPoint, CGPoint, CGPoint, [CGFloat])

        var length: CGFloat {
            switch self {
            case .line(_, _, let len): len
            case .quad(_, _, _, let lut): lut.last ?? 0
            case .cubic(_, _, _, _, let lut): lut.last ?? 0
            }
        }

        func parameter(forDistance target: CGFloat) -> CGFloat {
            switch self {
            case .line(_, _, let len):
                return len > 0 ? min(max(target / len, 0), 1) : 1
            case .quad(_, _, _, let lut), .cubic(_, _, _, _, let lut):
                guard let total = lut.last, total > 0 else { return 1 }
                if target <= 0 { return 0 }
                if target >= total { return 1 }
                let steps = lut.count - 1
                for i in 1...steps {
                    if target <= lut[i] {
                        let d0 = lut[i - 1]
                        let d1 = lut[i]
                        let span = d1 - d0
                        let frac = span > 0 ? (target - d0) / span : 0
                        return (CGFloat(i - 1) + frac) / CGFloat(steps)
                    }
                }
                return 1
            }
        }

        func appendSlice(from u0: CGFloat, to u1: CGFloat, into out: CGMutablePath, cursor: inout CGPoint?) {
            func ensureStart(_ pt: CGPoint) {
                if let c = cursor, hypot(c.x - pt.x, c.y - pt.y) < 1e-3 { return }
                out.move(to: pt)
            }
            switch self {
            case .line(let a, let b, _):
                let p0 = lerp(a, b, u0)
                let p1 = lerp(a, b, u1)
                ensureStart(p0)
                out.addLine(to: p1)
                cursor = p1

            case .quad(let p0, let p1, let p2, _):
                let left = splitQuad(p0, p1, p2, at: u1).left
                let frac = u1 > 0 ? u0 / u1 : 0
                let seg = frac > 0 ? splitQuad(left.0, left.1, left.2, at: frac).right : left
                ensureStart(seg.0)
                out.addQuadCurve(to: seg.2, control: seg.1)
                cursor = seg.2

            case .cubic(let p0, let p1, let p2, let p3, _):
                let left = splitCubic(p0, p1, p2, p3, at: u1).left
                let frac = u1 > 0 ? u0 / u1 : 0
                let seg = frac > 0 ? splitCubic(left.0, left.1, left.2, left.3, at: frac).right : left
                ensureStart(seg.0)
                out.addCurve(to: seg.3, control1: seg.1, control2: seg.2)
                cursor = seg.3
            }
        }
    }

    private static func flattenSegments(_ path: CGPath) -> [Segment] {
        var segments: [Segment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { elementPtr in
            let el = elementPtr.pointee
            switch el.type {
            case .moveToPoint:
                let pt = el.points[0]
                current = pt
                subpathStart = pt
            case .addLineToPoint:
                let pt = el.points[0]
                let len = hypot(pt.x - current.x, pt.y - current.y)
                segments.append(.line(current, pt, len))
                current = pt
            case .addQuadCurveToPoint:
                let cp = el.points[0]
                let end = el.points[1]
                let lut = quadLUT(current, cp, end)
                segments.append(.quad(current, cp, end, lut))
                current = end
            case .addCurveToPoint:
                let cp1 = el.points[0]
                let cp2 = el.points[1]
                let end = el.points[2]
                let lut = cubicLUT(current, cp1, cp2, end)
                segments.append(.cubic(current, cp1, cp2, end, lut))
                current = end
            case .closeSubpath:
                let len = hypot(subpathStart.x - current.x, subpathStart.y - current.y)
                if len > 1e-6 {
                    segments.append(.line(current, subpathStart, len))
                }
                current = subpathStart
            @unknown default:
                break
            }
        }
        return segments
    }

    private static let lutSamples = 32

    private static func quadLUT(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) -> [CGFloat] {
        var lut = [CGFloat](repeating: 0, count: lutSamples + 1)
        var prev = p0
        var acc: CGFloat = 0
        for i in 1...lutSamples {
            let t = CGFloat(i) / CGFloat(lutSamples)
            let inv = 1 - t
            let pt = CGPoint(
                x: inv * inv * p0.x + 2 * inv * t * p1.x + t * t * p2.x,
                y: inv * inv * p0.y + 2 * inv * t * p1.y + t * t * p2.y
            )
            acc += hypot(pt.x - prev.x, pt.y - prev.y)
            lut[i] = acc
            prev = pt
        }
        return lut
    }

    private static func cubicLUT(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> [CGFloat] {
        var lut = [CGFloat](repeating: 0, count: lutSamples + 1)
        var prev = p0
        var acc: CGFloat = 0
        for i in 1...lutSamples {
            let t = CGFloat(i) / CGFloat(lutSamples)
            let inv = 1 - t
            let inv2 = inv * inv
            let t2 = t * t
            let pt = CGPoint(
                x: inv2 * inv * p0.x + 3 * inv2 * t * p1.x + 3 * inv * t2 * p2.x + t2 * t * p3.x,
                y: inv2 * inv * p0.y + 3 * inv2 * t * p1.y + 3 * inv * t2 * p2.y + t2 * t * p3.y
            )
            acc += hypot(pt.x - prev.x, pt.y - prev.y)
            lut[i] = acc
            prev = pt
        }
        return lut
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func splitQuad(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, at t: CGFloat
    ) -> (left: (CGPoint, CGPoint, CGPoint), right: (CGPoint, CGPoint, CGPoint)) {
        let p01 = lerp(p0, p1, t)
        let p12 = lerp(p1, p2, t)
        let p012 = lerp(p01, p12, t)
        return ((p0, p01, p012), (p012, p12, p2))
    }

    private static func splitCubic(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, at t: CGFloat
    ) -> (left: (CGPoint, CGPoint, CGPoint, CGPoint), right: (CGPoint, CGPoint, CGPoint, CGPoint)) {
        let p01 = lerp(p0, p1, t)
        let p12 = lerp(p1, p2, t)
        let p23 = lerp(p2, p3, t)
        let p012 = lerp(p01, p12, t)
        let p123 = lerp(p12, p23, t)
        let p0123 = lerp(p012, p123, t)
        return ((p0, p01, p012, p0123), (p0123, p123, p23, p3))
    }

    // MARK: - Compact SVG `d` Token Scanner

    private struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ string: String) {
            self.bytes = Array(string.utf8)
        }

        mutating func skipSeparators() {
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x2C /* , */ || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    index += 1
                } else {
                    break
                }
            }
        }

        func peekCommand() -> Character? {
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) {
                let ch = Character(UnicodeScalar(b))
                return "MmLlHhVvCcSsQqTtAaZz".contains(ch) ? ch : nil
            }
            return nil
        }

        mutating func advance() {
            index += 1
        }

        func hasNumberStart() -> Bool {
            guard index < bytes.count else { return false }
            let b = bytes[index]
            return (b >= 0x30 && b <= 0x39) || b == 0x2B /* + */ || b == 0x2D /* - */ || b == 0x2E /* . */
        }

        mutating func readFlag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            if b == 0x30 /* 0 */ {
                index += 1
                return false
            }
            if b == 0x31 /* 1 */ {
                index += 1
                return true
            }
            return nil
        }

        mutating func readNumber() -> CGFloat? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let start = index
            if bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            var sawDigit = false
            while index < bytes.count, bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                sawDigit = true
                index += 1
            }
            if index < bytes.count, bytes[index] == 0x2E /* . */ {
                index += 1
                while index < bytes.count, bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    sawDigit = true
                    index += 1
                }
            }
            guard sawDigit else {
                index = start
                return nil
            }
            if index < bytes.count, bytes[index] == 0x65 /* e */ || bytes[index] == 0x45 /* E */ {
                let expStart = index
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                    index += 1
                }
                var expDigits = false
                while index < bytes.count, bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    expDigits = true
                    index += 1
                }
                if !expDigits { index = expStart }
            }
            guard let str = String(bytes: bytes[start..<index], encoding: .utf8),
                  let val = Double(str) else {
                index = start
                return nil
            }
            return CGFloat(val)
        }
    }
}
