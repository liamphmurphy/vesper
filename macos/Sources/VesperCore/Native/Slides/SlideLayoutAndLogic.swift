import CoreGraphics
import CoreText
import Foundation

// MARK: - Slide Display List & Layout Engine (parity with web/lib/slides/layout.ts)

public struct SlideRotation: Sendable, Equatable, Hashable {
    public var deg: Double
    public var cx: Double
    public var cy: Double

    public init(deg: Double, cx: Double, cy: Double) {
        self.deg = deg
        self.cx = cx
        self.cy = cy
    }
}

public enum SlideDrawOp: Sendable, Equatable {
    case rect(x: Double, y: Double, w: Double, h: Double, r: Double, fill: SlideResolvedPaint?, fillOpacity: Double?, stroke: String?, sw: Double, strokeOpacity: Double?, dash: [Double], rot: SlideRotation?, el: String?)
    case ellipse(x: Double, y: Double, w: Double, h: Double, fill: SlideResolvedPaint?, fillOpacity: Double?, stroke: String?, sw: Double, strokeOpacity: Double?, dash: [Double], rot: SlideRotation?, el: String)
    case path(segs: [SlidePathSeg], box: SlideFrame, fill: SlideResolvedPaint?, fillOpacity: Double?, stroke: String?, sw: Double, strokeOpacity: Double?, dash: [Double], rot: SlideRotation?, el: String)
    case line(x1: Double, y1: Double, x2: Double, y2: Double, stroke: String, sw: Double, strokeOpacity: Double?, dash: [Double], startArrow: Bool, endArrow: Bool, rot: SlideRotation?, el: String)
    case image(asset: String, x: Double, y: Double, w: Double, h: Double, src: SlideFrame, alt: String, opacity: Double?, rot: SlideRotation?, el: String)
    case highlight(x: Double, y: Double, w: Double, h: Double, fill: String, rot: SlideRotation?, el: String)
    case text(x: Double, y: Double, text: String, slot: SlideFontSlot, bold: Bool, italic: Bool, size: Double, color: String, underline: Bool, strike: Bool, w: Double, rot: SlideRotation?, el: String)
}

public struct LaidSlide: Sendable, Equatable {
    public var ops: [SlideDrawOp]
    public var overflow: Set<String>
}

public enum SlideLayoutEngine: Sendable {
    public typealias MeasureFn = @Sendable (_ text: String, _ slot: SlideFontSlot, _ bold: Bool, _ italic: Bool, _ size: Double) -> Double

    public static func coreTextMeasure(text: String, slot: SlideFontSlot, bold: Bool, italic: Bool, size: Double) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = makeCTFont(slot: slot, bold: bold, italic: italic, size: size)
        let attr = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    public static func makeCTFont(slot: SlideFontSlot, bold: Bool, italic: Bool, size: Double) -> CTFont {
        let base = CTFontCreateWithName(slot.systemFontName as CFString, CGFloat(size), nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        if !traits.isEmpty,
           let styled = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, traits, traits) {
            return styled
        }
        return base
    }

    public static func lineHeight(for p: SlideParagraph) -> Double {
        let maxRun = p.runs.map(\.size).max() ?? 44
        return maxRun * SlideConstants.lineHeightMultiplier * (p.lineSpacing ?? 1)
    }

    public static func textFrame(for element: SlideElement) -> SlideFrame {
        if case .shape(let s) = element, s.shape.isPreset {
            return SlideShapeGeometry.geometry(for: s.shape, in: s.frame).text
        }
        return element.frame
    }

    public static func imageSource(for img: SlideImageElement, asset: SlideAsset) -> SlideFrame {
        let c = img.crop ?? SlideCrop()
        var x = c.l * Double(asset.w)
        var y = c.t * Double(asset.h)
        var w = (1 - c.l - c.r) * Double(asset.w)
        var h = (1 - c.t - c.b) * Double(asset.h)
        let fa = img.frame.w / max(1, img.frame.h)
        if w / max(1, h) > fa {
            let nw = h * fa
            x += (w - nw) / 2
            w = nw
        } else {
            let nh = w / fa
            y += (h - nh) / 2
            h = nh
        }
        return SlideFrame(x: x, y: y, w: w, h: h)
    }

