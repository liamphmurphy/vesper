import CoreGraphics
import CoreText
import Foundation

// MARK: - Orthogonal Connector Router (exact port of web/lib/designs/route.ts)

public struct DesignBox: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct DesignPt: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public enum DesignConnectorRouter: Sendable {
    public static let stubLen: Double = 20
    public static let clearance: Double = 14
    public static let bendPenalty: Double = 36
    private static let reachMargin: Double = 240
    private static let maxObstacles = 300

    public static func anchorPoint(_ b: DesignBox, _ anchor: String) -> DesignPt {
        switch anchor {
        case "top": DesignPt(b.x + b.w / 2, b.y)
        case "bottom": DesignPt(b.x + b.w / 2, b.y + b.h)
        case "left": DesignPt(b.x, b.y + b.h / 2)
        default: DesignPt(b.x + b.w, b.y + b.h / 2)
        }
    }

    public static func autoAnchor(from: DesignBox, to: DesignBox) -> String {
        let dx = (to.x + to.w / 2) - (from.x + from.w / 2)
        let dy = (to.y + to.h / 2) - (from.y + from.h / 2)
        return abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "bottom" : "top")
    }

    private static func dir(_ anchor: String) -> (Double, Double) {
        switch anchor {
        case "top": (0, -1)
        case "bottom": (0, 1)
        case "left": (-1, 0)
        default: (1, 0)
        }
    }

    private static func inflate(_ b: DesignBox, by m: Double) -> DesignBox {
        DesignBox(x: b.x - m, y: b.y - m, w: b.w + 2 * m, h: b.h + 2 * m)
    }

    private static func overlaps(_ a: DesignBox, _ b: DesignBox) -> Bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    public static func simplify(_ pts: [DesignPt]) -> [DesignPt] {
        var out: [DesignPt] = []
        for p in pts {
            if let last = out.last, last == p { continue }
            if out.count >= 2 {
                let a = out[out.count - 2]
                let b = out[out.count - 1]
                if (a.x == b.x && b.x == p.x) || (a.y == b.y && b.y == p.y) {
                    out.removeLast()
                }
            }
            out.append(p)
        }
        return out
    }

    public static func simpleRoute(fb: DesignBox, fa: String, tb: DesignBox, ta: String) -> [DesignPt] {
        let p0 = anchorPoint(fb, fa)
        let p3 = anchorPoint(tb, ta)
        let (fdx, fdy) = dir(fa)
        let (tdx, tdy) = dir(ta)
        let p1 = DesignPt(p0.x + fdx * stubLen, p0.y + fdy * stubLen)
        let p2 = DesignPt(p3.x + tdx * stubLen, p3.y + tdy * stubLen)
        var pts = [p0, p1]
        let fh = fdx != 0
        let th = tdx != 0
        if fh && th {
            let xm = (p1.x + p2.x) / 2
            pts.append(DesignPt(xm, p1.y))
            pts.append(DesignPt(xm, p2.y))
        } else if !fh && !th {
            let ym = fdy == tdy ? (fdy > 0 ? max(p1.y, p2.y) : min(p1.y, p2.y)) : (p1.y + p2.y) / 2
            pts.append(DesignPt(p1.x, ym))
            pts.append(DesignPt(p2.x, ym))
        } else if fh {
            pts.append(DesignPt(p2.x, p1.y))
        } else {
            pts.append(DesignPt(p1.x, p2.y))
        }
        pts.append(p2)
        pts.append(p3)
        return simplify(pts)
    }

    public static func routeOrthogonal(fb: DesignBox, fa: String, tb: DesignBox, ta: String, obstacles: [DesignBox] = []) -> [DesignPt] {
        let p0 = anchorPoint(fb, fa)
        let p3 = anchorPoint(tb, ta)
        let fd = dir(fa)
        let td = dir(ta)

        func dist(_ p: DesignPt, _ b: DesignBox) -> Double {
            max(b.x - p.x, p.x - b.x - b.w, b.y - p.y, p.y - b.y - b.h, 0)
        }
        let otherBlocks = obstacles.map { inflate($0, by: min(clearance, dist(p0, $0) / 2, dist(p3, $0) / 2)) }

        func stub(_ p: DesignPt, _ d: (Double, Double), _ blocks: [DesignBox]) -> DesignPt {
            var len = stubLen
            for b in blocks {
                let horiz = d.0 != 0
                let cross = horiz ? p.y : p.x
                let low = horiz ? b.y : b.x
                let sz = horiz ? b.h : b.w
                if cross <= low || cross >= low + sz { continue }
                let along = horiz ? p.x : p.y
                let dv = horiz ? d.0 : d.1
                let near = horiz ? b.x : b.y
                let ext = horiz ? b.w : b.h
                let gap = dv > 0 ? near - along : along - near - ext
                if gap >= 0 { len = min(len, gap / 2) }
            }
            return DesignPt(p.x + d.0 * len, p.y + d.1 * len)
        }

        let p1 = stub(p0, fd, [tb] + otherBlocks)
        let p2 = stub(p3, td, [fb] + otherBlocks)
        let minX = min(fb.x, tb.x), minY = min(fb.y, tb.y)
        let maxX = max(fb.x + fb.w, tb.x + tb.w), maxY = max(fb.y + fb.h, tb.y + tb.h)
        let reach = inflate(DesignBox(x: minX, y: minY, w: maxX - minX, h: maxY - minY), by: reachMargin)
        let blocks = [
            inflate(fb, by: min(clearance, abs(p1.x - p0.x) + abs(p1.y - p0.y))),
            inflate(tb, by: min(clearance, abs(p2.x - p3.x) + abs(p2.y - p3.y))),
        ] + otherBlocks.filter { overlaps($0, reach) }
        if blocks.count > maxObstacles { return simpleRoute(fb: fb, fa: fa, tb: tb, ta: ta) }

        var xsSet: Set<Double> = [p1.x, p2.x, (p1.x + p2.x) / 2, reach.x, reach.x + reach.w]
        var ysSet: Set<Double> = [p1.y, p2.y, (p1.y + p2.y) / 2, reach.y, reach.y + reach.h]
        for b in blocks {
            xsSet.insert(b.x); xsSet.insert(b.x + b.w)
            ysSet.insert(b.y); ysSet.insert(b.y + b.h)
        }
        let xs = xsSet.sorted()
        let ys = ysSet.sorted()
        func withMids(_ v: [Double]) -> [Double] {
            var s = Set(v)
            for i in 1..<v.count { s.insert((v[i] + v[i - 1]) / 2) }
            return s.sorted()
        }
        let X = withMids(xs)
        let Y = withMids(ys)
        let nx = X.count, ny = Y.count
        let xi = Dictionary(uniqueKeysWithValues: X.enumerated().map { ($1, $0) })
        let yi = Dictionary(uniqueKeysWithValues: Y.enumerated().map { ($1, $0) })

        var blockedH = [UInt8](repeating: 0, count: nx * ny)
        var blockedV = [UInt8](repeating: 0, count: nx * ny)
        func lowerBound(_ arr: [Double], _ target: Double) -> Int {
            var lo = 0, hi = arr.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if arr[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        for b in blocks {
            let i0 = lowerBound(X, b.x), i1 = lowerBound(X, b.x + b.w)
            let j0 = lowerBound(Y, b.y), j1 = lowerBound(Y, b.y + b.h)
            for j in j0...min(j1, ny - 1) {
                let inY = Y[j] > b.y && Y[j] < b.y + b.h
                for i in i0...min(i1, nx - 1) {
                    let inX = X[i] > b.x && X[i] < b.x + b.w
                    if inY && i < i1 { blockedH[j * nx + i] = 1 }
                    if inX && j < j1 { blockedV[j * nx + i] = 1 }
                }
            }
        }

        guard let sxi = xi[p1.x], let syi = yi[p1.y], let gxi = xi[p2.x], let gyi = yi[p2.y] else {
            return simpleRoute(fb: fb, fa: fa, tb: tb, ta: ta)
        }
        let s = syi * nx + sxi
        let g = gyi * nx + gxi
        let step: [(Int, Int)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        func heading(_ d: (Double, Double)) -> Int {
            step.firstIndex { Double($0.0) == d.0 && Double($0.1) == d.1 } ?? 0
        }
        let startH = heading(fd)
        let goalH = heading((-td.0, -td.1))
        var cost = [Double](repeating: .infinity, count: nx * ny * 4)
        var prev = [Int](repeating: -1, count: nx * ny * 4)
        func heur(_ n: Int) -> Double { abs(X[n % nx] - p2.x) + abs(Y[n / nx] - p2.y) }

        var heap: [(Double, Int)] = []
        func push(_ p: Double, _ v: Int) {
            heap.append((p, v))
            var i = heap.count - 1
            while i > 0 {
                let j = (i - 1) >> 1
                if heap[j].0 <= heap[i].0 { break }
                heap.swapAt(i, j)
                i = j
            }
        }
        func pop() -> (Double, Int) {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count && heap[l].0 < heap[m].0 { m = l }
                    if r < heap.count && heap[r].0 < heap[m].0 { m = r }
                    if m == i { break }
                    heap.swapAt(i, m)
                    i = m
                }
            }
            return top
        }

        cost[s * 4 + startH] = 0
        push(heur(s), s * 4 + startH)
        var found = -1

        while !heap.isEmpty {
            let (f, st) = pop()
            let n = st >> 2, h = st & 3
            if f - heur(n) > cost[st] + 1e-9 { continue }
            if n == g { found = st; break }
            let i = n % nx, j = n / nx
            for k in 0..<4 {
                if k == ((h + 2) & 3) { continue }
                let (dx, dy) = step[k]
                let ni = i + dx, nj = j + dy
                if ni < 0 || nj < 0 || ni >= nx || nj >= ny { continue }
                if dx != 0 && blockedH[j * nx + min(i, ni)] != 0 { continue }
                if dy != 0 && blockedV[min(j, nj) * nx + i] != 0 { continue }
                let m = nj * nx + ni
                var c = cost[st] + abs(X[ni] - X[i]) + abs(Y[nj] - Y[j]) + (k != h ? bendPenalty : 0)
                if m == g && k != goalH { c += bendPenalty }
                let ns = m * 4 + k
                if c < cost[ns] - 1e-9 {
                    cost[ns] = c
                    prev[ns] = st
                    push(c + heur(m), ns)
                }
            }
        }
        guard found >= 0 else { return simpleRoute(fb: fb, fa: fa, tb: tb, ta: ta) }
        var path: [DesignPt] = []
        var cur = found
        while cur >= 0 {
            let n = cur >> 2
            path.append(DesignPt(X[n % nx], Y[n / nx]))
            cur = prev[cur]
        }
        path.reverse()
        return simplify([p0] + path + [p3])
    }

    public static func clipEnd(_ end: DesignPt, prev: DesignPt, box: DesignBox, outline: String) -> DesignPt {
        guard outline != "box", box.w > 0, box.h > 0 else { return end }
        let cx = box.x + box.w / 2, cy = box.y + box.h / 2, rx = box.w / 2, ry = box.h / 2
        if end.x == prev.x {
            let u = min(1, abs(end.x - cx) / rx)
            let dy = outline == "diamond" ? ry * (1 - u) : ry * sqrt(max(0, 1 - u * u))
            return DesignPt(end.x, prev.y < cy ? cy - dy : cy + dy)
        }
        if end.y == prev.y {
            let u = min(1, abs(end.y - cy) / ry)
            let dx = outline == "diamond" ? rx * (1 - u) : rx * sqrt(max(0, 1 - u * u))
            return DesignPt(prev.x < cx ? cx - dx : cx + dx, end.y)
        }
        return end
    }

    public static func connectorPath(
        fb: DesignBox,
        tb: DesignBox,
        fromAnchor: String?,
        toAnchor: String?,
        fromOutline: String = "box",
        toOutline: String = "box",
        straight: Bool = false,
        storedPoints: [DesignPt]? = nil,
        obstacles: [DesignBox] = []
    ) -> [DesignPt] {
        let fa = (fromAnchor == nil || fromAnchor == "auto") ? autoAnchor(from: fb, to: tb) : fromAnchor!
        let ta = (toAnchor == nil || toAnchor == "auto") ? autoAnchor(from: tb, to: fb) : toAnchor!
        var pts: [DesignPt]
        if let stored = storedPoints, pointsStillFit(stored, fb: fb, tb: tb, obstacles: obstacles, fa: fromAnchor == "auto" ? nil : fromAnchor, ta: toAnchor == "auto" ? nil : toAnchor) {
            pts = stored
        } else if straight {
            return [anchorPoint(fb, fa), anchorPoint(tb, ta)]
        } else {
            pts = routeOrthogonal(fb: fb, fa: fa, tb: tb, ta: ta, obstacles: obstacles)
        }
        if pts.count >= 2 {
            pts[0] = clipEnd(pts[0], prev: pts[1], box: fb, outline: fromOutline)
            pts[pts.count - 1] = clipEnd(pts[pts.count - 1], prev: pts[pts.count - 2], box: tb, outline: toOutline)
        }
        return pts
    }

    private static func onEdge(_ p: DesignPt, _ b: DesignBox, tol: Double = 1) -> Bool {
        let inX = p.x >= b.x - tol && p.x <= b.x + b.w + tol
        let inY = p.y >= b.y - tol && p.y <= b.y + b.h + tol
        return (inX && (abs(p.y - b.y) <= tol || abs(p.y - b.y - b.h) <= tol))
            || (inY && (abs(p.x - b.x) <= tol || abs(p.x - b.x - b.w) <= tol))
    }

    private static func segmentHits(_ a: DesignPt, _ b: DesignPt, _ box: DesignBox) -> Bool {
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
        let y0 = min(a.y, b.y), y1 = max(a.y, b.y)
        let eps = 0.01
        if x1 <= box.x + eps || x0 >= box.x + box.w - eps || y1 <= box.y + eps || y0 >= box.y + box.h - eps { return false }
        if a.x == b.x || a.y == b.y { return true }
        for i in 0...32 {
            let t = Double(i) / 32.0
            let px = a.x + (b.x - a.x) * t
            let py = a.y + (b.y - a.y) * t
            if px > box.x && px < box.x + box.w && py > box.y && py < box.y + box.h { return true }
        }
        return false
    }

    private static func pointsStillFit(_ pts: [DesignPt], fb: DesignBox, tb: DesignBox, obstacles: [DesignBox], fa: String?, ta: String?) -> Bool {
        guard pts.count >= 2, onEdge(pts[0], fb), onEdge(pts[pts.count - 1], tb) else { return false }
        if let fa, pts[0] != anchorPoint(fb, fa) { return false }
        if let ta, pts[pts.count - 1] != anchorPoint(tb, ta) { return false }
        let blocks = [fb, tb] + obstacles
        for i in 1..<pts.count {
            for o in blocks where segmentHits(pts[i - 1], pts[i], o) { return false }
        }
        return true
    }
}

