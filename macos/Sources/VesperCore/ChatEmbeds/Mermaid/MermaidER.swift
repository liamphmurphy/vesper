import CoreGraphics
import Foundation

/// `erDiagram`: entities with attribute blocks (`type name PK, FK "comment"`), entities without
/// attributes, `ID["Alias"]` display names, relationships with a cardinality at each end in
/// mermaid's symbol form (`||--o{`) or word form (`1 to zero or more`), identifying (`--`, solid)
/// and non-identifying (`..`, dashed) lines, `direction`, and `classDef`/`class`/`style`/`:::`
/// colours.
///
/// Each entity is a header with its name over a table whose columns line up within the entity and
/// only appear when some row uses them. Crow's feet are the shared `MermaidMarker` ends, which
/// point along the edge into the entity at either end.
struct MermaidER {
    /// How many of an entity take part at one end of a relationship.
    enum Cardinality {
        case zeroOrOne, exactlyOne, zeroOrMore, oneOrMore

        var marker: MermaidMarker {
            switch self {
            case .zeroOrOne: .erZeroOne
            case .exactlyOne: .erOne
            case .zeroOrMore: .erZeroMany
            case .oneOrMore: .erOneMany
            }
        }

        /// The left end as written before the line (`|o`, `||`, `}o`, `}|`).
        init?(left s: Substring) {
            switch s {
            case "|o": self = .zeroOrOne
            case "||": self = .exactlyOne
            case "}o": self = .zeroOrMore
            case "}|": self = .oneOrMore
            default: return nil
            }
        }

        /// The right end as written after the line (`o|`, `||`, `o{`, `|{`).
        init?(right s: Substring) {
            switch s {
            case "o|": self = .zeroOrOne
            case "||": self = .exactlyOne
            case "o{": self = .zeroOrMore
            case "|{": self = .oneOrMore
            default: return nil
            }
        }

        /// Mermaid's word aliases, which read the same on either side of `to`.
        init?(words: String) {
            switch words.lowercased() {
            case "only one", "exactly one", "1": self = .exactlyOne
            case "zero or one", "one or zero": self = .zeroOrOne
            case "one or more", "one or many", "many(1)", "1+": self = .oneOrMore
            case "zero or more", "zero or many", "many(0)", "0+": self = .zeroOrMore
            default: return nil
            }
        }
    }

    struct Attribute {
        var type: String
        var name: String
        var keys: [String] = []
        var comment: String?
    }

    struct Entity {
        var id: String
        var label: String
        var attributes: [Attribute] = []
        var classes: [String] = []
        var style = MermaidStyle()
    }

    struct Relationship {
        var from: String
        var to: String
        var fromCardinality: Cardinality
        var toCardinality: Cardinality
        var identifying: Bool
        var label: String?
    }

    var direction: MermaidGraphInput.Direction = .down
    var entities: [String: Entity] = [:]
    var order: [String] = []
    var relationships: [Relationship] = []
    var classDefs: [String: MermaidStyle] = [:]

    // MARK: Parsing

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidER {
        var er = MermaidER()
        var block: (id: String, line: Int)?
        var skippingBlock = false
        var statements: [MermaidLine] = []
        var pending = doc.lines[...]
        if !doc.headerRest.isEmpty {
            pending = ([MermaidLine(number: doc.headerLine, text: doc.headerRest)] + doc.lines)[...]
        }
        while true {
            let stmt: MermaidLine
            if !statements.isEmpty {
                stmt = statements.removeFirst()
            } else if let next = pending.popFirst() {
                // Attribute lines are one per line, so `;` only separates statements outside a block.
                if block != nil {
                    stmt = next
                } else {
                    statements = Self.splitStatements(next.text).map { MermaidLine(number: next.number, text: $0) }
                    continue
                }
            } else {
                break
            }
            let t = stmt.text
            if let open = block {
                var body = t
                let closes = body.hasSuffix("}")
                if closes { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
                if !body.isEmpty { er.entities[open.id]?.attributes.append(try Self.parseAttribute(body, line: stmt.number)) }
                if closes { block = nil }
                continue
            }
            if skippingBlock {
                if t.contains("}") { skippingBlock = false }
                continue
            }
            if t == "}" { throw .syntax(line: stmt.number, message: "\"}\" without an entity block") }
            if let rest = MermaidScan.keyword(t, "direction") {
                if let d = MermaidGraphInput.Direction(mermaid: rest) { er.direction = d }
                continue
            }
            if let rest = MermaidScan.keyword(t, "classDef") {
                let (names, css) = MermaidScan.firstWord(rest)
                let style = MermaidStyle(css: css)
                for n in names.split(separator: ",") { er.classDefs[String(n)] = style }
                continue
            }
            if let rest = MermaidScan.keyword(t, "class") {
                let (ids, cls) = MermaidScan.firstWord(rest)
                for id in ids.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
                    er.touch(id)
                    er.entities[id]?.classes.append(cls)
                }
                continue
            }
            if let rest = MermaidScan.keyword(t, "style") {
                let (id, css) = MermaidScan.firstWord(rest)
                guard !id.isEmpty else { continue }
                er.touch(id)
                let base = er.entities[id]?.style ?? MermaidStyle()
                er.entities[id]?.style = MermaidStyle(css: css).merged(over: base)
                continue
            }
            if t.hasPrefix("accTitle") || t.hasPrefix("accDescr") || t.hasPrefix("click ") {
                if t.hasPrefix("accDescr"), t.contains("{"), !t.contains("}") { skippingBlock = true }
                continue
            }
            if try er.parseRelationship(t, line: stmt.number) { continue }
            if let opened = try er.parseEntity(t, line: stmt.number) { block = (opened, stmt.number) }
        }
        if let open = block { throw .syntax(line: open.line, message: "entity \"\(open.id)\" isn't closed with }") }
        guard !er.entities.isEmpty else { throw .syntax(line: doc.headerLine, message: "the diagram has no entities") }
        let rows = er.entities.values.reduce(0) { $0 + $1.attributes.count }
        guard er.entities.count <= NativeMermaid.maxNodes, er.relationships.count <= NativeMermaid.maxEdges,
              rows <= NativeMermaid.maxRows else { throw .tooLarge }
        return er
    }