    public static func layoutText(
        theme: SlideTheme,
        box: SlideTextBox,
        frame: SlideFrame,
        measure: MeasureFn = coreTextMeasure,
        el: String,
        rot: SlideRotation?
    ) -> (ops: [SlideDrawOp], overflow: Bool, height: Double) {
        struct Piece { let run: SlideRun; let slot: SlideFontSlot; let text: String; let x: Double; let w: Double }
        struct Line {
            let y: Double; let lh: Double; let maxSize: Double; let left: Double
            let pieces: [Piece]; let align: String; var last: Bool
            var bullet: (glyph: String, x: Double, run: SlideRun, slot: SlideFontSlot)?
        }

        let innerW = max(1, frame.w - 2 * SlideConstants.inset)
        var lines: [Line] = []
        var y = 0.0
        var number = 0

        for p in box.paragraphs {
            let maxSize = p.runs.map(\.size).max() ?? 44
            let lh = lineHeight(for: p)
            let level = p.level ?? 0
            let left = p.bullet != nil ? SlideConstants.bulletIndent * Double(level + 1) : 0
            number = p.bullet == "number" ? number + 1 : 0
            y += p.spaceBefore ?? 0

            var tokens: [(run: SlideRun, slot: SlideFontSlot, text: String)] = []
            for r in p.runs {
                let slot = SlideSchema.slotOf(theme, font: r.font)
                for chunk in splitKeepingTrailingSpace(r.text) where !chunk.isEmpty {
                    tokens.append((r, slot, chunk))
                }
            }

            let firstLineIdx = lines.count
            var cur: [Piece] = []
            var w = 0.0

            func flush() {
                lines.append(Line(y: y, lh: lh, maxSize: maxSize, left: left, pieces: cur, align: p.align ?? "left", last: false, bullet: nil))
                cur = []
                w = 0
                y += lh
            }

            for t in tokens {
                let bold = t.run.bold ?? false
                let italic = t.run.italic ?? false
                let tw = measure(t.text, t.slot, bold, italic, t.run.size)
                let trimmed = measure(trimTrailingSpaces(t.text), t.slot, bold, italic, t.run.size)
                if !cur.isEmpty && w + trimmed > innerW - left { flush() }
                if cur.isEmpty && trimmed > innerW - left {
                    var chunk = ""
                    for ch in t.text {
                        let cand = chunk + String(ch)
                        if !chunk.isEmpty && measure(cand, t.slot, bold, italic, t.run.size) > innerW - left {
                            cur.append(Piece(run: t.run, slot: t.slot, text: chunk, x: 0, w: measure(chunk, t.slot, bold, italic, t.run.size)))
                            flush()
                            chunk = ""
                        }
                        chunk.append(ch)
                    }
                    let cw = measure(chunk, t.slot, bold, italic, t.run.size)
                    cur.append(Piece(run: t.run, slot: t.slot, text: chunk, x: 0, w: cw))
                    w = cw
                    continue
                }
                cur.append(Piece(run: t.run, slot: t.slot, text: t.text, x: w, w: tw))
                w += tw
            }
            flush()
            lines[lines.count - 1].last = true
            if let bullet = p.bullet, let firstRun = p.runs.first {
                lines[firstLineIdx].bullet = (
                    glyph: bullet == "number" ? "\(number)." : "•",
                    x: SlideConstants.bulletIndent * Double(level),
                    run: firstRun,
                    slot: SlideSchema.slotOf(theme, font: firstRun.font)
                )
            }
        }

        let height = y
        let avail = frame.h - 2 * SlideConstants.inset
        let shift: Double = switch box.valign {
        case "middle": (avail - height) / 2
        case "bottom": avail - height
        default: 0
        }

        var highlights: [SlideDrawOp] = []
        var textOps: [SlideDrawOp] = []

        for l in lines {
            let slot0 = l.pieces.first?.slot ?? l.bullet?.slot ?? .sans
            let m = slot0.metrics
            let baseline = frame.y + SlideConstants.inset + shift + l.y + (l.lh - (m.asc + m.desc) * l.maxSize) / 2 + m.asc * l.maxSize
            let used: Double = {
                guard let last = l.pieces.last else { return 0 }
                return last.x + measure(trimTrailingSpaces(last.text), last.slot, last.run.bold ?? false, last.run.italic ?? false, last.run.size)
            }()
            let room = innerW - l.left - used
            let dx: Double = switch l.align {
            case "center": room / 2
            case "right": room
            default: 0
            }
            let gaps = (l.align == "justify" && !l.last && room > 0)
                ? l.pieces.dropLast().filter { $0.text.hasSuffix(" ") }.count
                : 0
            let per = gaps > 0 ? room / Double(gaps) : 0

            var placed: [(pc: Piece, x: Double, w: Double)] = []
            var spread = 0.0
            for pc in l.pieces {
                let px = frame.x + SlideConstants.inset + l.left + dx + pc.x + spread
                if per > 0 && pc.text.hasSuffix(" ") { spread += per }
                if !pc.text.isEmpty {
                    let pw = measure(trimTrailingSpaces(pc.text), pc.slot, pc.run.bold ?? false, pc.run.italic ?? false, pc.run.size)
                    placed.append((pc, px, pw))
                }
            }

            if let b = l.bullet, l.pieces.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                textOps.append(.text(
                    x: frame.x + SlideConstants.inset + b.x,
                    y: baseline,
                    text: b.glyph,
                    slot: b.slot,
                    bold: false,
                    italic: false,
                    size: b.run.size,
                    color: SlideSchema.resolveColor(theme, b.run.color),
                    underline: false,
                    strike: false,
                    w: 0,
                    rot: rot,
                    el: el
                ))
            }

            for (idx, item) in placed.enumerated() {
                let pc = item.pc
                textOps.append(.text(
                    x: item.x,
                    y: baseline,
                    text: pc.text,
                    slot: pc.slot,
                    bold: pc.run.bold ?? false,
                    italic: pc.run.italic ?? false,
                    size: pc.run.size,
                    color: SlideSchema.resolveColor(theme, pc.run.color),
                    underline: pc.run.underline ?? false,
                    strike: pc.run.strike ?? false,
                    w: item.w,
                    rot: rot,
                    el: el
                ))
                if let hl = pc.run.highlight {
                    let fill = SlideSchema.resolveColor(theme, hl)
                    let next = idx + 1 < placed.count ? placed[idx + 1] : nil
                    let endX: Double = {
                        if let next, let nhl = next.pc.run.highlight, SlideSchema.resolveColor(theme, nhl) == fill {
                            return next.x
                        }
                        return item.x + item.w
                    }()
                    let pm = pc.slot.metrics
                    highlights.append(.highlight(
                        x: item.x,
                        y: baseline - pm.asc * pc.run.size,
                        w: endX - item.x,
                        h: (pm.asc + pm.desc) * pc.run.size,
                        fill: fill,
                        rot: rot,
                        el: el
                    ))
                }
            }
        }
        return (highlights + textOps, height > avail + 0.5, height)
    }

    public static func layoutSlide(deck: SlideDeck, slide: Slide, measure: MeasureFn = coreTextMeasure) -> LaidSlide {
        let theme = deck.theme
        var ops: [SlideDrawOp] = [
            .rect(x: 0, y: 0, w: deck.size.w, h: deck.size.h, r: 0, fill: SlideSchema.resolvePaint(theme, slide.background?.color, fallback: .background), fillOpacity: nil, stroke: nil, sw: 0, strokeOpacity: nil, dash: [], rot: nil, el: nil)
        ]
        var overflow = Set<String>()

        func lay(_ el: SlideElement) {
            let f = el.frame
            let rot: SlideRotation? = (el.rotation ?? 0) != 0 ? SlideRotation(deg: el.rotation ?? 0, cx: f.x + f.w / 2, cy: f.y + f.h / 2) : nil
            switch el {
            case .shape(let s):
                let sw = s.strokeWidth ?? 0
                let fill = s.fill.map { SlideSchema.resolvePaint(theme, $0) }
                let stroke = s.stroke.map { SlideSchema.resolveColor(theme, $0) }
                let dash = (s.dash ?? .solid).lengths(strokeWidth: sw)
                if s.shape.isPreset {
                    let g = SlideShapeGeometry.geometry(for: s.shape, in: f, radius: s.radius ?? 24)
                    ops.append(.path(segs: g.segs, box: f, fill: fill, fillOpacity: s.fillOpacity, stroke: stroke, sw: sw, strokeOpacity: s.strokeOpacity, dash: dash, rot: rot, el: s.id))
                } else if s.shape == .ellipse {
                    ops.append(.ellipse(x: f.x, y: f.y, w: f.w, h: f.h, fill: fill, fillOpacity: s.fillOpacity, stroke: stroke, sw: sw, strokeOpacity: s.strokeOpacity, dash: dash, rot: rot, el: s.id))
                } else {
                    let r = s.shape == .roundRect ? min(s.radius ?? 24, f.w / 2, f.h / 2) : 0
                    ops.append(.rect(x: f.x, y: f.y, w: f.w, h: f.h, r: r, fill: fill, fillOpacity: s.fillOpacity, stroke: stroke, sw: sw, strokeOpacity: s.strokeOpacity, dash: dash, rot: rot, el: s.id))
                }
            case .line(let l):
                ops.append(.line(
                    x1: f.x, y1: f.y, x2: f.x + f.w, y2: f.y + f.h,
                    stroke: SlideSchema.resolveColor(theme, l.stroke),
                    sw: l.strokeWidth, strokeOpacity: l.strokeOpacity,
                    dash: (l.dash ?? .solid).lengths(strokeWidth: l.strokeWidth),
                    startArrow: l.startArrow ?? false, endArrow: l.endArrow ?? false,
                    rot: rot, el: l.id
                ))
            case .image(let img):
                if let asset = deck.assets[img.asset] {
                    ops.append(.image(asset: img.asset, x: f.x, y: f.y, w: f.w, h: f.h, src: imageSource(for: img, asset: asset), alt: img.alt ?? asset.alt ?? "", opacity: img.opacity, rot: rot, el: img.id))
                } else {
                    ops.append(.rect(x: f.x, y: f.y, w: f.w, h: f.h, r: 0, fill: .solid("#E5E7EB"), fillOpacity: nil, stroke: nil, sw: 0, strokeOpacity: nil, dash: [], rot: rot, el: img.id))
                }
            case .text, .group:
                break
            }

            if let box = el.textBox {
                let res = layoutText(theme: theme, box: box, frame: textFrame(for: el), measure: measure, el: el.id, rot: rot)
                if res.overflow { overflow.insert(el.id) }
                ops.append(contentsOf: res.ops)
            }
        }

        for el in slide.elements {
            if case .group(let g) = el {
                for child in g.elements { lay(child) }
            } else {
                lay(el)
            }
        }
        return LaidSlide(ops: ops, overflow: overflow)
    }

    private static func splitKeepingTrailingSpace(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ch == " " {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex && s[s.index(before: end)] == " " {
            end = s.index(before: end)
        }
        return String(s[..<end])
    }
}