// MARK: - Design Display List & Layout Engine (exact port of web/lib/designs/layout.ts)

public enum DesignDrawOp: Sendable, Equatable {
    case rect(x: Double, y: Double, w: Double, h: Double, r: Double, fill: DesignResolvedPaint?, stroke: String?, sw: Double, dash: [Double], opacity: Double, el: String)
    case ellipse(x: Double, y: Double, w: Double, h: Double, fill: DesignResolvedPaint?, stroke: String?, sw: Double, dash: [Double], opacity: Double, el: String)
    case path(d: String, box: DesignBox, fill: DesignResolvedPaint?, stroke: String?, sw: Double, dash: [Double], cap: String?, join: String?, opacity: Double, el: String)
    case polyline(points: [DesignPt], stroke: String, sw: Double, dash: [Double], join: String?, opacity: Double, el: String)
    case image(asset: String, x: Double, y: Double, w: Double, h: Double, r: Double, src: DesignBox, iw: Int, ih: Int, alt: String, opacity: Double, el: String)
    case text(x: Double, y: Double, text: String, weight: Int, italic: Bool, size: Double, fill: String, opacity: Double, el: String)
    case clip(x: Double, y: Double, w: Double, h: Double, r: Double)
    case unclip
    case rotate(deg: Double, cx: Double, cy: Double)
    case unrotate
}

