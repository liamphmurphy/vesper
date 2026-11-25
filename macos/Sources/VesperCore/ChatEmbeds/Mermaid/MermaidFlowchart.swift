import CoreGraphics
import Foundation

/// `flowchart` / `graph`: nodes in the classic shapes, links with heads and labels, chains and
/// `&` groups, subgraphs, and `classDef`/`class`/`style`/`linkStyle` colours.
struct MermaidFlowchart {
    enum LineKind { case solid, dotted, thick, invisible }

    struct Node {
        var id: String
        var label: String
        var shape: MermaidShape = .rect
        var classes: [String] = []
        var style = MermaidStyle()
    }

    struct Edge {
        var from: String
        var to: String
        var label: String?
        var line: LineKind
        var start: MermaidMarker?
        var end: MermaidMarker?
    }

    struct Subgraph {
        var id: String
        var title: String
        var parent: String?
        var style = MermaidStyle()
        var classes: [String] = []
    }

    var direction: MermaidGraphInput.Direction = .down
    var nodes: [String: Node] = [:]
    var order: [String] = []
    var parentOf: [String: String] = [:]
    var subgraphs: [Subgraph] = []
    var edges: [Edge] = []
    var classDefs: [String: MermaidStyle] = [:]
    var linkStyles: [Int: MermaidStyle] = [:]
    var defaultLinkStyle = MermaidStyle()