// MARK: - Arrange, Snap & Group Logic (parity with arrange.ts & group.ts)

public struct SlideBox: Sendable, Equatable {
    public var l: Double
    public var t: Double
    public var r: Double
    public var b: Double

    public init(l: Double, t: Double, r: Double, b: Double) {
        self.l = l
        self.t = t
        self.r = r
        self.b = b
    }

    public var frame: SlideFrame { SlideFrame(x: l, y: t, w: r - l, h: b - t) }
}

public enum SlideZOrder: String, Sendable { case forward, backward, front, back }
public enum SlideAlignOp: String, Sendable { case left, center, right, top, middle, bottom }

public enum SlideArrangeLogic: Sendable {
    public static func boxOf(_ f: SlideFrame) -> SlideBox {
        SlideBox(l: min(f.x, f.x + f.w), t: min(f.y, f.y + f.h), r: max(f.x, f.x + f.w), b: max(f.y, f.y + f.h))
    }

    public static func unionBox(_ frames: [SlideFrame]) -> SlideBox? {
        guard !frames.isEmpty else { return nil }
        let bs = frames.map(boxOf)
        return SlideBox(l: bs.map(\.l).min()!, t: bs.map(\.t).min()!, r: bs.map(\.r).max()!, b: bs.map(\.b).max()!)
    }

    public static func reorder(_ elements: [SlideElement], ids: Set<String>, op: SlideZOrder) -> [SlideElement] {
        var out = elements
        switch op {
        case .front:
            out = elements.filter { !ids.contains($0.id) } + elements.filter { ids.contains($0.id) }
        case .back:
            out = elements.filter { ids.contains($0.id) } + elements.filter { !ids.contains($0.id) }
        case .forward:
            if out.count >= 2 {
                for i in stride(from: out.count - 2, through: 0, by: -1) {
                    if ids.contains(out[i].id) && !ids.contains(out[i + 1].id) {
                        out.swapAt(i, i + 1)
                    }
                }
            }
        case .backward:
            if out.count >= 2 {
                for i in 1..<out.count {
                    if ids.contains(out[i].id) && !ids.contains(out[i - 1].id) {
                        out.swapAt(i, i - 1)
                    }
                }
            }
        }
        return out
    }

    public static func duplicate(_ elements: [SlideElement], ids: Set<String>, offset: Double = 40) -> (elements: [SlideElement], ids: [String]) {
        let src = elements.filter { ids.contains($0.id) }
        guard !src.isEmpty else { return (elements, []) }
        func clone(_ el: SlideElement) -> SlideElement {
            var copy = el
            var f = copy.frame
            f.x += offset
            f.y += offset
            copy.frame = f
            copy.placeholder = nil
            switch copy {
            case .text(var e): e.id = SlideSchema.newId(prefix: "e"); return .text(e)
            case .shape(var e): e.id = SlideSchema.newId(prefix: "e"); return .shape(e)
            case .line(var e): e.id = SlideSchema.newId(prefix: "e"); return .line(e)
            case .image(var e): e.id = SlideSchema.newId(prefix: "e"); return .image(e)
            case .group(var g):
                g.id = SlideSchema.newId(prefix: "e")
                g.elements = g.elements.map(clone)
                return .group(fitGroup(g))
            }
        }
        let copies = src.map(clone)
        let top = elements.enumerated().reduce(-1) { ids.contains($1.element.id) ? $1.offset : $0 }
        var out = elements
        out.insert(contentsOf: copies, at: top + 1)
        return (out, copies.map(\.id))
    }

    public static func align(_ frames: [String: SlideFrame], op: SlideAlignOp, to target: SlideBox) -> [String: SlideFrame] {
        var out: [String: SlideFrame] = [:]
        for (id, f) in frames {
            let b = boxOf(f)
            var dx = 0.0
            var dy = 0.0
            switch op {
            case .left: dx = target.l - b.l
            case .right: dx = target.r - b.r
            case .center: dx = (target.l + target.r) / 2 - (b.l + b.r) / 2
            case .top: dy = target.t - b.t
            case .bottom: dy = target.b - b.b
            case .middle: dy = (target.t + target.b) / 2 - (b.t + b.b) / 2
            }
            out[id] = SlideFrame(x: (f.x + dx).rounded(), y: (f.y + dy).rounded(), w: f.w, h: f.h)
        }
        return out
    }

    public static func distribute(_ frames: [String: SlideFrame], horizontal: Bool) -> [String: SlideFrame] {
        let items = frames.map { (id: $0.key, f: $0.value, b: boxOf($0.value)) }
        guard items.count >= 3 else { return frames }
        let lo: (SlideBox) -> Double = { horizontal ? $0.l : $0.t }
        let hi: (SlideBox) -> Double = { horizontal ? $0.r : $0.b }
        let mid: (SlideBox) -> Double = { (lo($0) + hi($0)) / 2 }
        let sorted = items.sorted { mid($0.b) < mid($1.b) }
        guard let first = sorted.first, let last = sorted.last else { return frames }
        let totalSpan = hi(last.b) - lo(first.b)
        let sumSize = sorted.reduce(0.0) { $0 + (hi($1.b) - lo($1.b)) }
        let gap = (totalSpan - sumSize) / Double(sorted.count - 1)

        var out = frames
        if gap >= 0 {
            var cursor = hi(first.b) + gap
            for item in sorted.dropFirst().dropLast() {
                let d = (cursor - lo(item.b)).rounded()
                out[item.id] = horizontal
                    ? SlideFrame(x: item.f.x + d, y: item.f.y, w: item.f.w, h: item.f.h)
                    : SlideFrame(x: item.f.x, y: item.f.y + d, w: item.f.w, h: item.f.h)
                cursor += (hi(item.b) - lo(item.b)) + gap
            }
        } else {
            let c0 = mid(first.b)
            let step = (mid(last.b) - c0) / Double(sorted.count - 1)
            for (idx, item) in sorted.enumerated() where idx > 0 && idx < sorted.count - 1 {
                let d = (c0 + Double(idx) * step - mid(item.b)).rounded()
                out[item.id] = horizontal
                    ? SlideFrame(x: item.f.x + d, y: item.f.y, w: item.f.w, h: item.f.h)
                    : SlideFrame(x: item.f.x, y: item.f.y + d, w: item.f.w, h: item.f.h)
            }
        }
        return out
    }