public struct DesignLaidNode: Sendable, Equatable {
    public var id: String
    public var box: DesignBox
    public var ops: [DesignDrawOp]
}

public struct DesignLaidPage: Sendable, Equatable {
    public var nodes: [DesignLaidNode]
    public var connectors: [DesignDrawOp]
    public var box: DesignBox
    public var background: String?
    public var boxes: [String: DesignBox]
    public var rotations: [String: Double]
    public var local: [String: DesignBox]
    public var overflow: Set<String>

    public var allOps: [DesignDrawOp] {
        nodes.flatMap(\.ops) + connectors
    }
}

public final class DesignLayoutEngine {
    public static let shapeInset: Double = 8
    public static let stickyInset: Double = 12
    public static let lineHeightFactor: Double = 1.2
    public static let bulletIndent: Double = 20
    public static let stickyText = "#1A1206"
    public static let stickyColors: [String: String] = [
        "yellow": "#FDE68A", "pink": "#FBCFE8", "green": "#BBF7D0",
        "blue": "#BFDBFE", "violet": "#DDD6FE", "grey": "#E5E7EB",
    ]
    public static let fallbackColors: [DesignMode: [String: String]] = [
        .light: ["text": "#16161D", "text-secondary": "#5E5E6E", "bg": "#FFFFFF", "surface": "#FFFFFF", "border": "#D9D9E3"],
        .dark: ["text": "#ECECF1", "text-secondary": "#9A9AAE", "bg": "#0C0C10", "surface": "#16161D", "border": "#2A2A36"],
    ]

    private let design: DesignDocument
    private var nodeIndex: [String: DesignNode] = [:]
    private let activeTokenSet: DesignTokenSet?
    private var boxes: [String: DesignBox] = [:]
    private var rotations: [String: Double] = [:]
    private var local: [String: DesignBox] = [:]
    private var overflow = Set<String>()

    public init(design: DesignDocument) {
        self.design = design
        self.activeTokenSet = design.tokensRef.flatMap { design.tokenSets[$0.set] }
        func visit(_ n: DesignNode) {
            nodeIndex[n.id] = n
            for c in n.children ?? [] { visit(c) }
        }
        for p in design.pages {
            for n in p.children { visit(n) }
        }
    }

    public func resolveColor(_ c: String?, mode: DesignMode) -> String? {
        guard let c else { return nil }
        if !c.hasPrefix("$") { return c }
        let name = String(c.dropFirst())
        if mode == .light, let tok = activeTokenSet?.modes.light?[name], tok.kind == "color" { return tok.value }
        if let tok = activeTokenSet?.modes.dark[name], tok.kind == "color" { return tok.value }
        return Self.fallbackColors[mode]?[name] ?? Self.fallbackColors[mode]?["text"] ?? "#ECECF1"
    }

    public func resolvePaint(_ p: DesignPaint?, mode: DesignMode) -> DesignResolvedPaint? {
        guard let p else { return nil }
        switch p {
        case .color(let c):
            return resolveColor(c, mode: mode).map { .color($0) }
        case .gradient(let g):
            let s0 = resolveColor(g.stops.first, mode: mode) ?? "#FFFFFF"
            let s1 = resolveColor(g.stops.dropFirst().first ?? g.stops.first, mode: mode) ?? s0
            return .gradient(angle: g.angle, start: s0, end: s1)
        }
    }

    public static func dashLengths(_ dash: String?, sw: Double) -> [Double] {
        let base: [Double] = switch dash {
        case "dash": [4, 3]
        case "dot": [1, 1]
        case "dashDot": [4, 3, 1, 3]
        case "longDash": [8, 3]
        default: []
        }
        return base.map { DesignSchema.round2($0 * sw) }
    }

    public static func lineHeight(_ p: DesignParagraph) -> Double {
        (p.runs.map(\.size).max() ?? 16) * lineHeightFactor * (p.lineSpacing ?? 1)
    }

    public static func constrain(_ c: DesignNode, ow: Double, oh: Double, nw: Double, nh: Double) -> DesignNode {
        if c.type == .connector || (ow == nw && oh == nh) { return c }
        func axis(_ mode: String?, _ pos: Double, _ size: Double, _ o: Double, _ n: Double) -> (Double, Double) {
            switch mode {
            case "right", "bottom": return (pos + (n - o), size)
            case "left-right", "top-bottom": return (pos, max(0, size + (n - o)))
            case "center": return (pos + (n - o) / 2, size)
            case "scale": return o != 0 ? ((pos * n) / o, (size * n) / o) : (pos, size)
            default: return (pos, size)
            }
        }
        let (nx, nw2) = axis(c.constraints?.h, c.x, c.w, ow, nw)
        let (ny, nh2) = axis(c.constraints?.v, c.y, c.h, oh, nh)
        var out = c
        out.x = DesignSchema.round2(nx)
        out.y = DesignSchema.round2(ny)
        out.w = DesignSchema.round2(nw2)
        out.h = DesignSchema.round2(nh2)
        return out
    }

    public func expand(_ n: DesignNode) -> DesignNode {
        guard n.type == .instance, let compId = n.component, let main = nodeIndex[compId],
              main.type == .component || main.type == .frame else {
            return n
        }
        func clone(_ m: DesignNode) -> DesignNode {
            let ov = n.overrides?[m.id]
            var c = m
            c.id = "\(n.id)/\(m.id)"
            if let kids = m.children { c.children = kids.map(clone) }
            if let fill = ov?.fill { c.fill = fill }
            if let vis = ov?.visible { c.visible = vis }
            if let txt = ov?.text, c.type == .text, let firstP = c.paragraphs?.first, let firstR = firstP.runs.first {
                var r = firstR; r.text = txt
                var p = firstP; p.runs = [r]
                c.paragraphs = [p]
            }
            return c
        }
        var root = clone(main)
        if main.autoLayout == nil && (n.w != main.w || n.h != main.h) {
            root.children = (root.children ?? []).map { Self.constrain($0, ow: main.w, oh: main.h, nw: n.w, nh: n.h) }
        }
        root.id = n.id
        root.type = .frame
        root.x = n.x; root.y = n.y; root.w = n.w; root.h = n.h
        root.sizing = n.sizing ?? main.sizing
        root.name = n.name ?? main.name
        root.rotation = n.rotation
        root.opacity = n.opacity
        return root
    }