    /// Splits on `;` outside double quotes. `MermaidScan.splitTopLevel` counts `{` as nesting,
    /// which would swallow the rest of a line after an `o{` cardinality.
    static func splitStatements(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if ch == ";", !quoted {
                out.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Letters, digits, `_` and `-`: mermaid's bare entity names. Anything else needs quotes.
    static func isValidID(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// `ID`, `"Quoted name"`, `ID[Alias]` or `ID["Alias"]`, each optionally followed by `:::class`.
    static func reference(_ s: String, line: Int) throws(NativeMermaidError) -> (id: String, alias: String?, cls: String?) {
        var t = Substring(s.trimmingCharacters(in: .whitespaces))
        let id: String
        var quoted = false
        if t.hasPrefix("\"") {
            guard let close = t.dropFirst().firstIndex(of: "\"") else { throw .syntax(line: line, message: "a quoted entity name isn't closed") }
            id = String(t[t.index(after: t.startIndex)..<close])
            t = t[t.index(after: close)...]
            quoted = true
        } else {
            let end = t.firstIndex(where: { $0 == "[" || $0 == ":" || $0 == " " || $0 == "\t" }) ?? t.endIndex
            id = String(t[..<end])
            t = t[end...]
        }
        var alias: String?
        if t.hasPrefix("[") {
            guard let close = t.lastIndex(of: "]") else { throw .syntax(line: line, message: "an entity alias isn't closed with ]") }
            alias = MermaidText.unquote(String(t[t.index(after: t.startIndex)..<close]))
            t = t[t.index(after: close)...]
        }
        var cls: String?
        if t.hasPrefix(":::") {
            cls = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
            t = ""
        }
        let leftover = t.trimmingCharacters(in: .whitespaces)
        guard leftover.isEmpty, quoted ? !id.isEmpty : isValidID(id) else {
            throw .syntax(line: line, message: id.isEmpty && leftover.isEmpty ? "expected an entity"
                : "expected an entity or a relationship like A ||--o{ B : label")
        }
        return (id, alias.flatMap { $0.isEmpty ? nil : $0 }, cls.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Records an entity the first time it's named, keeping source order for the layout.
    mutating func touch(_ id: String) {
        guard entities[id] == nil else { return }
        entities[id] = Entity(id: id, label: id)
        order.append(id)
    }

    mutating func declare(_ ref: (id: String, alias: String?, cls: String?)) {
        touch(ref.id)
        if let alias = ref.alias { entities[ref.id]?.label = alias }
        if let cls = ref.cls { entities[ref.id]?.classes.append(cls) }
    }

    /// `ID`, `ID["Alias"]`, `ID {` (opens a block) or `ID { type name }` on one line. Returns the
    /// entity when its block stays open.
    mutating func parseEntity(_ t: String, line: Int) throws(NativeMermaidError) -> String? {
        var head = t
        var inner: String?
        if let brace = Self.unquotedIndex(of: "{", in: t) {
            head = String(t[..<brace])
            inner = t[t.index(after: brace)...].trimmingCharacters(in: .whitespaces)
        }
        let ref = try Self.reference(head, line: line)
        declare(ref)
        guard var body = inner else { return nil }
        let closes = body.hasSuffix("}")
        if closes { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
        if !body.isEmpty { entities[ref.id]?.attributes.append(try Self.parseAttribute(body, line: line)) }
        return closes ? nil : ref.id
    }

    /// `type name`, then optional keys (`PK`, `FK`, `UK`, comma-separated) and a quoted comment.
    static func parseAttribute(_ s: String, line: Int) throws(NativeMermaidError) -> Attribute {
        var t = s.trimmingCharacters(in: .whitespaces)
        var comment: String?
        if t.hasSuffix("\""), let open = t.dropLast().lastIndex(of: "\"") {
            comment = MermaidText.collapse(MermaidText.decodeEntities(String(t[t.index(after: open)..<t.index(before: t.endIndex)])))
            t = String(t[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.count >= 2 else { throw .syntax(line: line, message: "an attribute needs a type and a name, like string email") }
        var keys: [String] = []
        for k in words.dropFirst(2).joined(separator: " ").split(whereSeparator: { $0 == "," || $0 == " " }) {
            if k.hasPrefix("\"") { throw .syntax(line: line, message: "an attribute comment isn't closed") }
            let key = k.uppercased()
            guard key == "PK" || key == "FK" || key == "UK" else {
                throw .syntax(line: line, message: "\"\(k.prefix(24))\" isn't a key (PK, FK or UK)")
            }
            if !keys.contains(key) { keys.append(key) }
        }
        return Attribute(type: words[0], name: words[1], keys: keys, comment: comment.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `A ||--o{ B : label` or `A 1 to zero or more B : label`. False when the statement isn't a
    /// relationship at all, so it's read as an entity instead.
    mutating func parseRelationship(_ t: String, line: Int) throws(NativeMermaidError) -> Bool {
        var spec = t
        var label: String?
        if let colon = Self.labelColon(t) {
            label = MermaidText.unquote(String(t[t.index(after: colon)...]))
            spec = String(t[..<colon])
        }
        let lhs: String, rhs: String
        let left: Cardinality, right: Cardinality
        let identifying: Bool
        let symbols = /(\|o|\|\||\}o|\}\|)(--|\.\.|\.-|-\.)(o\||\|\||o\{|\|\{)/
        let outsideQuotes = { (i: String.Index) in spec[..<i].filter { $0 == "\"" }.count % 2 == 0 }
        if let m = spec.matches(of: symbols).first(where: { match in outsideQuotes(match.range.lowerBound) }),
           let l = Cardinality(left: m.output.1), let r = Cardinality(right: m.output.3) {
            lhs = String(spec[..<m.range.lowerBound])
            rhs = String(spec[m.range.upperBound...])
            left = l
            right = r
            identifying = m.output.2 == "--"
        } else {
            let words = Self.words(spec)
            guard words.count >= 4, let to = words.indices.dropFirst(2).first(where: { words[$0].lowercased() == "to" }),
                  to < words.count - 2 else { return false }
            var leftWords = Array(words[1..<to])
            identifying = leftWords.last?.lowercased() != "optionally"
            if !identifying { leftWords.removeLast() }
            let leftPhrase = leftWords.joined(separator: " "), rightPhrase = words[(to + 1)..<(words.count - 1)].joined(separator: " ")
            guard let l = Cardinality(words: leftPhrase) else { throw .syntax(line: line, message: "\"\(leftPhrase.prefix(24))\" isn't a cardinality") }
            guard let r = Cardinality(words: rightPhrase) else { throw .syntax(line: line, message: "\"\(rightPhrase.prefix(24))\" isn't a cardinality") }
            lhs = words[0]
            rhs = words[words.count - 1]
            left = l
            right = r
        }
        guard !lhs.trimmingCharacters(in: .whitespaces).isEmpty, !rhs.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw .syntax(line: line, message: "a relationship needs an entity on both ends")
        }
        let a = try Self.reference(lhs, line: line), b = try Self.reference(rhs, line: line)
        declare(a)
        declare(b)
        relationships.append(Relationship(from: a.id, to: b.id, fromCardinality: left, toCardinality: right,
                                          identifying: identifying, label: label.flatMap { $0.isEmpty ? nil : $0 }))
        return true
    }

    /// The `:` before a relationship label: outside quotes and an alias's brackets, and not part of
    /// a `:::class` marker.
    static func labelColon(_ t: String) -> String.Index? {
        var quoted = false
        var depth = 0
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c == "\"" {
                quoted.toggle()
            } else if !quoted {
                if c == "[" { depth += 1 }
                if c == "]" { depth = max(0, depth - 1) }
                if c == ":", depth == 0 {
                    if t[i...].hasPrefix(":::") {
                        i = t.index(i, offsetBy: 3)
                        continue
                    }
                    return i
                }
            }
            i = t.index(after: i)
        }
        return nil
    }

    static func unquotedIndex(of target: Character, in t: String) -> String.Index? {
        var quoted = false
        for i in t.indices {
            if t[i] == "\"" { quoted.toggle() } else if !quoted, t[i] == target { return i }
        }
        return nil
    }

    /// Whitespace-separated words, a quoted entity name counting as one.
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if !quoted, ch == " " || ch == "\t" {
                if !current.isEmpty { out.append(current) }
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Drawing

    enum Column: CaseIterable { case type, name, keys, comment }

    static let rowSize = MermaidText.smallSize
    static let rowHeight = MermaidText.lineHeight(MermaidText.smallSize) + 8
    static let headerPadY = 9.0
    static let cellPadX = 10.0
    static let columnGap = 14.0
    static let corner = 5.0

    /// An entity's measured box: its title lines, the columns its rows use with their widths, and
    /// the overall size.
    struct Box {
        var title: [String]
        var headerHeight: Double
        var columns: [(column: Column, width: Double)]
        var size: CGSize
    }

    static func cell(_ c: Column, _ a: Attribute) -> String {
        switch c {
        case .type: a.type
        case .name: a.name
        case .keys: a.keys.joined(separator: ", ")
        case .comment: a.comment ?? ""
        }
    }

    static func cellWidth(_ c: Column, _ text: String) -> Double {
        MermaidText.width(text, size: rowSize, bold: c == .keys, italic: c == .comment)
    }

    func box(_ e: Entity) -> Box {
        let title = MermaidText.wrap(MermaidText.lines(e.label), maxWidth: 260, bold: true)
        let headerHeight = MermaidText.lineHeight() * Double(title.count) + Self.headerPadY * 2
        var columns: [(column: Column, width: Double)] = []
        for c in Column.allCases {
            let w = e.attributes.map { Self.cellWidth(c, Self.cell(c, $0)) }.max() ?? 0
            if w > 0 { columns.append((c, w.rounded(.up))) }
        }
        let tableWidth = columns.isEmpty ? 0
            : columns.reduce(0) { $0 + $1.width } + Self.columnGap * Double(columns.count - 1) + Self.cellPadX * 2
        let width = max(MermaidText.width(lines: title, bold: true) + MermaidShape.padX * 2, tableWidth, 90)
        let height = headerHeight + Self.rowHeight * Double(e.attributes.count)
        return Box(title: title, headerHeight: headerHeight, columns: columns, size: CGSize(width: width.rounded(.up), height: height))
    }

    func style(_ e: Entity) -> MermaidStyle {
        var out = classDefs["default"] ?? MermaidStyle()
        for cls in e.classes { if let d = classDefs[cls] { out = d.merged(over: out) } }
        return e.style.merged(over: out)
    }

    func draw(_ theme: MermaidTheme, title: String?) throws(NativeMermaidError) -> MermaidDrawing {
        var input = MermaidGraphInput()
        input.direction = direction
        // Room between entities for a crow's foot at each end plus the label between them.
        input.layerSpacing = 56
        input.nodeSpacing = 40
        let lh = MermaidText.lineHeight()
        var boxes: [String: Box] = [:]
        for id in order {
            guard let e = entities[id] else { continue }
            let b = box(e)
            boxes[id] = b
            input.add(MermaidGraphInput.Node(id: id, size: b.size))
        }
        var edgeLabels: [Int: [String]] = [:]
        for (i, r) in relationships.enumerated() {
            var size: CGSize?
            if let label = r.label {
                let lines = MermaidText.wrap(MermaidText.lines(label), maxWidth: 200)
                edgeLabels[i] = lines
                size = CGSize(width: MermaidText.width(lines: lines) + 8, height: lh * Double(lines.count) + 4)
            }
            input.edges.append(MermaidGraphInput.Edge(id: "e\(i)", source: r.from, target: r.to, label: size))
        }
        let layout = try MermaidLayered.layout(input, diagram: "erDiagram")

        var svg = MermaidSVG(theme: theme)
        let size = svg.beginDiagram(content: layout.size, title: title)
        var frames: [CGRect] = []
        for id in order {
            guard let e = entities[id], let b = boxes[id], let r = layout.nodes[id] else { continue }
            drawEntity(&svg, e, b, in: r, theme: theme)
            frames.append(r)
        }
        // The ends carry the meaning here, so relationships use the muted ink rather than the
        // fainter line colour flowcharts use, which made crow's feet hard to read on dark.
        for (i, rel) in relationships.enumerated() {
            guard let pts = layout.edges["e\(i)"], pts.count >= 2 else { continue }
            svg.edge(pts, stroke: theme.muted, width: 1.25, dash: rel.identifying ? nil : "6 4",
                     start: rel.fromCardinality.marker, end: rel.toCardinality.marker)
        }
        for i in relationships.indices {
            guard let lines = edgeLabels[i], let r = layout.labels["e\(i)"] else { continue }
            svg.edgeLabel(lines, in: r)
        }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), nodeFrames: frames, texts: svg.texts)
    }

    /// A rectangle with its top and bottom corners rounded separately, so the header and the last
    /// row's fill follow the entity's rounded border instead of poking past it.
    static func roundedRect(_ r: CGRect, top: Double, bottom: Double) -> String {
        let n = MermaidSVG.num
        var d = "M\(n(r.minX)),\(n(r.minY + top))"
        d += top > 0 ? " Q\(n(r.minX)),\(n(r.minY)) \(n(r.minX + top)),\(n(r.minY))" : ""
        d += " L\(n(r.maxX - top)),\(n(r.minY))"
        d += top > 0 ? " Q\(n(r.maxX)),\(n(r.minY)) \(n(r.maxX)),\(n(r.minY + top))" : ""
        d += " L\(n(r.maxX)),\(n(r.maxY - bottom))"
        d += bottom > 0 ? " Q\(n(r.maxX)),\(n(r.maxY)) \(n(r.maxX - bottom)),\(n(r.maxY))" : ""
        d += " L\(n(r.minX + bottom)),\(n(r.maxY))"
        d += bottom > 0 ? " Q\(n(r.minX)),\(n(r.maxY)) \(n(r.minX)),\(n(r.maxY - bottom))" : ""
        return d + " Z"
    }

    /// The header takes a `classDef`/`style` fill and text colour (or a tint of the border colour);
    /// the rows stay on
    /// the surface with every other one on the panel colour so wide tables read across.
    private func drawEntity(_ svg: inout MermaidSVG, _ e: Entity, _ b: Box, in r: CGRect, theme: MermaidTheme) {
        let st = style(e)
        let stroke = st.stroke ?? theme.nodeStroke
        let n = MermaidSVG.num
        let rows = e.attributes.count
        svg.rect(r, rx: Self.corner, fill: theme.background)
        let header = CGRect(x: r.minX, y: r.minY, width: r.width, height: b.headerHeight)
        let headerPath = Self.roundedRect(header, top: Self.corner, bottom: rows == 0 ? Self.corner : 0)
        svg.add("path", [("d", headerPath), ("fill", st.fill ?? stroke), ("fill-opacity", st.fill == nil ? "0.14" : nil)])
        for i in stride(from: 1, to: rows, by: 2) {
            let row = CGRect(x: r.minX, y: header.maxY + Self.rowHeight * Double(i), width: r.width, height: Self.rowHeight)
            svg.add("path", [("d", Self.roundedRect(row, top: 0, bottom: i == rows - 1 ? Self.corner : 0)), ("fill", theme.nodeFill)])
        }
        // A `color` is picked to read on its `fill`, which only the header carries; the rows stay on
        // the surface, so they keep the palette's ink.
        svg.lines(b.title, x: r.midX, top: r.minY + Self.headerPadY, bold: true, fill: st.color ?? theme.text)
        if rows > 0 {
            svg.line(CGPoint(x: r.minX, y: header.maxY), CGPoint(x: r.maxX, y: header.maxY), stroke: stroke, width: 1)
        }
        for (i, a) in e.attributes.enumerated() {
            let y = header.maxY + Self.rowHeight * (Double(i) + 0.5)
            var x = r.minX + Self.cellPadX
            for (c, w) in b.columns {
                let fill = switch c {
                case .type, .comment: theme.muted
                case .name: theme.text
                case .keys: stroke
                }
                svg.text(Self.cell(c, a), x: x, y: y, anchor: "start", size: Self.rowSize, bold: c == .keys, italic: c == .comment, fill: fill)
                x += w + Self.columnGap
            }
        }
        svg.add("rect", [("x", n(r.minX)), ("y", n(r.minY)), ("width", n(r.width)), ("height", n(r.height)), ("rx", n(Self.corner)),
                         ("fill", "none"), ("stroke", stroke), ("stroke-width", n(st.strokeWidth ?? 1.5)), ("stroke-dasharray", st.dash)])
    }
}