    public static func snapMove(box: SlideBox, slideWidth: Double, slideHeight: Double, others: [SlideFrame], threshold: Double = 14) -> (dx: Double, dy: Double, guidesX: [Double], guidesY: [Double]) {
        var tx = [0.0, slideWidth / 2, slideWidth]
        var ty = [0.0, slideHeight / 2, slideHeight]
        for f in others {
            let b = boxOf(f)
            tx.append(contentsOf: [b.l, (b.l + b.r) / 2, b.r])
            ty.append(contentsOf: [b.t, (b.t + b.b) / 2, b.b])
        }
        func bestDelta(_ vals: [Double], _ targets: [Double]) -> Double {
            var best: Double?
            for v in vals {
                for t in targets {
                    let d = t - v
                    if abs(d) <= threshold && (best == nil || abs(d) < abs(best!)) { best = d }
                }
            }
            return best ?? 0
        }
        let dx = bestDelta([box.l, (box.l + box.r) / 2, box.r], tx)
        let dy = bestDelta([box.t, (box.t + box.b) / 2, box.b], ty)
        let m = SlideBox(l: box.l + dx, t: box.t + dy, r: box.r + dx, b: box.b + dy)
        let gx = Array(Set(tx.filter { t in [m.l, (m.l + m.r) / 2, m.r].contains { abs($0 - t) < 0.5 } })).sorted()
        let gy = Array(Set(ty.filter { t in [m.t, (m.t + m.b) / 2, m.b].contains { abs($0 - t) < 0.5 } })).sorted()
        return (dx, dy, gx, gy)
    }

    public static func fitGroup(_ g: SlideGroupElement) -> SlideGroupElement {
        var out = g
        if let u = unionBox(g.elements.map(\.frame)) {
            out.frame = SlideFrame(
                x: (u.l * 100).rounded() / 100,
                y: (u.t * 100).rounded() / 100,
                w: ((u.r - u.l) * 100).rounded() / 100,
                h: ((u.b - u.t) * 100).rounded() / 100
            )
        }
        return out
    }

    public static func withFrame(_ element: SlideElement, frame: SlideFrame) -> SlideElement {
        guard case .group(var g) = element else {
            var copy = element
            copy.frame = frame
            return copy
        }
        let from = boxOf(g.frame)
        let dest = boxOf(frame)
        let sx = (from.r > from.l) ? (dest.r - dest.l) / (from.r - from.l) : 1
        let sy = (from.b > from.t) ? (dest.b - dest.t) / (from.b - from.t) : 1
        g.elements = g.elements.map { child in
            var c = child
            c.frame = SlideFrame(
                x: (dest.l + (c.frame.x - from.l) * sx).rounded(),
                y: (dest.t + (c.frame.y - from.t) * sy).rounded(),
                w: (c.frame.w * sx).rounded(),
                h: (c.frame.h * sy).rounded()
            )
            return c
        }
        return .group(fitGroup(g))
    }

    public static func groupElements(_ elements: [SlideElement], ids: Set<String>) -> (elements: [SlideElement], id: String)? {
        let picked = elements.filter { ids.contains($0.id) }
        var kids: [SlideElement] = picked.flatMap { el -> [SlideElement] in
            if case .group(let g) = el { return g.elements }
            return [el]
        }.map { c in
            var copy = c
            copy.placeholder = nil
            return copy
        }
        guard kids.count >= 2 else { return nil }
        let gid = SlideSchema.newId(prefix: "e")
        let group = SlideElement.group(fitGroup(SlideGroupElement(id: gid, frame: .init(x: 0, y: 0, w: 0, h: 0), elements: kids)))
        kids.removeAll()
        let top = elements.enumerated().reduce(-1) { ids.contains($1.element.id) ? $1.offset : $0 }
        var out: [SlideElement] = []
        for (i, el) in elements.enumerated() {
            if i == top { out.append(group) }
            else if !ids.contains(el.id) { out.append(el) }
        }
        return (out, gid)
    }

    public static func ungroupElements(_ elements: [SlideElement], ids: Set<String>) -> (elements: [SlideElement], ids: [String]) {
        var freed: [String] = []
        let out = elements.flatMap { el -> [SlideElement] in
            if ids.contains(el.id), case .group(let g) = el {
                freed.append(contentsOf: g.elements.map(\.id))
                return g.elements
            }
            return [el]
        }
        return (out, freed)
    }

    public static func removeDeep(_ elements: [SlideElement], ids: Set<String>) -> [SlideElement] {
        elements.flatMap { el -> [SlideElement] in
            if ids.contains(el.id) { return [] }
            if case .group(var g) = el, g.elements.contains(where: { ids.contains($0.id) }) {
                let kept = g.elements.filter { !ids.contains($0.id) }
                if kept.count >= 2 {
                    g.elements = kept
                    return [.group(fitGroup(g))]
                }
                return kept
            }
            return [el]
        }
    }

    public static func mapDeep(_ elements: [SlideElement], ids: Set<String>, _ transform: (SlideElement) -> SlideElement) -> [SlideElement] {
        elements.map { el in
            var n = ids.contains(el.id) ? transform(el) : el
            if case .group(var g) = n {
                let kids = g.elements.map { ids.contains($0.id) ? transform($0) : $0 }
                if kids != g.elements {
                    g.elements = kids
                    n = .group(fitGroup(g))
                }
            }
            return n
        }
    }

    public static func flatten(_ elements: [SlideElement]) -> [SlideElement] {
        elements.flatMap { el -> [SlideElement] in
            if case .group(let g) = el { return [el] + g.elements }
            return [el]
        }
    }
}

// MARK: - Slides Review Diff & 3-Way Merge (parity with web/lib/slides/review.ts)

public struct SlideReviewChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case added, removed, moved, modified, theme }
    public let id: Int
    public let kind: Kind
    public let slideId: String?
    public let before: Slide?
    public let after: Slide?
    public let position: Int
    public let title: String
    public let details: [String]
}