    private func flowKids(_ n: DesignNode) -> [DesignNode] {
        (n.children ?? []).filter { $0.type != .connector && !($0.absolute ?? false) && $0.visible != false }
    }

    private func sizingW(_ n: DesignNode) -> String { n.sizing?.w ?? "fixed" }
    private func sizingH(_ n: DesignNode) -> String { n.sizing?.h ?? "fixed" }

    private func wrapText(_ paragraphs: [DesignParagraph], innerW: Double) -> (lines: [(y: Double, lh: Double, maxSize: Double, left: Double, pieces: [(run: DesignRun, text: String, x: Double, w: Double)], align: String, last: Bool, bullet: (glyph: String, x: Double, run: DesignRun)?)], height: Double, width: Double) {
        typealias Piece = (run: DesignRun, text: String, x: Double, w: Double)
        typealias Line = (y: Double, lh: Double, maxSize: Double, left: Double, pieces: [Piece], align: String, last: Bool, bullet: (glyph: String, x: Double, run: DesignRun)?)
        var lines: [Line] = []
        var y = 0.0
        var number = 0
        for p in paragraphs {
            y += p.spaceBefore ?? 0
            let lh = Self.lineHeight(p)
            let maxSize = p.runs.map(\.size).max() ?? 16
            let level = p.level ?? 0
            let left = p.bullet != nil ? Self.bulletIndent * Double(level + 1) : 0
            number = p.bullet == "number" ? number + 1 : 0
            let firstIdx = lines.count
            var cur: [Piece] = []
            var w = 0.0
            func flush() {
                lines.append((y, lh, maxSize, left, cur, p.align ?? "left", false, nil))
                cur = []
                w = 0
                y += lh
            }
            for r in p.runs {
                let wt = r.effectiveWeight
                let it = r.italic ?? false
                var tokens: [String] = []
                var buf = ""
                for ch in r.text {
                    buf.append(ch)
                    if ch == " " { tokens.append(buf); buf = "" }
                }
                if !buf.isEmpty { tokens.append(buf) }
                for t in tokens {
                    let tw = DesignMetrics.measure(text: t, weight: wt, italic: it, size: r.size)
                    let trimmedStr = t.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                    let trimmed = DesignMetrics.measure(text: trimmedStr, weight: wt, italic: it, size: r.size)
                    if !cur.isEmpty && w + trimmed > innerW - left + 0.001 { flush() }
                    if cur.isEmpty && trimmed > innerW - left + 0.001 && innerW.isFinite {
                        var chunk = ""
                        for ch in t {
                            let cand = chunk + String(ch)
                            if !chunk.isEmpty && DesignMetrics.measure(text: cand, weight: wt, italic: it, size: r.size) > innerW - left + 0.001 {
                                let cw = DesignMetrics.measure(text: chunk, weight: wt, italic: it, size: r.size)
                                cur.append((r, chunk, 0, cw))
                                flush()
                                chunk = ""
                            }
                            chunk.append(ch)
                        }
                        let cw = DesignMetrics.measure(text: chunk, weight: wt, italic: it, size: r.size)
                        cur.append((r, chunk, 0, cw))
                        w = cw
                        continue
                    }
                    cur.append((r, t, w, tw))
                    w += tw
                }
            }
            flush()
            lines[lines.count - 1].last = true
            if let b = p.bullet, let r0 = p.runs.first {
                lines[firstIdx].bullet = (b == "number" ? "\(number)." : "•", Self.bulletIndent * Double(level), r0)
            }
        }
        var maxW = 0.0
        for l in lines {
            if let last = l.pieces.last {
                let trimmed = last.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                let lw = l.left + last.x + DesignMetrics.measure(text: trimmed, weight: last.run.effectiveWeight, italic: last.run.italic ?? false, size: last.run.size)
                maxW = max(maxW, lw)
            }
        }
        return (lines, y, maxW)
    }

    public func hugW(_ node: DesignNode) -> Double {
        let n = expand(node)
        if n.type == .text { return wrapText(n.paragraphs ?? [], innerW: .infinity).width }
        guard n.type != .connector, let al = n.autoLayout else { return n.type == .connector ? 0 : n.w }
        let pad = al.padding ?? [0, 0, 0, 0]
        let pr = pad.count > 1 ? pad[1] : 0
        let pl = pad.count > 3 ? pad[3] : 0
        let gap = al.gap ?? 0
        let ws = flowKids(n).map { c in
            sizingW(c) == "fill" ? (al.direction == "horizontal" ? hugW(c) : 0) : widthOf(c)
        }
        let body = al.direction == "horizontal"
            ? ws.reduce(0, +) + gap * Double(max(0, ws.count - 1))
            : (ws.max() ?? 0)
        return pl + pr + body
    }

    public func widthOf(_ n: DesignNode) -> Double {
        if n.type == .connector { return 0 }
        return sizingW(n) == "hug" ? hugW(n) : n.w
    }

    public func hugH(_ node: DesignNode, w: Double) -> Double {
        let n = expand(node)
        if n.type == .text { return wrapText(n.paragraphs ?? [], innerW: w).height }
        guard n.type != .connector, let al = n.autoLayout else { return n.type == .connector ? 0 : n.h }
        let placed = childBoxes(n, al: al, w: w, h: nil)
        let pad = al.padding ?? [0, 0, 0, 0]
        let pt = pad.count > 0 ? pad[0] : 0
        let pb = pad.count > 2 ? pad[2] : 0
        let gap = al.gap ?? 0
        let hs = placed.map(\.box.h)
        let body = al.direction == "vertical"
            ? hs.reduce(0, +) + gap * Double(max(0, hs.count - 1))
            : (hs.max() ?? 0)
        return pt + pb + body
    }

    public func heightOf(_ n: DesignNode, w: Double) -> Double {
        if n.type == .connector { return 0 }
        return sizingH(n) == "hug" ? hugH(n, w: w) : n.h
    }

