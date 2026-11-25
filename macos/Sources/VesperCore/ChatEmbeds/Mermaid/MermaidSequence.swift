import CoreGraphics
import Foundation

/// `sequenceDiagram`: participants and actors (with aliases), every message arrow kind, notes,
/// activations, `loop`/`alt`/`opt`/`par`/`critical`/`break`/`rect` blocks and `autonumber`.
/// The layout is a deterministic column-and-row sweep, the way mermaid.js lays these out, so no
/// graph engine is involved.
struct MermaidSequence {
    struct Participant {
        var id: String
        var label: String
        var isActor: Bool
    }

    enum Event {
        case message(from: Int, to: Int, text: String, line: MessageLine, start: MermaidMarker?, end: MermaidMarker?, activate: Bool, deactivate: Bool)
        case note(over: [Int], side: NoteSide, text: String)
        case activate(Int)
        case deactivate(Int)
        case blockStart(kind: String, label: String)
        case blockDivider(kind: String, label: String)
        case blockEnd
    }

    enum MessageLine { case solid, dotted }
    enum NoteSide { case left, right, over }

    var participants: [Participant] = []
    var events: [Event] = []
    var autonumber = false
    var title: String?

    // MARK: Parsing

    private static let arrows: [(String, MessageLine, MermaidMarker?, MermaidMarker?)] = [
        ("<<-->>", .dotted, .arrow, .arrow), ("<<->>", .solid, .arrow, .arrow),
        ("-->>", .dotted, nil, .arrow), ("->>", .solid, nil, .arrow),
        ("--x", .dotted, nil, .cross), ("-x", .solid, nil, .cross),
        ("--)", .dotted, nil, .openArrow), ("-)", .solid, nil, .openArrow),
        ("-->", .dotted, nil, nil), ("->", .solid, nil, nil),
    ]