public enum SlideReviewLogic: Sendable {
    public static func deckChanges(base: SlideDeck, head: SlideDeck) -> [SlideReviewChange] {
        var out: [SlideReviewChange] = []
        var nextId = 0
        if base.theme != head.theme {
            let suffix = base.theme.name == head.theme.name ? " (colours or fonts changed)" : ""
            out.append(SlideReviewChange(id: nextId, kind: .theme, slideId: nil, before: nil, after: nil, position: 0, title: "Theme", details: ["\(base.theme.name) → \(head.theme.name)\(suffix)"]))
            nextId += 1
        }
        let baseById = Dictionary(uniqueKeysWithValues: base.slides.map { ($0.id, $0) })
        let headIds = Set(head.slides.map(\.id))
        let moved = movedIds(base: base.slides.map(\.id), head: head.slides.map(\.id))

        for (idx, s) in head.slides.enumerated() {
            guard let old = baseById[s.id] else {
                out.append(SlideReviewChange(id: nextId, kind: .added, slideId: s.id, before: nil, after: s, position: idx + 1, title: SlideSchema.slideTitle(s), details: ["New \(s.layout.label) slide"]))
                nextId += 1
                continue
            }
            let diff = old == s ? [] : describeSlideDiff(old, s)
            if !diff.isEmpty || moved.contains(s.id) {
                var details: [String] = []
                if moved.contains(s.id), let oldIdx = base.slides.firstIndex(where: { $0.id == s.id }) {
                    details.append("Moved from position \(oldIdx + 1) to \(idx + 1)")
                }
                details.append(contentsOf: diff)
                out.append(SlideReviewChange(id: nextId, kind: diff.isEmpty ? .moved : .modified, slideId: s.id, before: old, after: s, position: idx + 1, title: SlideSchema.slideTitle(s), details: details))
                nextId += 1
            }
        }
        for (idx, s) in base.slides.enumerated() where !headIds.contains(s.id) {
            out.append(SlideReviewChange(id: nextId, kind: .removed, slideId: s.id, before: s, after: nil, position: idx + 1, title: SlideSchema.slideTitle(s), details: ["Slide removed"]))
            nextId += 1
        }
        return out
    }

    public static func resolveDeck(base: SlideDeck, head: SlideDeck, changes: [SlideReviewChange], decisions: [Int: DocReviewDecision]) -> SlideDeck {
        var slides = head.slides
        var theme = head.theme
        let baseOrder = base.slides.map(\.id)
        for c in changes where decisions[c.id] == .reject {
            switch c.kind {
            case .theme:
                theme = base.theme
            case .added:
                slides.removeAll { $0.id == c.slideId }
            case .removed:
                if let before = c.before { slides = placeAfterPredecessor(slides: slides, slide: before, order: baseOrder) }
            case .modified, .moved:
                if let before = c.before {
                    slides = slides.map { $0.id == c.slideId ? before : $0 }
                    if c.details.contains(where: { $0.hasPrefix("Moved from") }) {
                        slides = placeAfterPredecessor(slides: slides, slide: before, order: baseOrder)
                    }
                }
            }
        }
        if slides.isEmpty, let first = base.slides.first { slides = [first] }
        var mergedAssets = base.assets
        for (k, v) in head.assets { mergedAssets[k] = v }
        return SlideDeck(schema: head.schema, size: head.size, theme: theme, assets: mergedAssets, slides: slides)
    }

    public static func mergeDecks(base: SlideDeck, mine: SlideDeck, theirs: SlideDeck) -> SlideDeck? {
        let mTheme = mine.theme != base.theme
        let tTheme = theirs.theme != base.theme
        if mTheme && tTheme && mine.theme != theirs.theme { return nil }

        let baseById = Dictionary(uniqueKeysWithValues: base.slides.map { ($0.id, $0) })
        func touched(_ d: SlideDeck) -> (ids: Set<String>, byId: [String: Slide]) {
            var ids = Set<String>()
            let byId = Dictionary(uniqueKeysWithValues: d.slides.map { ($0.id, $0) })
            for s in d.slides where baseById[s.id] != s { ids.insert(s.id) }
            for s in base.slides where byId[s.id] == nil { ids.insert(s.id) }
            return (ids, byId)
        }
        let m = touched(mine)
        let t = touched(theirs)
        for id in m.ids where t.ids.contains(id) && m.byId[id] != t.byId[id] { return nil }

        let mReordered = !movedIds(base: base.slides.map(\.id), head: mine.slides.map(\.id)).isEmpty
        let tReordered = !movedIds(base: base.slides.map(\.id), head: theirs.slides.map(\.id)).isEmpty
        if mReordered && tReordered { return nil }

        let (first, second, secondTouched) = mReordered ? (mine, theirs, t) : (theirs, mine, m)
        var slides = first.slides
        let secondOrder = second.slides.map(\.id)
        for id in secondTouched.ids {
            if let s = secondTouched.byId[id] {
                if let idx = slides.firstIndex(where: { $0.id == id }) {
                    slides[idx] = s
                } else {
                    slides = placeAfterPredecessor(slides: slides, slide: s, order: secondOrder)
                }
            } else {
                slides.removeAll { $0.id == id }
            }
        }
        var assets = theirs.assets
        for (k, v) in mine.assets { assets[k] = v }
        return SlideDeck(schema: theirs.schema, size: theirs.size, theme: mTheme ? mine.theme : theirs.theme, assets: assets, slides: slides)
    }

    private static func describeSlideDiff(_ a: Slide, _ b: Slide) -> [String] {
        var details: [String] = []
        if a.layout != b.layout { details.append("Layout: \(a.layout.label) → \(b.layout.label)") }
        if a.background != b.background { details.append("Background colour changed") }
        if (a.notes ?? "") != (b.notes ?? "") { details.append("Speaker notes changed") }
        if (a.hidden ?? false) != (b.hidden ?? false) { details.append((b.hidden ?? false) ? "Hidden in presentation" : "Shown in presentation") }
        let before = Dictionary(uniqueKeysWithValues: SlideArrangeLogic.flatten(a.elements).map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: SlideArrangeLogic.flatten(b.elements).map { ($0.id, $0) })
        for (id, el) in after {
            if let old = before[id] {
                if old != el {
                    details.append(old.plainText != el.plainText ? "Edited text" : "Moved or restyled element")
                }
            } else {
                details.append("Added element")
            }
        }
        for id in before.keys where after[id] == nil {
            details.append("Removed element")
        }
        return details.isEmpty ? ["Updated slide"] : details
    }