    private func childBoxes(_ n: DesignNode, al: DesignAutoLayout, w: Double, h: Double?) -> [(child: DesignNode, box: DesignBox)] {
        let kids = flowKids(n)
        let pad = al.padding ?? [0, 0, 0, 0]
        let pt = pad.count > 0 ? pad[0] : 0
        let pr = pad.count > 1 ? pad[1] : 0
        let pb = pad.count > 2 ? pad[2] : 0
        let pl = pad.count > 3 ? pad[3] : 0
        let baseGap = al.gap ?? 0
        let innerW = w - pl - pr
        let horiz = al.direction == "horizontal"

        let widths: [Double]
        if horiz {
            let fixed = kids.map { sizingW($0) == "fill" ? nil : widthOf($0) }
            let fills = fixed.filter { $0 == nil }.count
            let used = fixed.compactMap { $0 }.reduce(0, +) + baseGap * Double(max(0, kids.count - 1))
            let share = fills > 0 ? max(0, innerW - used) / Double(fills) : 0
            widths = fixed.map { $0 ?? share }
        } else {
            widths = kids.map { sizingW($0) == "fill" ? max(0, innerW) : widthOf($0) }
        }

        let innerH = h.map { $0 - pt - pb }
        var optH: [Double?] = kids.enumerated().map { idx, c in
            let s = sizingH(c)
            if s == "hug" { return hugH(c, w: widths[idx]) }
            if s == "fill" { return horiz ? (innerH ?? c.h) : nil }
            return c.h
        }
        if !horiz {
            let fills = optH.filter { $0 == nil }.count
            let used = optH.compactMap { $0 }.reduce(0, +) + baseGap * Double(max(0, kids.count - 1))
            let share = (fills > 0 && innerH != nil) ? max(0, innerH! - used) / Double(fills) : 0
            optH = optH.map { $0 ?? share }
        }
        let hs = optH.map { $0 ?? 0 }
        let mainSizes = horiz ? widths : hs
        let total = mainSizes.reduce(0, +) + baseGap * Double(max(0, kids.count - 1))
        let mainInner = horiz ? innerW : (innerH ?? total)
        var gap = baseGap
        var start = 0.0
        switch al.justify {
        case "center": start = (mainInner - total) / 2
        case "end": start = mainInner - total
        case "space-between":
            if kids.count > 1 {
                gap = (mainInner - (total - baseGap * Double(kids.count - 1))) / Double(kids.count - 1)
            }
        default: break
        }
        let crossInner = horiz ? (innerH ?? (hs.max() ?? 0)) : innerW
        var pos = start
        return kids.enumerated().map { idx, c in
            let cw = widths[idx], ch = hs[idx]
            let cross = horiz ? ch : cw
            let off: Double = switch al.align {
            case "center": (crossInner - cross) / 2
            case "end": crossInner - cross
            default: 0
            }
            let box = horiz
                ? DesignBox(x: pl + pos, y: pt + off, w: cw, h: ch)
                : DesignBox(x: pl + off, y: pt + pos, w: cw, h: ch)
            pos += (horiz ? cw : ch) + gap
            return (c, box)
        }
    }