    private static let blockKinds: Set<String> = ["loop", "alt", "opt", "par", "critical", "break", "rect"]
    private static let dividerKinds: Set<String> = ["else", "and", "option"]

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidSequence {
        var s = MermaidSequence()
        s.title = doc.title
        // Each open block remembers whether it's a drawn block or a `box` (which only groups).
        var open: [(drawn: Bool, line: Int)] = []
        for stmt in MermaidScan.statements(doc.lines, headerRest: doc.headerRest, headerLine: doc.headerLine) {
            let t = stmt.text
            let (word, rest) = MermaidScan.firstWord(t)
            let lower = word.lowercased()
            if lower == "end" {
                guard let top = open.popLast() else { throw .syntax(line: stmt.number, message: "\"end\" without a block") }
                if top.drawn { s.events.append(.blockEnd) }
                continue
            }
            if lower == "box" { open.append((false, stmt.number)); continue }
            if blockKinds.contains(lower) {
                open.append((true, stmt.number))
                s.events.append(.blockStart(kind: lower, label: lower == "rect" ? "" : MermaidText.collapse(rest)))
                continue
            }
            if dividerKinds.contains(lower) {
                guard open.last?.drawn == true else { throw .syntax(line: stmt.number, message: "\"\(word)\" outside a block") }
                s.events.append(.blockDivider(kind: lower, label: MermaidText.collapse(rest)))
                continue
            }
            switch lower {
            case "autonumber": s.autonumber = !(rest.lowercased() == "off"); continue
            case "title": s.title = rest.hasPrefix(":") ? String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) : rest; continue
            case "participant", "actor":
                try s.declare(rest, actor: lower == "actor", line: stmt.number)
                continue
            case "create":
                let (kind, decl) = MermaidScan.firstWord(rest)
                try s.declare(decl, actor: kind.lowercased() == "actor", line: stmt.number)
                continue
            case "destroy", "links", "link", "properties", "details": continue
            case "activate": s.events.append(.activate(s.index(rest))); continue
            case "deactivate": s.events.append(.deactivate(s.index(rest))); continue
            case "note": try s.parseNote(rest, line: stmt.number); continue
            default: break
            }
            if t.hasPrefix("accTitle") || t.hasPrefix("accDescr") { continue }
            try s.parseMessage(t, line: stmt.number)
        }
        if let top = open.last { throw .syntax(line: top.line, message: "block isn't closed with end") }
        guard s.events.count <= NativeMermaid.maxRows, s.participants.count <= 60 else { throw .tooLarge }
        guard !s.participants.isEmpty else { throw .syntax(line: doc.headerLine, message: "the diagram has no participants") }
        return s
    }

    /// `Alice`, `A as Alice`, `"Long name" as L`.
    mutating func declare(_ decl: String, actor: Bool, line: Int) throws(NativeMermaidError) {
        var id = decl, label: String?
        if let r = decl.range(of: " as ") {
            id = String(decl[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            label = String(decl[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        id = MermaidText.unquote(id)
        guard !id.isEmpty else { throw .syntax(line: line, message: "a participant needs a name") }
        let i = index(id)
        participants[i].isActor = actor
        if let label { participants[i].label = MermaidText.unquote(label) }
    }

    /// The participant's column, adding it on first mention as mermaid does.
    mutating func index(_ rawID: String) -> Int {
        let id = MermaidText.unquote(rawID)
        if let i = participants.firstIndex(where: { $0.id == id }) { return i }
        participants.append(Participant(id: id, label: id, isActor: false))
        return participants.count - 1
    }

    mutating func parseNote(_ rest: String, line: Int) throws(NativeMermaidError) {
        guard let colon = rest.firstIndex(of: ":") else { throw .syntax(line: line, message: "a note needs \": text\"") }
        let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let place = rest[..<colon].trimmingCharacters(in: .whitespaces)
        let side: NoteSide
        var targets: String
        if let r = MermaidScan.keyword(place, "right of") { side = .right; targets = r }
        else if let r = MermaidScan.keyword(place, "left of") { side = .left; targets = r }
        else if let r = MermaidScan.keyword(place, "over") { side = .over; targets = r }
        else { throw .syntax(line: line, message: "a note goes left of, right of or over a participant") }
        targets = targets.trimmingCharacters(in: .whitespaces)
        let ids = targets.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw .syntax(line: line, message: "a note needs a participant") }
        events.append(.note(over: ids.map { index($0) }, side: side, text: text))
    }

    mutating func parseMessage(_ t: String, line: Int) throws(NativeMermaidError) {
        let (head, text): (Substring, String) = {
            guard let colon = t.firstIndex(of: ":") else { return (t[...], "") }
            return (t[..<colon], String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }()
        // The earliest arrow wins; at one position the longest spelling does (the table is ordered so).
        var best: (range: Range<Substring.Index>, arrow: (String, MessageLine, MermaidMarker?, MermaidMarker?))?
        for a in Self.arrows {
            guard let r = head.range(of: a.0) else { continue }
            if best == nil || r.lowerBound < best!.range.lowerBound { best = (r, a) }
        }
        guard let (range, arrow) = best else { throw .syntax(line: line, message: "expected a message like A->>B: text") }
        let from = head[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        var to = head[range.upperBound...].trimmingCharacters(in: .whitespaces)
        var activate = false, deactivate = false
        if to.hasPrefix("+") { activate = true; to = String(to.dropFirst()).trimmingCharacters(in: .whitespaces) }
        else if to.hasPrefix("-") { deactivate = true; to = String(to.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !from.isEmpty, !to.isEmpty, !from.contains(" ") || from.hasPrefix("\""), !to.contains(" ") || to.hasPrefix("\"") else {
            throw .syntax(line: line, message: "expected a message like A->>B: text")
        }
        let a = index(from), b = index(to)
        events.append(.message(from: a, to: b, text: text, line: arrow.1, start: arrow.2, end: arrow.3,
                               activate: activate, deactivate: deactivate))
    }

    // MARK: Layout and drawing

    static let boxPadX = 14.0
    static let boxPadY = 10.0
    static let minBoxWidth = 90.0
    static let gap = 36.0
    static let actorFigure = 34.0

    func draw(_ theme: MermaidTheme) -> MermaidDrawing {
        let lh = MermaidText.lineHeight()
        let small = MermaidText.lineHeight(MermaidText.smallSize)
        let labels = participants.map { MermaidText.lines($0.label) }
        let widths = labels.map { max(MermaidText.width(lines: $0) + Self.boxPadX * 2, Self.minBoxWidth) }
        let boxHeight = (labels.map { Double($0.count) }.max() ?? 1) * lh + Self.boxPadY * 2
        let headerHeight = participants.contains(where: \.isActor) ? max(boxHeight, Self.actorFigure + lh + 6) : boxHeight

        // Columns: neighbours clear each other, then every message and note pushes its span wide
        // enough for its text.
        var centers = [widths[0] / 2]
        for i in 1..<max(1, participants.count) {
            centers.append(centers[i - 1] + widths[i - 1] / 2 + Self.gap + widths[i] / 2)
        }
        func require(_ a: Int, _ b: Int, _ distance: Double) {
            let lo = min(a, b), hi = max(a, b)
            let have = centers[hi] - centers[lo]
            guard have < distance else { return }
            for k in hi..<centers.count { centers[k] += distance - have }
        }
        var rightRoom = widths.last.map { $0 / 2 } ?? 0
        var leftRoom = widths.first.map { $0 / 2 } ?? 0
        let numberRoom = autonumber ? 22.0 : 0
        for e in events {
            switch e {
            case let .message(a, b, text, _, _, _, _, _):
                let w = MermaidText.width(lines: MermaidText.lines(text)) + 24 + numberRoom
                if a == b {
                    let need = w + 30
                    if a + 1 < centers.count { require(a, a + 1, need) } else { rightRoom = max(rightRoom, need) }
                } else {
                    require(a, b, w)
                }
            case let .note(over, side, text):
                let w = MermaidText.width(lines: MermaidText.lines(text), size: MermaidText.smallSize) + 20
                let lo = over.min() ?? 0, hi = over.max() ?? 0
                switch side {
                case .over where lo != hi: require(lo, hi, w - 40)
                case .over: break
                case .right:
                    if hi + 1 < centers.count { require(hi, hi + 1, w + 20) } else { rightRoom = max(rightRoom, w + 14) }
                case .left:
                    if lo > 0 { require(lo - 1, lo, w + 20) } else { leftRoom = max(leftRoom, w + 14) }
                }
            default: continue
            }
        }
        // Notes over one participant can be wider than its column.
        for e in events {
            if case let .note(over, .over, text) = e, over.count == 1 || Set(over).count == 1 {
                let w = MermaidText.width(lines: MermaidText.lines(text), size: MermaidText.smallSize) + 20
                if over[0] == 0 { leftRoom = max(leftRoom, w / 2) }
                if over[0] == centers.count - 1 { rightRoom = max(rightRoom, w / 2) }
            }
        }
        let shift = leftRoom + 8
        centers = centers.map { $0 + shift }
        let contentWidth = (centers.last ?? 0) + rightRoom + 8

        // Rows.
        var svg = MermaidSVG(theme: theme)
        // Messages and notes draw over blocks and lifelines, whose extents are only known once
        // every row is placed, so they're queued here.
        var foreground: [(inout MermaidSVG) -> Void] = []
        var y = headerHeight + 20
        var active: [[Double]] = Array(repeating: [], count: participants.count)
        var activations: [(Int, Double, Double, Int)] = []
        var blocks: [(kind: String, label: String, top: Double, dividers: [(Double, String)], lo: Int, hi: Int)] = []
        var drawnBlocks: [(kind: String, label: String, top: Double, bottom: Double, dividers: [(Double, String)], lo: Int, hi: Int, depth: Int)] = []
        var number = 0
        func touch(_ cols: [Int]) {
            for k in blocks.indices {
                blocks[k].lo = min(blocks[k].lo, cols.min() ?? blocks[k].lo)
                blocks[k].hi = max(blocks[k].hi, cols.max() ?? blocks[k].hi)
            }
        }
        func edgeX(_ p: Int, towards other: Double) -> Double {
            let depth = Double(active[p].count)
            guard depth > 0 else { return centers[p] }
            return centers[p] + (other >= centers[p] ? 1 : -1) * (5 * depth)
        }
        for e in events {
            switch e {
            case let .message(a, b, text, line, start, end, activate, deactivate):
                touch([a, b])
                let lines = MermaidText.lines(text).filter { !$0.isEmpty }
                number += 1
                let dash = line == .dotted ? "5 4" : nil
                let labelTop = y
                y += lh * Double(lines.count) + 4
                let showNumber = autonumber, n = number, rowY = y
                if a == b {
                    let x = edgeX(a, towards: centers[a] + 1)
                    let pts = [CGPoint(x: x, y: rowY), CGPoint(x: x + 40, y: rowY), CGPoint(x: x + 40, y: rowY + 22), CGPoint(x: x, y: rowY + 22)]
                    foreground.append { s in
                        s.edge(pts, stroke: theme.text, width: 1.5, dash: dash, start: start, end: end)
                        s.lines(lines, x: x + 46, top: labelTop, anchor: "start")
                        if showNumber { drawNumber(&s, n, at: CGPoint(x: x, y: rowY), theme: theme) }
                    }
                    y += 22
                } else {
                    let x1 = edgeX(a, towards: centers[b])
                    if activate { active[b].append(rowY) }
                    let x2 = edgeX(b, towards: centers[a])
                    let mid = (centers[a] + centers[b]) / 2
                    foreground.append { s in
                        s.edge([CGPoint(x: x1, y: rowY), CGPoint(x: x2, y: rowY)], stroke: theme.text, width: 1.5, dash: dash, start: start, end: end)
                        s.lines(lines, x: mid, top: labelTop)
                        if showNumber { drawNumber(&s, n, at: CGPoint(x: x1, y: rowY), theme: theme) }
                    }
                }
                // `A->>+B` activates the receiver; `B-->>-A` ends the sender's activation, as in mermaid.
                if deactivate, let top = active[a].popLast() { activations.append((a, top, y, active[a].count)) }
                y += 18
            case let .note(over, side, text):
                touch(over)
                let lines = MermaidText.lines(text)
                let w = MermaidText.width(lines: lines, size: MermaidText.smallSize) + 20
                let h = small * Double(lines.count) + 12
                let lo = over.min() ?? 0, hi = over.max() ?? 0
                let r: CGRect
                switch side {
                case .over:
                    let left = centers[lo] - (lo == hi ? 0 : 30), right = centers[hi] + (lo == hi ? 0 : 30)
                    let width = max(w, right - left)
                    r = CGRect(x: (left + right) / 2 - width / 2, y: y, width: width, height: h)
                case .right: r = CGRect(x: centers[hi] + 12, y: y, width: w, height: h)
                case .left: r = CGRect(x: centers[lo] - 12 - w, y: y, width: w, height: h)
                }
                foreground.append { s in
                    s.rect(r, rx: 2, fill: theme.noteFill, stroke: theme.noteStroke, strokeWidth: 1)
                    s.lines(lines, x: r.midX, top: r.minY + 6, size: MermaidText.smallSize)
                }
                y += h + 14
            case let .activate(p):
                active[p].append(y - 10)
            case let .deactivate(p):
                if let s = active[p].popLast() { activations.append((p, s, y - 10, active[p].count)) }
            case let .blockStart(kind, label):
                blocks.append((kind, label, y, [], Int.max, Int.min))
                y += kind == "rect" ? 10 : lh + 14
            case let .blockDivider(_, label):
                guard !blocks.isEmpty else { continue }
                blocks[blocks.count - 1].dividers.append((y, label))
                y += lh + 10
            case .blockEnd:
                guard let b = blocks.popLast() else { continue }
                drawnBlocks.append((b.kind, b.label, b.top, y, b.dividers, b.lo, b.hi, blocks.count))
                // Outer blocks span what their inner ones did.
                if b.lo <= b.hi { touch([b.lo, b.hi]) }
                y += 12
            }
        }
        for p in active.indices {
            while let s = active[p].popLast() { activations.append((p, s, y - 6, active[p].count)) }
        }
        let lifelineEnd = y + 6
        let totalHeight = lifelineEnd + headerHeight

        let size = svg.beginDiagram(content: CGSize(width: contentWidth, height: totalHeight), title: title)
        // Block frames behind everything, outer first; their tags and labels go over the activation
        // bars (drawn later), which would otherwise cover them where a bar crosses the label.
        var blockLabels: [(inout MermaidSVG) -> Void] = []
        for b in drawnBlocks.sorted(by: { $0.depth < $1.depth }) {
            let lo = b.lo <= b.hi ? b.lo : 0, hi = b.lo <= b.hi ? b.hi : participants.count - 1
            let inset = Double(b.depth) * 6
            let left = centers[lo] - widths[lo] / 2 + inset - 4
            let right = centers[hi] + widths[hi] / 2 - inset + 4
            let r = CGRect(x: left, y: b.top, width: right - left, height: b.bottom - b.top)
            if b.kind == "rect" {
                svg.rect(r, rx: 3, fill: theme.series(Int(b.depth) + 1), fillOpacity: 0.1)
                continue
            }
            svg.rect(r, fill: "none", stroke: theme.muted, strokeWidth: 1)
            for (dy, _) in b.dividers {
                svg.line(CGPoint(x: r.minX, y: dy), CGPoint(x: r.maxX, y: dy), stroke: theme.muted, dash: "4 3")
            }
            blockLabels.append { svg in
            let tag = b.kind
            let tagW = MermaidText.width(tag, size: MermaidText.smallSize, bold: true) + 16
            svg.polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + tagW, y: r.minY), CGPoint(x: r.minX + tagW, y: r.minY + small + 2),
                         CGPoint(x: r.minX + tagW - 6, y: r.minY + small + 8), CGPoint(x: r.minX, y: r.minY + small + 8)],
                        fill: theme.nodeFill, stroke: theme.muted, strokeWidth: 1)
            svg.text(tag, x: r.minX + 8, y: r.minY + (small + 8) / 2, anchor: "start", size: MermaidText.smallSize, bold: true)
            if !b.label.isEmpty { svg.text("[\(b.label)]", x: r.minX + tagW + 8, y: r.minY + (small + 8) / 2, anchor: "start", size: MermaidText.smallSize, bold: true) }
            for (dy, label) in b.dividers where !label.isEmpty {
                svg.text("[\(label)]", x: r.midX, y: dy + lh / 2 + 3, size: MermaidText.smallSize, bold: true)
            }
            }
        }
        // Lifelines, activation bars, then the participant heads at top and bottom.
        for c in centers {
            svg.line(CGPoint(x: c, y: headerHeight), CGPoint(x: c, y: lifelineEnd), stroke: theme.muted, width: 1, dash: "3 3")
        }
        for (p, top, bottom, depth) in activations.sorted(by: { ($0.0, $0.3, $0.1) < ($1.0, $1.3, $1.1) }) {
            let x = centers[p] - 5 + Double(depth) * 5
            svg.rect(CGRect(x: x, y: top, width: 10, height: max(bottom - top, 8)), fill: theme.nodeFill, stroke: theme.nodeStroke, strokeWidth: 1)
        }
        for draw in blockLabels { draw(&svg) }
        var frames: [CGRect] = []
        for (i, p) in participants.enumerated() {
            for top in [0, lifelineEnd] {
                let r = CGRect(x: centers[i] - widths[i] / 2, y: top, width: widths[i], height: headerHeight)
                drawHead(&svg, p, lines: labels[i], in: r, theme: theme)
                if top == 0 { frames.append(r) }
            }
        }
        for draw in foreground { draw(&svg) }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), nodeFrames: frames, texts: svg.texts)
    }

    private func drawHead(_ svg: inout MermaidSVG, _ p: Participant, lines: [String], in r: CGRect, theme: MermaidTheme) {
        let lh = MermaidText.lineHeight()
        guard p.isActor else {
            svg.rect(r, rx: 3, fill: theme.nodeFill, stroke: theme.nodeStroke, strokeWidth: 1.5)
            svg.lines(lines, x: r.midX, top: r.midY - lh * Double(lines.count) / 2)
            return
        }
        let cx = r.midX, top = r.minY + 2
        let stroke = theme.nodeStroke
        svg.add("circle", [("cx", MermaidSVG.num(cx)), ("cy", MermaidSVG.num(top + 6)), ("r", "6"), ("fill", theme.nodeFill),
                           ("stroke", stroke), ("stroke-width", "1.5")])
        svg.path("M\(MermaidSVG.num(cx)),\(MermaidSVG.num(top + 12)) L\(MermaidSVG.num(cx)),\(MermaidSVG.num(top + 24)) M\(MermaidSVG.num(cx - 10)),\(MermaidSVG.num(top + 16)) L\(MermaidSVG.num(cx + 10)),\(MermaidSVG.num(top + 16)) M\(MermaidSVG.num(cx - 8)),\(MermaidSVG.num(top + 32)) L\(MermaidSVG.num(cx)),\(MermaidSVG.num(top + 24)) L\(MermaidSVG.num(cx + 8)),\(MermaidSVG.num(top + 32))",
                 stroke: stroke, strokeWidth: 1.5)
        svg.lines(lines, x: cx, top: top + Self.actorFigure + 2)
    }

    private func drawNumber(_ svg: inout MermaidSVG, _ n: Int, at p: CGPoint, theme: MermaidTheme) {
        svg.add("circle", [("cx", MermaidSVG.num(p.x)), ("cy", MermaidSVG.num(p.y)), ("r", "8"), ("fill", theme.nodeStroke)])
        svg.text(String(n), x: p.x, y: p.y, size: 10, bold: true, fill: theme.background)
    }
}