    private static func movedIds(base: [String], head: [String]) -> Set<String> {
        let common = Set(base).intersection(head)
        let a = base.filter { common.contains($0) }
        let b = head.filter { common.contains($0) }
        let n = a.count
        let m = b.count
        guard n > 0 && m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var keep = Set<String>()
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { keep.insert(a[i]); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return Set(a.filter { !keep.contains($0) })
    }

    private static func placeAfterPredecessor(slides: [Slide], slide: Slide, order: [String]) -> [Slide] {
        var rest = slides.filter { $0.id != slide.id }
        if let at = order.firstIndex(of: slide.id), at > 0 {
            for k in stride(from: at - 1, through: 0, by: -1) {
                if let idx = rest.firstIndex(where: { $0.id == order[k] }) {
                    rest.insert(slide, at: idx + 1)
                    return rest
                }
            }
        }
        rest.insert(slide, at: 0)
        return rest
    }
}

// MARK: - CoreGraphics Slide Drawer, Native PDF Exporter & Pure Swift PPTX Exporter

public enum SlideCGDrawer {
    /// Renders a laid slide into a CoreGraphics context in top-left y-down slide coordinates (0...1920, 0...1080).
    public static func draw(
        laid: LaidSlide,
        deck: SlideDeck,
        images: [String: CGImage],
        in ctx: CGContext,
        hideTextOf: String? = nil
    ) {
        for op in laid.ops {
            switch op {
            case .text(_, _, _, _, _, _, _, _, _, _, _, _, let el),
                 .highlight(_, _, _, _, _, _, let el):
                if let hide = hideTextOf, hide == el { continue }
            default:
                break
            }
            ctx.saveGState()
            applyRotation(op, in: ctx)

            switch op {
            case .rect(let x, let y, let w, let h, let r, let fill, let fo, let stroke, let sw, let so, let dash, _, _):
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let path = r > 0
                    ? CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                    : CGPath(rect: rect, transform: nil)
                paintPath(path, bounds: rect, fill: fill, fillOpacity: fo, stroke: stroke, sw: sw, strokeOpacity: so, dash: dash, in: ctx)

            case .ellipse(let x, let y, let w, let h, let fill, let fo, let stroke, let sw, let so, let dash, _, _):
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let path = CGPath(ellipseIn: rect, transform: nil)
                paintPath(path, bounds: rect, fill: fill, fillOpacity: fo, stroke: stroke, sw: sw, strokeOpacity: so, dash: dash, in: ctx)

            case .path(let segs, let box, let fill, let fo, let stroke, let sw, let so, let dash, _, _):
                let path = SlideShapeGeometry.cgPath(from: segs)
                paintPath(path, bounds: box.cgRect, fill: fill, fillOpacity: fo, stroke: stroke, sw: sw, strokeOpacity: so, dash: dash, in: ctx)

            case .line(let x1, let y1, let x2, let y2, let stroke, let sw, let so, let dash, let startArrow, let endArrow, _, _):
                let color = cgColor(stroke, alpha: so ?? 1)
                let dx = x2 - x1
                let dy = y2 - y1
                let len = max(1, hypot(dx, dy))
                let ux = dx / len
                let uy = dy / len
                let head = sw * 4
                let ax1 = startArrow ? x1 + ux * head : x1
                let ay1 = startArrow ? y1 + uy * head : y1
                let ax2 = endArrow ? x2 - ux * head : x2
                let ay2 = endArrow ? y2 - uy * head : y2
                ctx.setStrokeColor(color)
                ctx.setLineWidth(sw)
                if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: ax1, y: ay1))
                ctx.addLine(to: CGPoint(x: ax2, y: ay2))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setFillColor(color)
                if endArrow { drawArrowHead(tip: CGPoint(x: x2, y: y2), ux: ux, uy: uy, head: head, in: ctx) }
                if startArrow { drawArrowHead(tip: CGPoint(x: x1, y: y1), ux: -ux, uy: -uy, head: head, in: ctx) }

            case .image(let assetId, let x, let y, let w, let h, let src, _, let opacity, _, _):
                if let img = images[assetId], let asset = deck.assets[assetId] {
                    ctx.setAlpha(CGFloat(opacity ?? 1))
                    let dest = CGRect(x: x, y: y, width: w, height: h)
                    ctx.clip(to: dest)
                    let scale = w / max(1, src.w)
                    let drawRect = CGRect(x: x - src.x * scale, y: y - src.y * scale, width: Double(asset.w) * scale, height: Double(asset.h) * scale)
                    // Flip locally so CGImage draws right-side up in y-down coordinates.
                    ctx.translateBy(x: 0, y: drawRect.minY + drawRect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: drawRect)
                }

            case .highlight(let x, let y, let w, let h, let fill, _, _):
                ctx.setFillColor(cgColor(fill, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: w, height: h))

            case .text(let x, let y, let text, let slot, let bold, let italic, let size, let colorHex, let underline, let strike, let w, _, _):
                let font = SlideLayoutEngine.makeCTFont(slot: slot, bold: bold, italic: italic, size: size)
                let color = cgColor(colorHex, alpha: 1)
                let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
                let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(attr)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
                if underline {
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(size * 0.06)
                    let uy = y + size * 0.12
                    ctx.move(to: CGPoint(x: x, y: uy))
                    ctx.addLine(to: CGPoint(x: x + w, y: uy))
                    ctx.strokePath()
                }
                if strike {
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(size * 0.06)
                    let sy = y - size * SlideConstants.strikePosition
                    ctx.move(to: CGPoint(x: x, y: sy))
                    ctx.addLine(to: CGPoint(x: x + w, y: sy))
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }
    }

    private static func applyRotation(_ op: SlideDrawOp, in ctx: CGContext) {
        let rot: SlideRotation? = switch op {
        case .rect(_, _, _, _, _, _, _, _, _, _, _, let r, _): r
        case .ellipse(_, _, _, _, _, _, _, _, _, _, let r, _): r
        case .path(_, _, _, _, _, _, _, _, let r, _): r
        case .line(_, _, _, _, _, _, _, _, _, _, let r, _): r
        case .image(_, _, _, _, _, _, _, _, let r, _): r
        case .highlight(_, _, _, _, _, let r, _): r
        case .text(_, _, _, _, _, _, _, _, _, _, _, let r, _): r
        }
        guard let rot, rot.deg != 0 else { return }
        ctx.translateBy(x: rot.cx, y: rot.cy)
        ctx.rotate(by: rot.deg * .pi / 180)
        ctx.translateBy(x: -rot.cx, y: -rot.cy)
    }

    private static func paintPath(_ path: CGPath, bounds: CGRect, fill: SlideResolvedPaint?, fillOpacity: Double?, stroke: String?, sw: Double, strokeOpacity: Double?, dash: [Double], in ctx: CGContext) {
        if let fill {
            ctx.saveGState()
            let alpha = fillOpacity ?? 1
            switch fill {
            case .solid(let hex):
                ctx.setFillColor(cgColor(hex, alpha: alpha))
                ctx.addPath(path)
                ctx.fillPath()
            case .gradient(let angle, let start, let end):
                ctx.addPath(path)
                ctx.clip()
                let g = SlideSchema.gradientLine(angle: angle, x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height)
                let colors = [cgColor(start, alpha: alpha), cgColor(end, alpha: alpha)] as CFArray
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(grad, start: CGPoint(x: g.x1, y: g.y1), end: CGPoint(x: g.x2, y: g.y2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            ctx.restoreGState()
        }
        if let stroke, sw > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(cgColor(stroke, alpha: strokeOpacity ?? 1))
            ctx.setLineWidth(sw)
            ctx.setLineJoin(.miter)
            if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private static func drawArrowHead(tip: CGPoint, ux: Double, uy: Double, head: Double, in ctx: CGContext) {
        let bx = tip.x - ux * head
        let by = tip.y - uy * head
        let px = -uy * head * 0.6
        let py = ux * head * 0.6
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: bx + px, y: by + py))
        ctx.addLine(to: CGPoint(x: bx - px, y: by - py))
        ctx.closePath()
        ctx.fillPath()
    }

    public static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let (r, g, b, a) = SlideSchema.parseHexRGBA(hex)
        return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a * alpha])!
    }
}

// MARK: - Native PDF & PPTX Exporters