    private func emitTextOps(_ paragraphs: [DesignParagraph], box: DesignBox, inset: Double, valign: String, mode: DesignMode, ops: inout [DesignDrawOp], el: String, defaultColor: String) -> Double {
        let innerW = box.w - 2 * inset
        let wrapped = wrapText(paragraphs, innerW: innerW)
        let avail = box.h - 2 * inset
        let shift: Double = switch valign {
        case "middle": (avail - wrapped.height) / 2
        case "bottom": avail - wrapped.height
        default: 0
        }
        var highlights: [DesignDrawOp] = []
        var textOut: [DesignDrawOp] = []
        let f400 = DesignMetrics.face(weight: 400, italic: false)
        for l in wrapped.lines {
            let baseline = box.y + inset + shift + l.y + (l.lh - (f400.asc + f400.desc) * l.maxSize) / 2 + f400.asc * l.maxSize
            let usedW: Double = {
                guard let last = l.pieces.last else { return 0 }
                let trimmed = last.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                return last.x + DesignMetrics.measure(text: trimmed, weight: last.run.effectiveWeight, italic: last.run.italic ?? false, size: last.run.size)
            }()
            let room = innerW - l.left - usedW
            let dx: Double = switch l.align {
            case "center": room / 2
            case "right": room
            default: 0
            }
            let gaps = (l.align == "justify" && !l.last && room > 0) ? l.pieces.dropLast().filter { $0.text.hasSuffix(" ") }.count : 0
            let per = gaps > 0 ? room / Double(gaps) : 0
            var spread = 0.0
            if let b = l.bullet, l.pieces.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                textOut.append(.text(x: DesignSchema.round2(box.x + inset + b.x), y: DesignSchema.round2(baseline), text: b.glyph, weight: 400, italic: false, size: b.run.size, fill: resolveColor(b.run.color, mode: mode) ?? defaultColor, opacity: 1, el: el))
            }
            for pc in l.pieces {
                let px = box.x + inset + l.left + dx + pc.x + spread
                if per > 0 && pc.text.hasSuffix(" ") { spread += per }
                let text = pc.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let r = pc.run
                let wt = r.effectiveWeight
                let it = r.italic ?? false
                let tw = DesignMetrics.measure(text: text, weight: wt, italic: it, size: r.size)
                let fill = resolveColor(r.color, mode: mode) ?? defaultColor
                let fm = DesignMetrics.face(weight: wt, italic: it)
                if let hl = r.highlight, let hlColor = resolveColor(hl, mode: mode) {
                    highlights.append(.rect(x: DesignSchema.round2(px), y: DesignSchema.round2(baseline - fm.asc * r.size), w: DesignSchema.round2(tw), h: DesignSchema.round2((fm.asc + fm.desc) * r.size), r: 0, fill: .color(hlColor), stroke: nil, sw: 0, dash: [], opacity: 1, el: el))
                }
                textOut.append(.text(x: DesignSchema.round2(px), y: DesignSchema.round2(baseline), text: text, weight: wt, italic: it, size: r.size, fill: fill, opacity: 1, el: el))
                if r.underline == true {
                    textOut.append(.rect(x: DesignSchema.round2(px), y: DesignSchema.round2(baseline + fm.underline.pos * r.size), w: DesignSchema.round2(tw), h: DesignSchema.round2(fm.underline.thick * r.size), r: 0, fill: .color(fill), stroke: nil, sw: 0, dash: [], opacity: 1, el: el))
                }
                if r.strike == true {
                    textOut.append(.rect(x: DesignSchema.round2(px), y: DesignSchema.round2(baseline - fm.strike.pos * r.size), w: DesignSchema.round2(tw), h: DesignSchema.round2(fm.strike.thick * r.size), r: 0, fill: .color(fill), stroke: nil, sw: 0, dash: [], opacity: 1, el: el))
                }
            }
        }
        ops.append(contentsOf: highlights)
        ops.append(contentsOf: textOut)
        return wrapped.height
    }

    private func drawNode(_ node: DesignNode, ax: Double, ay: Double, w: Double, h: Double, mode inMode: DesignMode, ops: inout [DesignDrawOp]) {
        guard node.visible != false, node.type != .connector else { return }
        let id = node.id
        let n = expand(node)
        let mode = n.mode ?? inMode
        let box = DesignBox(x: ax, y: ay, w: w, h: h)
        boxes[id] = box
        if let rot = n.rotation, rot != 0 { rotations[id] = rot }

        let op0 = ops.count
        let hasRot = (n.rotation ?? 0) != 0
        if hasRot { ops.append(.rotate(deg: n.rotation ?? 0, cx: ax + w / 2, cy: ay + h / 2)) }

        let stColor = resolveColor(n.stroke, mode: mode)
        let stWidth = stColor != nil ? (n.strokeWidth ?? 1) : 0
        let stDash = stColor != nil ? Self.dashLengths(n.dash, sw: stWidth) : []

        switch n.type {
        case .frame, .component, .section:
            let fill = resolvePaint(n.fill, mode: mode)
            let isSection = n.type == .section
            let r = isSection ? 8 : (n.radius ?? 0)
            if fill != nil || (!isSection && stColor != nil) {
                ops.append(.rect(x: ax, y: ay, w: w, h: h, r: r, fill: fill, stroke: isSection ? nil : stColor, sw: isSection ? 0 : stWidth, dash: isSection ? [] : stDash, opacity: 1, el: id))
            }
            if isSection {
                ops.append(.text(x: ax + 16, y: ay + 28, text: n.name ?? "Section", weight: 600, italic: false, size: 14, fill: resolveColor("$text-secondary", mode: mode) ?? "#9A9AAE", opacity: 1, el: id))
            }
            let shouldClip = !isSection && (n.clip ?? false)
            if shouldClip { ops.append(.clip(x: ax, y: ay, w: w, h: h, r: r)) }
            drawChildren(n, box: box, mode: mode, ops: &ops)
            if shouldClip { ops.append(.unclip) }

        case .group:
            drawChildren(n, box: box, mode: mode, ops: &ops)

        case .shape:
            let fill = resolvePaint(n.fill, mode: mode)
            let shapeKind = SlideShapeKind(rawValue: n.shape ?? "rect") ?? .rect
            var textBox = box
            if shapeKind == .ellipse {
                ops.append(.ellipse(x: ax, y: ay, w: w, h: h, fill: fill, stroke: stColor, sw: stWidth, dash: stDash, opacity: 1, el: id))
            } else if shapeKind == .rect || shapeKind == .roundRect {
                let r = shapeKind == .roundRect ? min(n.radius ?? 8, w / 2, h / 2) : 0
                ops.append(.rect(x: ax, y: ay, w: w, h: h, r: r, fill: fill, stroke: stColor, sw: stWidth, dash: stDash, opacity: 1, el: id))
            } else {
                let g = SlideShapeGeometry.geometry(for: shapeKind, in: SlideFrame(x: ax, y: ay, w: w, h: h), radius: n.radius ?? 8)
                ops.append(.path(d: SlideShapeGeometry.svgPath(from: g.segs), box: box, fill: fill, stroke: stColor, sw: stWidth, dash: stDash, cap: nil, join: nil, opacity: 1, el: id))
                textBox = DesignBox(x: g.text.x, y: g.text.y, w: g.text.w, h: g.text.h)
            }
            if let st = n.shapeText {
                _ = emitTextOps(st.paragraphs, box: textBox, inset: Self.shapeInset, valign: st.valign ?? "middle", mode: mode, ops: &ops, el: id, defaultColor: resolveColor("$text", mode: mode) ?? "#ECECF1")
            }

        case .path:
            let offsetD = offsetPathD(n.d ?? "", dx: ax, dy: ay)
            ops.append(.path(d: offsetD, box: box, fill: resolvePaint(n.fill, mode: mode), stroke: stColor, sw: stWidth, dash: stDash, cap: n.cap, join: n.join, opacity: 1, el: id))

        case .text:
            let height = emitTextOps(n.paragraphs ?? [], box: box, inset: 0, valign: n.valign ?? "top", mode: mode, ops: &ops, el: id, defaultColor: resolveColor("$text", mode: mode) ?? "#ECECF1")
            if height > h + 0.5 { overflow.insert(id) }

        case .image:
            if let aid = n.asset, let a = design.assets[aid] {
                let c = n.crop ?? SlideCrop()
                var sx = c.l * Double(a.w), sy = c.t * Double(a.h)
                var sw = (1 - c.l - c.r) * Double(a.w), sh = (1 - c.t - c.b) * Double(a.h)
                var dest = box
                let fit = n.fit ?? "cover"
                if fit == "cover" {
                    let k = max(w / max(1, sw), h / max(1, sh))
                    let vw = w / k, vh = h / k
                    sx += (sw - vw) / 2
                    sy += (sh - vh) / 2
                    sw = vw; sh = vh
                } else if fit == "contain" {
                    let k = min(w / max(1, sw), h / max(1, sh))
                    dest = DesignBox(x: ax + (w - sw * k) / 2, y: ay + (h - sh * k) / 2, w: sw * k, h: sh * k)
                }
                ops.append(.image(asset: aid, x: dest.x, y: dest.y, w: dest.w, h: dest.h, r: n.radius ?? 0, src: DesignBox(x: DesignSchema.round2(sx), y: DesignSchema.round2(sy), w: DesignSchema.round2(sw), h: DesignSchema.round2(sh)), iw: a.w, ih: a.h, alt: n.alt ?? a.alt ?? "", opacity: 1, el: id))
            } else {
                ops.append(.rect(x: ax, y: ay, w: w, h: h, r: n.radius ?? 0, fill: .color("#E5E7EB"), stroke: nil, sw: 0, dash: [], opacity: 1, el: id))
            }

        case .sticky:
            let bgHex = Self.stickyColors[n.stickyColor ?? "yellow"] ?? Self.stickyColors["yellow"]!
            ops.append(.rect(x: ax, y: ay, w: w, h: h, r: 4, fill: .color(bgHex), stroke: nil, sw: 0, dash: [], opacity: 1, el: id))
            var paras = [DesignParagraph(runs: [DesignRun(text: n.stickyText ?? "", size: 14, weight: 500, color: Self.stickyText)])]
            if let author = n.author, !author.isEmpty {
                paras.append(DesignParagraph(runs: [DesignRun(text: author, size: 11, color: Self.stickyText)], spaceBefore: 6))
            }
            _ = emitTextOps(paras, box: box, inset: Self.stickyInset, valign: "top", mode: mode, ops: &ops, el: id, defaultColor: Self.stickyText)

        case .instance, .connector:
            break
        }

        if hasRot { ops.append(.unrotate) }
        if let op = n.opacity, op < 1 {
            for i in op0..<ops.count { ops[i] = multiplyOpacity(ops[i], factor: op) }
        }
    }

    private func drawChildren(_ n: DesignNode, box: DesignBox, mode: DesignMode, ops: inout [DesignDrawOp]) {
        let placed = n.autoLayout.map { childBoxes(n, al: $0, w: box.w, h: box.h) } ?? []
        let byId = Dictionary(uniqueKeysWithValues: placed.map { ($0.child.id, $0.box) })
        var conns: [DesignNode] = []
        for c in n.children ?? [] {
            if c.type == .connector { conns.append(c); continue }
            if let b = byId[c.id] {
                local[c.id] = b
                drawNode(c, ax: box.x + b.x, ay: box.y + b.y, w: b.w, h: b.h, mode: mode, ops: &ops)
            } else {
                let cw = widthOf(c)
                let ch = heightOf(c, w: cw)
                local[c.id] = DesignBox(x: c.x, y: c.y, w: cw, h: ch)
                drawNode(c, ax: box.x + c.x, ay: box.y + c.y, w: cw, h: ch, mode: mode, ops: &ops)
            }
        }
        let parentBg: String? = {
            if case .color(let c) = n.fill { return resolveColor(c, mode: mode) }
            return nil
        }()
        for c in conns {
            drawConnector(c, mode: mode, ops: &ops, bg: parentBg, siblings: n.children ?? [], originX: box.x, originY: box.y)
        }
    }

    private func drawConnector(_ c: DesignNode, mode: DesignMode, ops: inout [DesignDrawOp], bg: String?, siblings: [DesignNode], originX: Double, originY: Double) {
        guard c.visible != false, let fromEnd = c.from, let toEnd = c.to,
              let fb = boxes[fromEnd.node], let tb = boxes[toEnd.node] else { return }
        let ends: Set<String> = [fromEnd.node, toEnd.node]
        var obstacles: [DesignBox] = []
        func collectObstacles(_ list: [DesignNode]) {
            for item in list {
                if item.type == .connector || item.visible == false || ends.contains(item.id) { continue }
                if containsAny(item, ids: ends) { collectObstacles(item.children ?? []) }
                else if let b = boxes[item.id] { obstacles.append(b) }
            }
        }
        func containsAny(_ item: DesignNode, ids: Set<String>) -> Bool {
            (item.children ?? []).contains { ids.contains($0.id) || containsAny($0, ids: ids) }
        }
        collectObstacles(siblings)

        func outlineOf(_ id: String) -> String {
            guard let n = nodeIndex[id], n.type == .shape, let s = n.shape else { return "box" }
            return (s == "diamond" || s == "ellipse") ? s : "box"
        }

        let stored = c.points?.compactMap { pair -> DesignPt? in
            pair.count >= 2 ? DesignPt(originX + pair[0], originY + pair[1]) : nil
        }
        let pts = DesignConnectorRouter.connectorPath(
            fb: fb, tb: tb,
            fromAnchor: fromEnd.anchor, toAnchor: toEnd.anchor,
            fromOutline: outlineOf(fromEnd.node), toOutline: outlineOf(toEnd.node),
            straight: c.route == "straight",
            storedPoints: stored,
            obstacles: obstacles
        )
        guard pts.count >= 2 else { return }

        let stroke = resolveColor(c.stroke ?? "$text-secondary", mode: mode) ?? "#9A9AAE"
        let sw = c.strokeWidth ?? 1.5
        let arrowLen = 10.0
        var line = pts
        var heads: [DesignDrawOp] = []

        func makeHead(tip: DesignPt, from: DesignPt, kind: String, adjustEnd: (DesignPt) -> Void) {
            guard kind != "none" else { return }
            let len = max(1, hypot(tip.x - from.x, tip.y - from.y))
            let ux = (tip.x - from.x) / len, uy = (tip.y - from.y) / len
            if kind == "dot" {
                heads.append(.ellipse(x: tip.x - 3.5, y: tip.y - 3.5, w: 7, h: 7, fill: .color(stroke), stroke: nil, sw: 0, dash: [], opacity: 1, el: c.id))
                return
            }
            adjustEnd(DesignPt(tip.x - ux * arrowLen * 0.8, tip.y - uy * arrowLen * 0.8))
            let bx = tip.x - ux * arrowLen, by = tip.y - uy * arrowLen
            let half = arrowLen * 0.45
            let d = "M\(DesignSchema.round2(tip.x)) \(DesignSchema.round2(tip.y)) L\(DesignSchema.round2(bx - uy * half)) \(DesignSchema.round2(by + ux * half)) L\(DesignSchema.round2(bx + uy * half)) \(DesignSchema.round2(by - ux * half)) Z"
            heads.append(.path(d: d, box: DesignBox(x: tip.x - arrowLen, y: tip.y - arrowLen, w: 2 * arrowLen, h: 2 * arrowLen), fill: .color(stroke), stroke: nil, sw: 0, dash: [], cap: nil, join: nil, opacity: 1, el: c.id))
        }

        makeHead(tip: pts[pts.count - 1], from: pts[pts.count - 2], kind: c.endArrow ?? "arrow") { line[line.count - 1] = $0 }
        makeHead(tip: pts[0], from: pts[1], kind: c.startArrow ?? "none") { line[0] = $0 }
        ops.append(.polyline(points: line, stroke: stroke, sw: sw, dash: Self.dashLengths(c.dash, sw: sw), join: "round", opacity: 1, el: c.id))
        ops.append(contentsOf: heads)

        if let label = c.label, !label.isEmpty {
            var bestLen = 0.0, bestIdx = 1
            for i in 1..<pts.count {
                let l = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
                if l > bestLen { bestLen = l; bestIdx = i }
            }
            let mx = (pts[bestIdx].x + pts[bestIdx - 1].x) / 2
            let my = (pts[bestIdx].y + pts[bestIdx - 1].y) / 2
            let size = 12.0
            let tw = DesignMetrics.measure(text: label, weight: 400, italic: false, size: size)
            let pillFill = bg ?? resolveColor("$bg", mode: mode) ?? "#0C0C10"
            ops.append(.rect(x: DesignSchema.round2(mx - tw / 2 - 6), y: DesignSchema.round2(my - 10), w: DesignSchema.round2(tw + 12), h: 20, r: 4, fill: .color(pillFill), stroke: nil, sw: 0, dash: [], opacity: 1, el: c.id))
            let f = DesignMetrics.face(weight: 400, italic: false)
            ops.append(.text(x: DesignSchema.round2(mx - tw / 2), y: DesignSchema.round2(my - 10 + (20 - (f.asc + f.desc) * size) / 2 + f.asc * size), text: label, weight: 400, italic: false, size: size, fill: resolveColor("$text-secondary", mode: mode) ?? "#9A9AAE", opacity: 1, el: c.id))
        }
    }

    public func layoutPage(_ page: DesignPage) -> DesignLaidPage {
        boxes.removeAll()
        rotations.removeAll()
        local.removeAll()
        overflow.removeAll()
        var laidNodes: [DesignLaidNode] = []
        var conns: [DesignNode] = []
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity

        for n in page.children {
            if n.type == .connector { conns.append(n); continue }
            if n.visible == false { continue }
            let w = widthOf(n)
            let h = heightOf(n, w: w)
            var ops: [DesignDrawOp] = []
            local[n.id] = DesignBox(x: n.x, y: n.y, w: w, h: h)
            drawNode(n, ax: n.x, ay: n.y, w: w, h: h, mode: design.mode, ops: &ops)
            let b = DesignBox(x: n.x, y: n.y, w: w, h: h)
            laidNodes.append(DesignLaidNode(id: n.id, box: b, ops: ops))
            x0 = min(x0, b.x); y0 = min(y0, b.y)
            x1 = max(x1, b.x + b.w); y1 = max(y1, b.y + b.h)
        }
        var connOps: [DesignDrawOp] = []
        let pageBg = resolveColor(page.background, mode: design.mode)
        for c in conns {
            drawConnector(c, mode: design.mode, ops: &connOps, bg: pageBg, siblings: page.children, originX: 0, originY: 0)
        }
        let bounds = x0.isFinite ? DesignBox(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : DesignBox(x: 0, y: 0, w: 0, h: 0)
        return DesignLaidPage(nodes: laidNodes, connectors: connOps, box: bounds, background: pageBg, boxes: boxes, rotations: rotations, local: local, overflow: overflow)
    }

    public static func settle(_ design: DesignDocument) -> DesignDocument {
        let engine = DesignLayoutEngine(design: design)
        var out = design
        for pi in out.pages.indices {
            let laid = engine.layoutPage(out.pages[pi])
            func fix(_ n: DesignNode) -> DesignNode {
                var m = n
                if let kids = m.children { m.children = kids.map(fix) }
                if m.type != .connector, let b = laid.local[m.id] {
                    m.x = DesignSchema.round2(b.x)
                    m.y = DesignSchema.round2(b.y)
                    m.w = DesignSchema.round2(b.w)
                    m.h = DesignSchema.round2(b.h)
                }
                return m
            }
            out.pages[pi].children = out.pages[pi].children.map(fix)
        }
        return out
    }

    private func offsetPathD(_ d: String, dx: Double, dy: Double) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(-?[\d.]+(?:[eE]-?\d+)?)[ ,]+(-?[\d.]+(?:[eE]-?\d+)?)"#) else { return d }
        let ns = d as NSString
        let matches = regex.matches(in: d, range: NSRange(location: 0, length: ns.length))
        var out = d
        for m in matches.reversed() {
            let xs = ns.substring(with: m.range(at: 1))
            let ys = ns.substring(with: m.range(at: 2))
            if let xv = Double(xs), let yv = Double(ys) {
                let rep = "\(DesignSchema.round2(dx + xv)) \(DesignSchema.round2(dy + yv))"
                out = (out as NSString).replacingCharacters(in: m.range, with: rep)
            }
        }
        return out
    }

    private func multiplyOpacity(_ op: DesignDrawOp, factor: Double) -> DesignDrawOp {
        switch op {
        case .rect(let x, let y, let w, let h, let r, let f, let s, let sw, let d, let o, let el):
            .rect(x: x, y: y, w: w, h: h, r: r, fill: f, stroke: s, sw: sw, dash: d, opacity: o * factor, el: el)
        case .ellipse(let x, let y, let w, let h, let f, let s, let sw, let d, let o, let el):
            .ellipse(x: x, y: y, w: w, h: h, fill: f, stroke: s, sw: sw, dash: d, opacity: o * factor, el: el)
        case .path(let pd, let b, let f, let s, let sw, let d, let cap, let join, let o, let el):
            .path(d: pd, box: b, fill: f, stroke: s, sw: sw, dash: d, cap: cap, join: join, opacity: o * factor, el: el)
        case .polyline(let pts, let s, let sw, let d, let j, let o, let el):
            .polyline(points: pts, stroke: s, sw: sw, dash: d, join: j, opacity: o * factor, el: el)
        case .image(let a, let x, let y, let w, let h, let r, let src, let iw, let ih, let alt, let o, let el):
            .image(asset: a, x: x, y: y, w: w, h: h, r: r, src: src, iw: iw, ih: ih, alt: alt, opacity: o * factor, el: el)
        case .text(let x, let y, let t, let wt, let it, let sz, let f, let o, let el):
            .text(x: x, y: y, text: t, weight: wt, italic: it, size: sz, fill: f, opacity: o * factor, el: el)
        case .clip, .unclip, .rotate, .unrotate:
            op
        }
    }
}