    // MARK: Parsing

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidFlowchart {
        var f = MermaidFlowchart()
        let (dirWord, rest) = MermaidScan.firstWord(doc.headerRest.replacingOccurrences(of: ";", with: " ; "))
        var headerRest = doc.headerRest
        if let d = MermaidGraphInput.Direction(mermaid: dirWord) {
            f.direction = d
            headerRest = rest
        }
        var stack: [String] = []
        var skippingBlock = false
        for stmt in MermaidScan.statements(doc.lines, headerRest: headerRest, headerLine: doc.headerLine) {
            let t = stmt.text
            if skippingBlock {
                if t.contains("}") { skippingBlock = false }
                continue
            }
            if t == "end" {
                guard !stack.isEmpty else { throw .syntax(line: stmt.number, message: "\"end\" without a subgraph") }
                stack.removeLast()
                continue
            }
            if let header = MermaidScan.keyword(t, "subgraph") {
                let (id, title) = Self.subgraphHeader(header, line: stmt.number, index: f.subgraphs.count)
                if f.subgraphs.contains(where: { $0.id == id }) {
                    throw .syntax(line: stmt.number, message: "subgraph \"\(id)\" is defined twice")
                }
                f.subgraphs.append(Subgraph(id: id, title: title, parent: stack.last))
                stack.append(id)
                continue
            }
            if MermaidScan.keyword(t, "direction") != nil { continue }
            if let rest = MermaidScan.keyword(t, "classDef") {
                let (names, css) = MermaidScan.firstWord(rest)
                let style = MermaidStyle(css: css)
                for n in names.split(separator: ",") { f.classDefs[String(n)] = style }
                continue
            }
            if let rest = MermaidScan.keyword(t, "class") {
                let (ids, cls) = MermaidScan.firstWord(rest)
                for id in ids.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
                    f.addClass(cls, to: id)
                }
                continue
            }
            if let rest = MermaidScan.keyword(t, "style") {
                let (id, css) = MermaidScan.firstWord(rest)
                if let i = f.subgraphs.firstIndex(where: { $0.id == id }) {
                    f.subgraphs[i].style = MermaidStyle(css: css).merged(over: f.subgraphs[i].style)
                } else {
                    f.touch(id, in: nil)
                    let base = f.nodes[id]?.style ?? MermaidStyle()
                    f.nodes[id]?.style = MermaidStyle(css: css).merged(over: base)
                }
                continue
            }
            if let rest = MermaidScan.keyword(t, "linkStyle") {
                let (which, css) = MermaidScan.firstWord(rest)
                let style = MermaidStyle(css: css)
                if which == "default" {
                    f.defaultLinkStyle = style
                } else {
                    for i in which.split(separator: ",").compactMap({ Int($0) }) { f.linkStyles[i] = style }
                }
                continue
            }
            if t.hasPrefix("click ") || t.hasPrefix("accTitle") || t.hasPrefix("accDescr") {
                if t.hasPrefix("accDescr"), t.contains("{"), !t.contains("}") { skippingBlock = true }
                continue
            }
            try f.parseChain(t, line: stmt.number, subgraph: stack.last)
        }
        if !stack.isEmpty { throw .syntax(line: (doc.lines.last?.number ?? doc.headerLine), message: "subgraph \"\(stack.last ?? "")\" isn't closed with end") }
        f.resolveSubgraphReferences()
        guard f.nodes.count + f.subgraphs.count <= NativeMermaid.maxNodes, f.edges.count <= NativeMermaid.maxEdges else { throw .tooLarge }
        return f
    }

    /// `id`, `id [Title]`, `id["Title"]`, `"Title"` or `Some words`.
    static func subgraphHeader(_ s: String, line: Int, index: Int) -> (String, String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return ("subGraph\(index)", "") }
        if t.hasPrefix("\"") { let title = MermaidText.unquote(t); return (title, title) }
        if let open = t.firstIndex(of: "["), t.hasSuffix("]") {
            let id = t[..<open].trimmingCharacters(in: .whitespaces)
            let title = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
            return (id.isEmpty ? MermaidText.unquote(title) : id, MermaidText.unquote(title))
        }
        return (t, t)
    }

    mutating func addClass(_ cls: String, to id: String) {
        if let i = subgraphs.firstIndex(where: { $0.id == id }) {
            subgraphs[i].classes.append(cls)
            return
        }
        touch(id, in: nil)
        nodes[id]?.classes.append(cls)
    }

    /// Records a node the first time it's seen, and puts it in the innermost subgraph mentioning it.
    mutating func touch(_ id: String, in subgraph: String?) {
        if nodes[id] == nil {
            nodes[id] = Node(id: id, label: id)
            order.append(id)
        }
        if let subgraph, parentOf[id] == nil, id != subgraph { parentOf[id] = subgraph }
    }

    /// A subgraph id used as a link end means the subgraph, not a new node.
    mutating func resolveSubgraphReferences() {
        let ids = Set(subgraphs.map(\.id))
        for id in ids where nodes[id] != nil {
            nodes[id] = nil
            order.removeAll { $0 == id }
            parentOf[id] = nil
        }
        // A link between a subgraph and something inside it has no layered drawing.
        let kept = edges.filter { e in
            !((ids.contains(e.from) && isInside(e.to, e.from)) || (ids.contains(e.to) && isInside(e.from, e.to)))
        }
        edges = kept
    }

    func isInside(_ id: String, _ subgraph: String) -> Bool {
        var p = parentOf[id] ?? subgraphs.first(where: { $0.id == id })?.parent
        var guardCount = 0
        while let q = p, guardCount < 64 {
            if q == subgraph { return true }
            p = subgraphs.first(where: { $0.id == q })?.parent
            guardCount += 1
        }
        return false
    }

    mutating func parseChain(_ s: String, line: Int, subgraph: String?) throws(NativeMermaidError) {
        var c = MermaidCursor(s)
        var previous = try parseGroup(&c, line: line, subgraph: subgraph)
        while true {
            c.skipSpaces()
            if c.atEnd { break }
            guard let link = Self.parseLink(&c) else {
                throw .syntax(line: line, message: "unexpected \"\(c.rest.prefix(24))\"")
            }
            let next = try parseGroup(&c, line: line, subgraph: subgraph)
            for a in previous {
                for b in next {
                    edges.append(Edge(from: a, to: b, label: link.label, line: link.line, start: link.start, end: link.end))
                }
            }
            previous = next
        }
    }

    mutating func parseGroup(_ c: inout MermaidCursor, line: Int, subgraph: String?) throws(NativeMermaidError) -> [String] {
        var ids: [String] = []
        repeat {
            c.skipSpaces()
            guard let id = try parseNode(&c, line: line, subgraph: subgraph) else {
                throw .syntax(line: line, message: c.atEnd ? "expected a node" : "expected a node at \"\(c.rest.prefix(24))\"")
            }
            ids.append(id)
            c.skipSpaces()
        } while c.eat("&")
        return ids
    }

    static func isIDChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    private static let openers: [(String, [String], MermaidShape)] = [
        ("(((", [")))"], .doubleCircle), ("((", ["))"], .circle), ("([", ["])"], .stadium), ("[[", ["]]"], .subroutine),
        ("[(", [")]"], .cylinder), ("[/", ["/]", "\\]"], .leanRight), ("[\\", ["\\]", "/]"], .leanLeft),
        ("{{", ["}}"], .hexagon), ("{", ["}"], .rhombus), ("(", [")"], .round), (">", ["]"], .asymmetric), ("[", ["]"], .rect),
    ]

    mutating func parseNode(_ c: inout MermaidCursor, line: Int, subgraph: String?) throws(NativeMermaidError) -> String? {
        var id = ""
        while let ch = c.peek {
            if Self.isIDChar(ch) {
                id.append(ch)
                c.i += 1
            } else if ch == "-" || ch == ".", let next = c.peek(1), Self.isIDChar(next) {
                var probe = c
                if Self.parseLink(&probe) != nil { break }
                id.append(ch)
                c.i += 1
            } else {
                break
            }
        }
        guard !id.isEmpty else { return nil }
        touch(id, in: subgraph)
        if c.starts(with: "@{") {
            c.i += 2
            var body = ""
            while let ch = c.peek, ch != "}" { body.append(ch); c.i += 1 }
            guard c.eat("}") else { throw .syntax(line: line, message: "\"@{\" isn't closed") }
            applyShapeData(body, to: id)
        } else if let (open, closers, shape) = Self.openers.first(where: { c.starts(with: $0.0) }) {
            c.i += open.count
            let (label, closer) = try Self.readLabel(&c, closers: closers, opener: open.last ?? "[", line: line)
            var finalShape = shape
            if shape == .leanRight, closer == "\\]" { finalShape = .trapezoid }
            if shape == .leanLeft, closer == "/]" { finalShape = .trapezoidAlt }
            nodes[id]?.label = label
            nodes[id]?.shape = finalShape
        }
        if c.eat(":::") {
            var cls = ""
            while let ch = c.peek, Self.isIDChar(ch) || ch == "-" { cls.append(ch); c.i += 1 }
            if !cls.isEmpty { nodes[id]?.classes.append(cls) }
        }
        return id
    }

    /// `A@{ shape: diam, label: "Decide" }`, mermaid's newer shape syntax, for the shapes it shares
    /// with the bracket forms.
    mutating func applyShapeData(_ body: String, to id: String) {
        for part in MermaidScan.splitTopLevel(body, separators: [","]) {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "label": nodes[id]?.label = MermaidText.unquote(kv[1])
            case "shape":
                let map: [String: MermaidShape] = [
                    "rect": .rect, "proc": .rect, "process": .rect, "rectangle": .rect, "rounded": .round, "event": .round,
                    "stadium": .stadium, "pill": .stadium, "terminal": .stadium, "subroutine": .subroutine, "subproc": .subroutine,
                    "fr-rect": .subroutine, "cyl": .cylinder, "cylinder": .cylinder, "database": .cylinder, "db": .cylinder,
                    "circle": .circle, "circ": .circle, "dbl-circ": .doubleCircle, "double-circle": .doubleCircle,
                    "diam": .rhombus, "diamond": .rhombus, "decision": .rhombus, "question": .rhombus, "hex": .hexagon,
                    "hexagon": .hexagon, "prepare": .hexagon, "lean-r": .leanRight, "lean-right": .leanRight, "in-out": .leanRight,
                    "lean-l": .leanLeft, "lean-left": .leanLeft, "out-in": .leanLeft, "trap-b": .trapezoid, "trapezoid": .trapezoid,
                    "priority": .trapezoid, "trap-t": .trapezoidAlt, "inv-trapezoid": .trapezoidAlt, "manual": .trapezoidAlt,
                    "odd": .asymmetric,
                ]
                if let s = map[MermaidText.unquote(kv[1]).lowercased()] { nodes[id]?.shape = s }
            default: continue
            }
        }
    }

    /// The label inside a shape: a quoted string, or text up to the closer (nested brackets of the
    /// opener's kind are kept).
    static func readLabel(_ c: inout MermaidCursor, closers: [String], opener: Character, line: Int) throws(NativeMermaidError) -> (String, String) {
        var label = ""
        if c.peek == "\"" {
            c.i += 1
            while let ch = c.peek, ch != "\"" { label.append(ch); c.i += 1 }
            guard c.eat("\"") else { throw .syntax(line: line, message: "a quoted label isn't closed") }
            c.skipSpaces()
            guard let closer = closers.first(where: { c.starts(with: $0) }) else {
                throw .syntax(line: line, message: "expected \(closers[0]) after the label")
            }
            c.i += closer.count
            return (label, closer)
        }
        let closeChar = closers[0].first ?? "]"
        var depth = 0
        while !c.atEnd {
            if depth == 0, let closer = closers.first(where: { c.starts(with: $0) }) {
                c.i += closer.count
                return (label, closer)
            }
            let ch = c.chars[c.i]
            if ch == opener, opener != closeChar { depth += 1 }
            if ch == closeChar, depth > 0 { depth -= 1 }
            label.append(ch)
            c.i += 1
        }
        throw .syntax(line: line, message: "expected \(closers[0]) to close the node")
    }

    struct Link {
        var line: LineKind
        var start: MermaidMarker?
        var end: MermaidMarker?
        var label: String?
    }

    private static func head(_ ch: Character?) -> MermaidMarker? {
        switch ch {
        case ">": .arrow
        case "x": .cross
        case "o": .circle
        default: nil
        }
    }

    /// One link token: `-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `o--o`, `x--x`, `-- text -->`,
    /// `-. text .->`, `== text ==>`, each optionally followed by `|label|`.
    static func parseLink(_ c: inout MermaidCursor) -> Link? {
        let save = c
        c.skipSpaces()
        var start: MermaidMarker?
        if c.peek == "<", c.peek(1) == "-" || c.peek(1) == "=" {
            start = .arrow
            c.i += 1
        } else if c.peek == "o" || c.peek == "x", c.peek(1) == "-" || c.peek(1) == "=", c.peek(2) == "-" || c.peek(2) == "=" || c.peek(2) == "." {
            start = head(c.peek)
            c.i += 1
        }
        var link: Link?
        if c.starts(with: "~~~") {
            while c.peek == "~" { c.i += 1 }
            link = Link(line: .invisible)
        } else if c.peek == "-" || c.peek == "=" {
            link = lineBody(&c, char: c.peek ?? "-")
        }
        guard var l = link else { c = save; return nil }
        if l.start == nil { l.start = start }
        c.skipSpaces()
        if c.peek == "|" {
            c.i += 1
            var text = ""
            while let ch = c.peek, ch != "|" { text.append(ch); c.i += 1 }
            guard c.eat("|") else { c = save; return nil }
            l.label = text
        }
        return l
    }

    private static func endsHere(_ c: MermaidCursor, after offset: Int) -> Bool {
        guard let n = c.peek(offset) else { return true }
        return !(n.isLetter || n.isNumber || n == "_")
    }

    /// The dashes/equals of a link, with an inline `-- text -->` label when present.
    private static func lineBody(_ c: inout MermaidCursor, char: Character) -> Link? {
        let kind: LineKind = char == "=" ? .thick : .solid
        if char == "-", c.peek(1) == "." {
            // Dotted: -.-> -.- -..-> or -. text .->
            c.i += 1
            while c.peek == "." { c.i += 1 }
            if c.peek == " " {
                guard let (text, endAt) = findClose(c, marker: ".-") else { return nil }
                c.i = endAt
                while c.peek == "." { c.i += 1 }
                guard c.eat("-") else { return nil }
                var l = Link(line: .dotted, label: text)
                l.end = takeHead(&c)
                return l
            }
            guard c.eat("-") else { return nil }
            var l = Link(line: .dotted)
            l.end = takeHead(&c)
            return l
        }
        var count = 0
        while c.peek == char { count += 1; c.i += 1 }
        guard count >= 2 else { return nil }
        if let h = head(c.peek), h == .arrow || endsHere(c, after: 1) {
            c.i += 1
            return Link(line: kind, end: h)
        }
        if count >= 3 { return Link(line: kind) }
        // `-- text -->` / `== text ==>`
        guard c.peek == " " else { return nil }
        let doubled = String([char, char])
        guard let (text, endAt) = findClose(c, marker: doubled) else { return nil }
        c.i = endAt
        while c.peek == char { c.i += 1 }
        var l = Link(line: kind, label: text)
        l.end = takeHead(&c)
        return l
    }

    private static func takeHead(_ c: inout MermaidCursor) -> MermaidMarker? {
        guard let h = head(c.peek), h == .arrow || endsHere(c, after: 1) else { return nil }
        c.i += 1
        return h
    }

    /// The text before the next `marker`, and where the marker starts.
    private static func findClose(_ c: MermaidCursor, marker: String) -> (String, Int)? {
        let m = Array(marker)
        var k = c.i
        while k + m.count <= c.chars.count {
            if Array(c.chars[k..<(k + m.count)]) == m {
                let text = String(c.chars[c.i..<k]).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : (text, k)
            }
            k += 1
        }
        return nil
    }

    // MARK: Drawing

    func nodeStyle(_ n: Node) -> MermaidStyle {
        var s = classDefs["default"] ?? MermaidStyle()
        for cls in n.classes { if let d = classDefs[cls] { s = d.merged(over: s) } }
        return n.style.merged(over: s)
    }

    func draw(_ theme: MermaidTheme, title: String?) throws(NativeMermaidError) -> MermaidDrawing {
        var input = MermaidGraphInput()
        input.direction = direction
        var labelLines: [String: [String]] = [:]
        let lh = MermaidText.lineHeight()

        // Clusters and nodes interleave in declaration order: a cluster is added just before the
        // first node it contains, and its parents before it.
        var addedClusters: Set<String> = []
        func addCluster(_ id: String) {
            guard !addedClusters.contains(id), let sg = subgraphs.first(where: { $0.id == id }) else { return }
            addedClusters.insert(id)
            if let p = sg.parent { addCluster(p) }
            let lines = MermaidText.lines(sg.title)
            let header = sg.title.isEmpty ? 12 : lh * Double(lines.count) + 14
            input.add(MermaidGraphInput.Cluster(id: id, parent: sg.parent, header: header,
                                                minWidth: MermaidText.width(lines: lines) + 32))
        }
        for id in order {
            guard let n = nodes[id] else { continue }
            if let p = parentOf[id] { addCluster(p) }
            let lines = MermaidText.wrap(MermaidText.lines(n.label), maxWidth: 220)
            labelLines[id] = lines
            let text = CGSize(width: MermaidText.width(lines: lines), height: lh * Double(lines.count))
            input.add(MermaidGraphInput.Node(id: id, size: n.shape.size(text: text), parent: parentOf[id]))
        }
        for sg in subgraphs { addCluster(sg.id) }
        var edgeLabels: [Int: [String]] = [:]
        for (i, e) in edges.enumerated() {
            var size: CGSize?
            if let label = e.label, !label.isEmpty, e.line != .invisible {
                let lines = MermaidText.wrap(MermaidText.lines(label), maxWidth: 200)
                edgeLabels[i] = lines
                size = CGSize(width: MermaidText.width(lines: lines) + 8, height: lh * Double(lines.count) + 4)
            }
            input.edges.append(MermaidGraphInput.Edge(id: "e\(i)", source: e.from, target: e.to, label: size))
        }
        let layout = try MermaidLayered.layout(input, diagram: "flowchart")

        var svg = MermaidSVG(theme: theme)
        let size = svg.beginDiagram(content: layout.size, title: title)
        // Outer clusters first so nested ones draw on top.
        let depthOf: (Subgraph) -> Int = { sg in
            var d = 0, p = sg.parent
            while let q = p, d < 64 { d += 1; p = subgraphs.first(where: { $0.id == q })?.parent }
            return d
        }
        for sg in subgraphs.sorted(by: { depthOf($0) < depthOf($1) }) {
            guard let r = layout.clusters[sg.id] else { continue }
            var style = MermaidStyle()
            for cls in sg.classes { if let d = classDefs[cls] { style = d.merged(over: style) } }
            style = sg.style.merged(over: style)
            svg.rect(r, rx: 4, fill: style.fill ?? theme.clusterFill, stroke: style.stroke ?? theme.clusterStroke,
                     strokeWidth: style.strokeWidth ?? 1, dash: style.dash)
            let lines = MermaidText.lines(sg.title)
            svg.lines(lines, x: r.midX, top: r.minY + 7, bold: false, fill: style.color)
        }
        var frames: [CGRect] = []
        for id in order {
            guard let n = nodes[id], let r = layout.nodes[id] else { continue }
            let style = nodeStyle(n)
            n.shape.draw(&svg, r, fill: style.fill ?? theme.nodeFill, stroke: style.stroke ?? theme.nodeStroke,
                         width: style.strokeWidth ?? 1.5, dash: style.dash)
            let lines = labelLines[id] ?? []
            let off = n.shape.textOffset(in: r)
            let h = lh * Double(lines.count)
            for (k, l) in lines.enumerated() {
                svg.text(l, x: r.midX + off.x, y: r.midY + off.y - h / 2 + lh * (Double(k) + 0.5), bold: style.bold, fill: style.color)
            }
            frames.append(r)
        }
        for (i, e) in edges.enumerated() where e.line != .invisible {
            guard var pts = layout.edges["e\(i)"], pts.count >= 2 else { continue }
            if let n = nodes[e.from], let r = layout.nodes[e.from], let o = n.shape.outline(r) { MermaidLayered.clip(&pts, atEnd: false, to: o) }
            if let n = nodes[e.to], let r = layout.nodes[e.to], let o = n.shape.outline(r) { MermaidLayered.clip(&pts, atEnd: true, to: o) }
            let style = (linkStyles[i] ?? MermaidStyle()).merged(over: defaultLinkStyle)
            let width = style.strokeWidth ?? (e.line == .thick ? 3 : 1.5)
            let dash = style.dash ?? (e.line == .dotted ? "4 3" : nil)
            svg.edge(pts, stroke: style.stroke ?? theme.line, width: width, dash: dash, start: e.start, end: e.end)
        }
        for (i, e) in edges.enumerated() where e.line != .invisible {
            guard let lines = edgeLabels[i], let r = layout.labels["e\(i)"] else { continue }
            let style = (linkStyles[i] ?? MermaidStyle()).merged(over: defaultLinkStyle)
            svg.edgeLabel(lines, in: r, color: style.color)
        }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), nodeFrames: frames, texts: svg.texts)
    }
}