public enum SlideExporters {
    /// Renders every visible slide to a crisp vector PDF (960 × 540 pt per page) using `CGPDFContext`.
    public static func exportPDF(deck: SlideDeck, images: [String: CGImage]) -> Data {
        let k = 0.5
        let pageW = deck.size.w * k
        let pageH = deck.size.h * k
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        let shown = deck.slides.filter { !($0.hidden ?? false) }
        for slide in (shown.isEmpty ? deck.slides : shown) {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Flip PDF y-up into slide y-down and scale 1920×1080 -> 960×540 pt.
            ctx.translateBy(x: 0, y: pageH)
            ctx.scaleBy(x: k, y: -k)
            let laid = SlideLayoutEngine.layoutSlide(deck: deck, slide: slide)
            SlideCGDrawer.draw(laid: laid, deck: deck, images: images, in: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Builds a native, editable PowerPoint `.pptx` OpenXML archive (with `prstGeom` shapes,
    /// editable text runs, bullets, `a:gradFill` gradients, cropped media, speaker notes, and groups).
    public static func exportPPTX(deck: SlideDeck, assetBytes: [String: Data]) -> Data {
        let emuPerUnit = 6350 // 1920 * 6350 = 12,192,000 EMU = 13.333 in (16:9 widescreen)
        func emu(_ u: Double) -> Int { Int((u * Double(emuPerUnit)).rounded()) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        func hex6(_ ref: String?, fallback: SlideThemeColorKey = .text) -> String {
            let h = SlideSchema.resolveColor(deck.theme, ref, fallback: fallback)
            return String(h.dropFirst().prefix(6))
        }
        func alphaTag(_ opacity: Double?) -> String {
            guard let opacity, opacity < 1 else { return "" }
            return "<a:alpha val=\"\(Int((max(0, opacity) * 100000).rounded()))\"/>"
        }
        func fillXML(_ fill: SlideFill?, opacity: Double?, fallback: SlideThemeColorKey = .text) -> String {
            guard let fill else { return "<a:noFill/>" }
            switch SlideSchema.resolvePaint(deck.theme, fill, fallback: fallback) {
            case .solid(let hex):
                return "<a:solidFill><a:srgbClr val=\"\(String(hex.dropFirst().prefix(6)))\">\(alphaTag(opacity))</a:srgbClr></a:solidFill>"
            case .gradient(let angle, let start, let end):
                let ang = Int((angle.truncatingRemainder(dividingBy: 360) * 60000).rounded())
                return """
                <a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="\(String(start.dropFirst().prefix(6)))">\(alphaTag(opacity))</a:srgbClr></a:gs><a:gs pos="100000"><a:srgbClr val="\(String(end.dropFirst().prefix(6)))">\(alphaTag(opacity))</a:srgbClr></a:gs></a:gsLst><a:lin ang="\(ang)" scaled="0"/></a:gradFill>
                """
            }
        }
        func textBodyXML(_ box: SlideTextBox) -> String {
            let anchor: String = switch box.valign {
            case "middle": "ctr"
            case "bottom": "b"
            default: "t"
            }
            let inset = emu(SlideConstants.inset)
            let paras = box.paragraphs.map { p -> String in
                let algn: String = switch p.align {
                case "center": "ctr"
                case "right": "r"
                case "justify": "just"
                default: "l"
                }
                let lvl = p.bullet != nil ? (p.level ?? 0) : 0
                let spcPts = Int((SlideLayoutEngine.lineHeight(for: p) * 50).rounded())
                let spcBef = (p.spaceBefore ?? 0) > 0 ? "<a:spcBef><a:spcPts val=\"\(Int(((p.spaceBefore ?? 0) * 50).rounded()))\"/></a:spcBef>" : ""
                let bulletXML: String = switch p.bullet {
                case "disc": "<a:buChar char=\"•\"/>"
                case "number": "<a:buAutoNum type=\"arabicPeriod\"/>"
                default: "<a:buNone/>"
                }
                let marL = p.bullet != nil ? " marL=\"\(emu(SlideConstants.bulletIndent * Double(lvl + 1)))\" indent=\"-\(emu(SlideConstants.bulletIndent))\"" : ""
                let runs = p.runs.map { r -> String in
                    let sz = Int((r.size * 50).rounded())
                    let b = (r.bold ?? false) ? " b=\"1\"" : ""
                    let i = (r.italic ?? false) ? " i=\"1\"" : ""
                    let u = (r.underline ?? false) ? " u=\"sng\"" : ""
                    let s = (r.strike ?? false) ? " strike=\"sngStrike\"" : ""
                    let face = SlideSchema.slotOf(deck.theme, font: r.font).officeFontName
                    let hl = r.highlight.map { "<a:highlight><a:srgbClr val=\"\(hex6($0))\"/></a:highlight>" } ?? ""
                    return "<a:r><a:rPr lang=\"en-US\" sz=\"\(sz)\"\(b)\(i)\(u)\(s)><a:solidFill><a:srgbClr val=\"\(hex6(r.color))\"/></a:solidFill>\(hl)<a:latin typeface=\"\(face)\"/></a:rPr><a:t>\(esc(r.text))</a:t></a:r>"
                }.joined()
                return "<a:p><a:pPr algn=\"\(algn)\" lvl=\"\(lvl)\"\(marL)><a:lnSpc><a:spcPts val=\"\(spcPts)\"/></a:lnSpc>\(spcBef)\(bulletXML)</a:pPr>\(runs)</a:p>"
            }.joined()
            return "<p:txBody><a:bodyPr wrap=\"square\" lIns=\"\(inset)\" tIns=\"\(inset)\" rIns=\"\(inset)\" bIns=\"\(inset)\" anchor=\"\(anchor)\"/><a:lstStyle/>\(paras)</p:txBody>"
        }

        var entries: [MinimalZipWriter.Entry] = []
        var contentOverrides = ""
        var presSldIds = ""
        var presRels = ""
        var mediaIndex = 1
        var mediaMap: [String: (path: String, ext: String)] = [:]

        for (assetId, bytes) in assetBytes.sorted(by: { $0.key < $1.key }) {
            let mime = deck.assets[assetId]?.mime ?? "image/png"
            let ext = mime.contains("jpeg") ? "jpeg" : "png"
            let mediaPath = "ppt/media/image\(mediaIndex).\(ext)"
            mediaIndex += 1
            mediaMap[assetId] = (mediaPath, ext)
            entries.append(.init(path: mediaPath, data: bytes))
        }

        for (idx, slide) in deck.slides.enumerated() {
            let n = idx + 1
            let rId = "rId\(n + 2)"
            presSldIds += "<p:sldId id=\"\(255 + n)\" r:id=\"\(rId)\"/>"
            presRels += "<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
            contentOverrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"

            var slideRels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            var nextSlideRel = 2
            var nextSpId = 2

            func emitLeaf(_ el: SlideElement) -> String {
                if el.isImageSlot { return "" }
                let spId = nextSpId
                nextSpId += 1
                let f = el.frame
                let rotAttr = (el.rotation ?? 0) != 0 ? " rot=\"\(Int(((el.rotation ?? 0) * 60000).rounded()))\"" : ""
                let xfrm = "<a:xfrm\(rotAttr)><a:off x=\"\(emu(f.x))\" y=\"\(emu(f.y))\"/><a:ext cx=\"\(emu(max(1, abs(f.w))))\" cy=\"\(emu(max(1, abs(f.h))))\"/></a:xfrm>"

                switch el {
                case .text(let t):
                    return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(spId)\" name=\"\(esc(t.id))\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\(textBodyXML(t.textBox))</p:sp>"

                case .shape(let s):
                    let fill = fillXML(s.fill, opacity: s.fillOpacity)
                    let ln: String = {
                        guard let st = s.stroke, let sw = s.strokeWidth, sw > 0 else { return "<a:ln><a:noFill/></a:ln>" }
                        let dash = "<a:prstDash val=\"\((s.dash ?? .solid).pptxValue)\"/>"
                        return "<a:ln w=\"\(emu(sw))\"><a:solidFill><a:srgbClr val=\"\(hex6(st))\">\(alphaTag(s.strokeOpacity))</a:srgbClr></a:solidFill>\(dash)</a:ln>"
                    }()
                    let tx = s.text.map(textBodyXML) ?? "<p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody>"
                    return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(spId)\" name=\"\(esc(s.id))\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm)<a:prstGeom prst=\"\(s.shape.rawValue)\"><a:avLst/></a:prstGeom>\(fill)\(ln)</p:spPr>\(tx)</p:sp>"

                case .line(let l):
                    let flipH = l.frame.w < 0 ? " flipH=\"1\"" : ""
                    let flipV = l.frame.h < 0 ? " flipV=\"1\"" : ""
                    let lxfrm = "<a:xfrm\(rotAttr)\(flipH)\(flipV)><a:off x=\"\(emu(min(f.x, f.x + f.w)))\" y=\"\(emu(min(f.y, f.y + f.h)))\"/><a:ext cx=\"\(emu(max(1, abs(f.w))))\" cy=\"\(emu(max(1, abs(f.h))))\"/></a:xfrm>"
                    let head = (l.startArrow ?? false) ? "<a:headEnd type=\"triangle\" w=\"med\" len=\"med\"/>" : ""
                    let tail = (l.endArrow ?? false) ? "<a:tailEnd type=\"triangle\" w=\"med\" len=\"med\"/>" : ""
                    let dash = "<a:prstDash val=\"\((l.dash ?? .solid).pptxValue)\"/>"
                    return "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(spId)\" name=\"\(esc(l.id))\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr>\(lxfrm)<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom><a:ln w=\"\(emu(l.strokeWidth))\"><a:solidFill><a:srgbClr val=\"\(hex6(l.stroke))\">\(alphaTag(l.strokeOpacity))</a:srgbClr></a:solidFill>\(dash)\(head)\(tail)</a:ln></p:spPr></p:cxnSp>"

                case .image(let img):
                    guard let media = mediaMap[img.asset] else { return "" }
                    let imgRelId = "rId\(nextSlideRel)"
                    nextSlideRel += 1
                    slideRels += "<Relationship Id=\"\(imgRelId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/\((media.path as NSString).lastPathComponent)\"/>"
                    return "<p:pic><p:nvPicPr><p:cNvPr id=\"\(spId)\" name=\"\(esc(img.id))\" descr=\"\(esc(img.alt ?? ""))\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(imgRelId)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"

                case .group(let g):
                    let ch = g.elements.map(emitLeaf).joined()
                    let gx = emu(g.frame.x), gy = emu(g.frame.y), gw = emu(max(1, g.frame.w)), gh = emu(max(1, g.frame.h))
                    return "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(spId)\" name=\"\(esc(g.id))\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"\(gx)\" y=\"\(gy)\"/><a:ext cx=\"\(gw)\" cy=\"\(gh)\"/><a:chOff x=\"\(gx)\" y=\"\(gy)\"/><a:chExt cx=\"\(gw)\" cy=\"\(gh)\"/></a:xfrm></p:grpSpPr>\(ch)</p:grpSp>"
                }
            }

            let shapesXML = slide.elements.map(emitLeaf).joined()
            let bgFill = fillXML(slide.background?.color ?? .solid("background"), opacity: nil, fallback: .background)
            let showAttr = (slide.hidden ?? false) ? " show=\"0\"" : ""

            if let notes = slide.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let noteRelId = "rId\(nextSlideRel)"
                nextSlideRel += 1
                slideRels += "<Relationship Id=\"\(noteRelId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide\" Target=\"../notesSlides/notesSlide\(n).xml\"/>"
                contentOverrides += "<Override PartName=\"/ppt/notesSlides/notesSlide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml\"/>"
                let noteXML = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(esc(notes))</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>
                """
                entries.append(.init(path: "ppt/notesSlides/notesSlide\(n).xml", utf8: noteXML))
                entries.append(.init(path: "ppt/notesSlides/_rels/notesSlide\(n).xml.rels", utf8: """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide\(n).xml"/></Relationships>
                """))
            }

            let slideXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"\(showAttr)><p:cSld><p:bg><p:bgPr>\(bgFill)<a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\(shapesXML)</p:spTree></p:cSld></p:sld>
            """
            entries.append(.init(path: "ppt/slides/slide\(n).xml", utf8: slideXML))
            entries.append(.init(path: "ppt/slides/_rels/slide\(n).xml.rels", utf8: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(slideRels)</Relationships>
            """))
        }

        let presXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(presSldIds)</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
        let presRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>\(presRels)</Relationships>
        """
        let masterXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """
        let layoutXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld></p:sldLayout>
        """
        let themeXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Vesper"><a:themeElements><a:clrScheme name="Vesper"><a:dk1><a:srgbClr val="111418"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2328"/></a:dk2><a:lt2><a:srgbClr val="F3F5F9"/></a:lt2><a:accent1><a:srgbClr val="3B6FE0"/></a:accent1><a:accent2><a:srgbClr val="E8A33D"/></a:accent2><a:accent3><a:srgbClr val="4CB782"/></a:accent3><a:accent4><a:srgbClr val="8B9CFF"/></a:accent4><a:accent5><a:srgbClr val="D1495B"/></a:accent5><a:accent6><a:srgbClr val="5F6673"/></a:accent6><a:hlink><a:srgbClr val="3B6FE0"/></a:hlink><a:folHlink><a:srgbClr val="7B4FA0"/></a:folHlink></a:clrScheme><a:fontScheme name="Vesper"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Vesper"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(contentOverrides)</Types>
        """
        let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """

        entries.insert(.init(path: "[Content_Types].xml", utf8: contentTypesXML), at: 0)
        entries.insert(.init(path: "_rels/.rels", utf8: rootRelsXML), at: 1)
        entries.append(.init(path: "ppt/presentation.xml", utf8: presXML))
        entries.append(.init(path: "ppt/_rels/presentation.xml.rels", utf8: presRelsXML))
        entries.append(.init(path: "ppt/slideMasters/slideMaster1.xml", utf8: masterXML))
        entries.append(.init(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", utf8: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """))
        entries.append(.init(path: "ppt/slideLayouts/slideLayout1.xml", utf8: layoutXML))
        entries.append(.init(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", utf8: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """))
        entries.append(.init(path: "ppt/theme/theme1.xml", utf8: themeXML))
        return MinimalZipWriter.archive(entries)
    }
}