// MARK: - CoreGraphics Renderer for DesignDrawOps (120Hz Editor, Present Mode & PDF Export)

public enum DesignCGDrawer {
    public static func draw(ops: [DesignDrawOp], images: [String: CGImage], in ctx: CGContext) {
        for op in ops {
            switch op {
            case .clip(let x, let y, let w, let h, let r):
                ctx.saveGState()
                let rect = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
                let rr = min(r, rect.width / 2, rect.height / 2)
                if rr > 0 {
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil))
                    ctx.clip()
                } else {
                    ctx.clip(to: rect)
                }
            case .unclip, .unrotate:
                ctx.restoreGState()
            case .rotate(let deg, let cx, let cy):
                ctx.saveGState()
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: deg * .pi / 180)
                ctx.translateBy(x: -cx, y: -cy)
            case .rect(let x, let y, let w, let h, let r, let fill, let stroke, let sw, let dash, let opacity, _):
                ctx.saveGState()
                ctx.setAlpha(CGFloat(opacity))
                let rect = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
                let rr = min(r, rect.width / 2, rect.height / 2)
                let path = rr > 0 ? CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil) : CGPath(rect: rect, transform: nil)
                paint(path, bounds: rect, fill: fill, stroke: stroke, sw: sw, dash: dash, cap: nil, join: nil, in: ctx)
                ctx.restoreGState()
            case .ellipse(let x, let y, let w, let h, let fill, let stroke, let sw, let dash, let opacity, _):
                ctx.saveGState()
                ctx.setAlpha(CGFloat(opacity))
                let rect = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
                paint(CGPath(ellipseIn: rect, transform: nil), bounds: rect, fill: fill, stroke: stroke, sw: sw, dash: dash, cap: nil, join: nil, in: ctx)
                ctx.restoreGState()
            case .path(let d, let box, let fill, let stroke, let sw, let dash, let cap, let join, let opacity, _):
                ctx.saveGState()
                ctx.setAlpha(CGFloat(opacity))
                let path = SVGPathParser.parse(d)
                paint(path, bounds: box.cgRect, fill: fill, stroke: stroke, sw: sw, dash: dash, cap: cap, join: join, in: ctx)
                ctx.restoreGState()
            case .polyline(let pts, let stroke, let sw, let dash, let join, let opacity, _):
                guard pts.count >= 2 else { continue }
                ctx.saveGState()
                ctx.setAlpha(CGFloat(opacity))
                ctx.setStrokeColor(SlideCGDrawer.cgColor(stroke))
                ctx.setLineWidth(sw)
                ctx.setLineJoin(join == "round" ? .round : join == "bevel" ? .bevel : .miter)
                if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
                for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                ctx.strokePath()
                ctx.restoreGState()
            case .image(let aid, let x, let y, let w, let h, let r, let src, let iw, let ih, _, let opacity, _):
                if let img = images[aid] {
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(opacity))
                    let rect = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
                    let rr = min(r, rect.width / 2, rect.height / 2)
                    if rr > 0 {
                        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil))
                        ctx.clip()
                    } else {
                        ctx.clip(to: rect)
                    }
                    let sx = w / max(1, src.w), sy = h / max(1, src.h)
                    let drawRect = CGRect(x: x - src.x * sx, y: y - src.y * sy, width: Double(iw) * sx, height: Double(ih) * sy)
                    ctx.translateBy(x: 0, y: drawRect.minY + drawRect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: drawRect)
                    ctx.restoreGState()
                }
            case .text(let x, let y, let text, let weight, let italic, let size, let fill, let opacity, _):
                ctx.saveGState()
                ctx.setAlpha(CGFloat(opacity))
                let font = makeInterCTFont(weight: weight, italic: italic, size: size)
                let color = SlideCGDrawer.cgColor(fill)
                let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color, kCTKernAttributeName: 0.0]
                let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
    }

    private static func makeInterCTFont(weight: Int, italic: Bool, size: Double) -> CTFont {
        let weightNum: CGFloat = switch weight {
        case 500: 0.23
        case 600: 0.30
        case 700...: 0.40
        default: 0.0
        }
        var traits: [CFString: Any] = [kCTFontWeightTrait: weightNum]
        if italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.italicTrait.rawValue }
        let desc = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Inter",
            kCTFontTraitsAttribute: traits,
        ] as CFDictionary)
        let candidate = CTFontCreateWithFontDescriptor(desc, CGFloat(size), nil)
        let family = CTFontCopyFamilyName(candidate) as String
        if family.localizedCaseInsensitiveContains("Inter") { return candidate }
        return SlideLayoutEngine.makeCTFont(slot: .sans, bold: weight >= 600, italic: italic, size: size)
    }

    private static func paint(_ path: CGPath, bounds: CGRect, fill: DesignResolvedPaint?, stroke: String?, sw: Double, dash: [Double], cap: String?, join: String?, in ctx: CGContext) {
        if let fill {
            ctx.saveGState()
            switch fill {
            case .color(let hex):
                ctx.setFillColor(SlideCGDrawer.cgColor(hex))
                ctx.addPath(path)
                ctx.fillPath()
            case .gradient(let angle, let start, let end):
                ctx.addPath(path)
                ctx.clip()
                let rad = angle * .pi / 180
                let cx = cos(rad), sy = sin(rad)
                let p0 = CGPoint(x: bounds.minX + (0.5 - cx / 2) * bounds.width, y: bounds.minY + (0.5 - sy / 2) * bounds.height)
                let p1 = CGPoint(x: bounds.minX + (0.5 + cx / 2) * bounds.width, y: bounds.minY + (0.5 + sy / 2) * bounds.height)
                let colors = [SlideCGDrawer.cgColor(start), SlideCGDrawer.cgColor(end)] as CFArray
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(grad, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            ctx.restoreGState()
        }
        if let stroke, sw > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(SlideCGDrawer.cgColor(stroke))
            ctx.setLineWidth(sw)
            ctx.setLineCap(cap == "round" ? .round : cap == "square" ? .square : .butt)
            ctx.setLineJoin(join == "round" ? .round : join == "bevel" ? .bevel : .miter)
            if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
