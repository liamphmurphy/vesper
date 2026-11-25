import CoreGraphics
import Foundation

/// `classDiagram` / `classDiagram-v2`: classes as three-compartment boxes (name, attributes,
/// methods) with `<<annotations>>`, `~generic~` types, visibility, abstract (italic) and static
/// (underlined) members; every UML relation with its marker on the end it's written on, dashed for
/// `..`, cardinalities beside each end and a label in the middle; `namespace` blocks as clusters;
/// `note for X` and floating notes; `direction`; and `classDef`/`cssClass`/`:::`/`style` colours.
///
/// Simplified next to mermaid.js: `click`/`link`/`callback` are ignored (a chat picture has nothing
/// to click), long member lines aren't wrapped, and cardinalities are placed beside each end rather
/// than routed around neighbouring edges.
struct MermaidClass {
    struct Member {
        var text: String
        var isAbstract = false
        var isStatic = false
    }

    struct Box {
        var id: String
        var label: String?
        var generic: String?
        var annotations: [String] = []
        var attributes: [Member] = []
        var methods: [Member] = []
        var namespace: String?
        var classes: [String] = []
        var style = MermaidStyle()
    }

    /// What a relation draws at one end.
    enum End {
        case none, inheritance, composition, aggregation, arrow, lollipop

        var marker: MermaidMarker? {
            switch self {
            case .none: nil
            case .inheritance: .triangle
            case .composition: .diamondFilled
            case .aggregation: .diamondHollow
            case .arrow: .openArrow
            case .lollipop: .circle
            }
        }
    }

    struct Relation {
        var from: String
        var to: String
        var fromEnd: End
        var toEnd: End
        var dashed: Bool
        var fromCardinality: String?
        var toCardinality: String?
        var label: String?
    }

    struct Note {
        var id: String
        var target: String?
        var text: String
    }

    var direction: MermaidGraphInput.Direction = .down
    var boxes: [String: Box] = [:]
    var order: [String] = []
    var namespaces: [String] = []
    var namespaceParent: [String: String] = [:]
    var relations: [Relation] = []
    var notes: [Note] = []
    var classDefs: [String: MermaidStyle] = [:]

    // MARK: Parsing

    /// An open `class X {` body: members go to `id` until its `}`.
    struct OpenBody {
        var id: String
        var line: Int
    }

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidClass {
        var c = MermaidClass()
        var namespaceStack: [(name: String, line: Int)] = []
        var body: OpenBody?
        var skippingBlock = false
        var statements: [MermaidLine] = []
        // Member lines are free text (`;` can sit in a signature), so statements are only split
        // on `;` outside class bodies; split lazily as the body state is known.
        var pending = doc.lines[...]
        let header = doc.headerRest.trimmingCharacters(in: CharacterSet(charactersIn: "; \t"))
        if !header.isEmpty {
            pending = ([MermaidLine(number: doc.headerLine, text: header)] + doc.lines)[...]
        }
        while true {
            let stmt: MermaidLine
            if !statements.isEmpty {
                stmt = statements.removeFirst()
            } else if let next = pending.popFirst() {
                if body != nil {
                    stmt = next
                } else {
                    statements = MermaidScan.splitTopLevel(next.text, separators: [";"]).map { MermaidLine(number: next.number, text: $0) }
                    continue
                }
            } else {
                break
            }
            let t = stmt.text
            if let open = body {
                var member = t
                let closes = member.hasSuffix("}")
                if closes { member = String(member.dropLast()).trimmingCharacters(in: .whitespaces) }
                if !member.isEmpty { c.addMember(member, to: open.id) }
                if closes { body = nil }
                continue
            }
            if skippingBlock {
                if t.contains("}") { skippingBlock = false }
                continue
            }
            let namespace = namespaceStack.last?.name
            if t == "}" {
                guard !namespaceStack.isEmpty else { throw .syntax(line: stmt.number, message: "\"}\" without a class or namespace") }
                namespaceStack.removeLast()
                continue
            }
            if let rest = MermaidScan.keyword(t, "direction") {
                if let d = MermaidGraphInput.Direction(mermaid: rest) { c.direction = d }
                continue
            }
            if let rest = MermaidScan.keyword(t, "classDef") {
                let (names, css) = MermaidScan.firstWord(rest)
                let style = MermaidStyle(css: css)
                for n in names.split(separator: ",") { c.classDefs[String(n)] = style }
                continue
            }
            if let rest = MermaidScan.keyword(t, "cssClass") {
                try c.parseCSSClass(rest, line: stmt.number, namespace: namespace)
                continue
            }
            if let rest = MermaidScan.keyword(t, "style") {
                let (id, css) = MermaidScan.firstWord(rest)
                guard !id.isEmpty else { continue }
                c.touch(id, namespace: namespace)
                let base = c.boxes[id]?.style ?? MermaidStyle()
                c.boxes[id]?.style = MermaidStyle(css: css).merged(over: base)
                continue
            }
            // `click`/`link`/`callback` only when the line isn't a relation or member of a class
            // that happens to have one of those names.
            let interaction = ["click", "link", "callback"].contains { MermaidScan.keyword(t, $0) != nil }
                && Self.findRelation(t) == nil && MermaidState.descriptionColon(t) == nil
            if t.hasPrefix("accTitle") || t.hasPrefix("accDescr") || interaction {
                if t.hasPrefix("accDescr"), t.contains("{"), !t.contains("}") { skippingBlock = true }
                continue
            }
            if let rest = MermaidScan.keyword(t, "namespace") {
                guard rest.hasSuffix("{") else { throw .syntax(line: stmt.number, message: "expected namespace Name {") }
                let name = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { throw .syntax(line: stmt.number, message: "expected namespace Name {") }
                if !c.namespaces.contains(name) {
                    c.namespaces.append(name)
                    if let namespace { c.namespaceParent[name] = namespace }
                }
                namespaceStack.append((name, stmt.number))
                continue
            }
            if let rest = MermaidScan.keyword(t, "note") {
                try c.parseNote(rest, line: stmt.number, namespace: namespace)
                continue
            }
            if let rest = MermaidScan.keyword(t, "class") {
                if let id = try c.parseClassDeclaration(rest, line: stmt.number, namespace: namespace) {
                    body = OpenBody(id: id, line: stmt.number)
                }
                continue
            }
            if t.hasPrefix("<<") {
                try c.parseAnnotation(t, line: stmt.number, namespace: namespace)
                continue
            }
            let colon = MermaidState.descriptionColon(t)
            if let op = Self.findRelation(t), colon.map({ $0 > op.lineStart }) ?? true {
                try c.parseRelation(t, op: op, line: stmt.number, namespace: namespace)
                continue
            }
            if let colon {
                // `A : +field` adds one member.
                let ref = try Self.reference(String(t[..<colon]), line: stmt.number)
                c.declare(ref, namespace: namespace)
                let member = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !member.isEmpty { c.addMember(member, to: ref.id) }
                continue
            }
            guard !t.contains(" ") else {
                throw .syntax(line: stmt.number, message: "expected a class, a member or a relation like A <|-- B")
            }
            c.declare(try Self.reference(t, line: stmt.number), namespace: namespace)
        }
        if let open = body { throw .syntax(line: open.line, message: "class \"\(open.id)\" isn't closed with }") }
        if let top = namespaceStack.last { throw .syntax(line: top.line, message: "namespace \"\(top.name)\" isn't closed with }") }
        guard !c.boxes.isEmpty else { throw .syntax(line: doc.headerLine, message: "the diagram has no classes") }
        guard c.boxes.count + c.namespaces.count + c.notes.count <= NativeMermaid.maxNodes,
              c.relations.count + c.notes.count <= NativeMermaid.maxEdges else { throw .tooLarge }
        return c
    }

    /// A class as written: its id, and the optional `~generic~`, `["label"]` and `:::class`.
    struct Reference {
        var id: String
        var generic: String?
        var label: String?
        var cssClass: String?
    }

    /// Letters, digits and `_`, `-`, `.`: mermaid's class names. Anything else goes in backticks.
    static func isValidID(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// `Name`, `` `Any name` ``, `Name~T~`, `Name["Label"]`, each optionally with `:::class`.
    static func reference(_ s: String, line: Int) throws(NativeMermaidError) -> Reference {
        var t = s.trimmingCharacters(in: .whitespaces)
        var cssClass: String?
        if let r = t.range(of: ":::") {
            let cls = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            cssClass = cls.isEmpty ? nil : cls
            t = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        var label: String?
        if t.hasSuffix("]"), let open = t.range(of: "[") {
            label = MermaidText.unquote(String(t[open.upperBound..<t.index(before: t.endIndex)]))
            t = t[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        if t.count >= 2, t.hasPrefix("`"), t.hasSuffix("`") {
            let id = String(t.dropFirst().dropLast())
            guard !id.trimmingCharacters(in: .whitespaces).isEmpty else { throw .syntax(line: line, message: "expected a class") }
            return Reference(id: id, label: label, cssClass: cssClass)
        }
        var generic: String?
        if let first = t.firstIndex(of: "~") {
            if let last = t.lastIndex(of: "~"), last > first {
                generic = String(t[t.index(after: first)..<last])
            }
            t = String(t[..<first])
        }
        guard isValidID(t) else {
            throw .syntax(line: line, message: t.isEmpty ? "expected a class" : "\"\(t.prefix(24))\" isn't a class name")
        }
        return Reference(id: t, generic: generic, label: label, cssClass: cssClass)
    }

    /// Records a class the first time it's seen, in the namespace it first appears in.
    mutating func touch(_ id: String, namespace: String?) {
        guard boxes[id] == nil else { return }
        boxes[id] = Box(id: id, namespace: namespace)
        order.append(id)
    }

    mutating func declare(_ ref: Reference, namespace: String?) {
        touch(ref.id, namespace: namespace)
        if let g = ref.generic { boxes[ref.id]?.generic = g }
        if let l = ref.label { boxes[ref.id]?.label = l }
        if let cls = ref.cssClass { boxes[ref.id]?.classes.append(cls) }
    }

    /// `class Name[~T~]["Label"][:::cls] [{ members… }]`. Returns the class id when a body opens on
    /// this line and continues below it.
    mutating func parseClassDeclaration(_ rest: String, line: Int, namespace: String?) throws(NativeMermaidError) -> String? {
        var head = rest
        var inline: String?
        if let brace = rest.firstIndex(of: "{") {
            head = String(rest[..<brace])
            inline = String(rest[rest.index(after: brace)...]).trimmingCharacters(in: .whitespaces)
        }
        let ref = try Self.reference(head, line: line)
        declare(ref, namespace: namespace)
        guard var body = inline else { return nil }
        let closes = body.hasSuffix("}")
        if closes { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
        if !body.isEmpty { addMember(body, to: ref.id) }
        return closes ? nil : ref.id
    }

    /// `<<interface>> Name`, or `<<interface>>` alone inside a body (handled by `addMember`).
    mutating func parseAnnotation(_ t: String, line: Int, namespace: String?) throws(NativeMermaidError) {
        guard let close = t.range(of: ">>") else { throw .syntax(line: line, message: "an annotation isn't closed with >>") }
        let name = String(t[t.index(t.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        let target = t[close.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { throw .syntax(line: line, message: "expected <<annotation>> ClassName") }
        let ref = try Self.reference(target, line: line)
        declare(ref, namespace: namespace)
        if !name.isEmpty { boxes[ref.id]?.annotations.append(name) }
    }

    /// `cssClass "A,B" styleName`.
    mutating func parseCSSClass(_ rest: String, line: Int, namespace: String?) throws(NativeMermaidError) {
        var ids: String
        var cls: String
        if rest.hasPrefix("\"") {
            guard let close = rest.dropFirst().firstIndex(of: "\"") else { throw .syntax(line: line, message: "a quoted class list isn't closed") }
            ids = String(rest[rest.index(after: rest.startIndex)..<close])
            cls = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
        } else {
            (ids, cls) = MermaidScan.firstWord(rest)
        }
        guard !cls.isEmpty else { throw .syntax(line: line, message: "expected cssClass \"A,B\" styleName") }
        for id in ids.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
            touch(id, namespace: namespace)
            boxes[id]?.classes.append(cls)
        }
    }

    /// `note for Name "text"` or a floating `note "text"`.
    mutating func parseNote(_ rest: String, line: Int, namespace: String?) throws(NativeMermaidError) {
        var target: String?
        var text = rest
        if let r = MermaidScan.keyword(rest, "for") {
            let (id, after) = MermaidScan.firstWord(r)
            let ref = try Self.reference(id, line: line)
            touch(ref.id, namespace: namespace)
            target = ref.id
            text = after
        }
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else {
            throw .syntax(line: line, message: "expected note \"text\" or note for Class \"text\"")
        }
        // Mermaid's class notes take a literal `\n` as a line break as well as `<br>`.
        let body = MermaidText.unquote(text).replacingOccurrences(of: "\\n", with: "<br>")
        notes.append(Note(id: "\u{1F}note\u{1F}\(notes.count)", target: target, text: body))
    }

    /// One body line: an `<<annotation>>`, a method (it has a `(`) or an attribute.
    mutating func addMember(_ raw: String, to id: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<<"), t.hasSuffix(">>"), t.count > 4 {
            boxes[id]?.annotations.append(String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces))
            return
        }
        let m = Self.member(t)
        if t.contains("(") {
            boxes[id]?.methods.append(m)
        } else {
            boxes[id]?.attributes.append(m)
        }
    }

    /// A member's display text: the trailing `*` (abstract) or `$` (static) classifier removed and
    /// kept as a flag, `~T~` shown as `<T>`, and a method's return type after ` : ` as mermaid
    /// shows it.
    static func member(_ raw: String) -> Member {
        var t = MermaidText.collapse(MermaidText.decodeEntities(raw))
        var m = Member(text: "")
        if t.hasSuffix("$") { m.isStatic = true; t.removeLast() } else if t.hasSuffix("*") { m.isAbstract = true; t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        var visibility = ""
        if let first = t.first, "+-#~".contains(first) {
            visibility = String(first)
            t.removeFirst()
        }
        if let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")"), close > open {
            let name = String(t[..<open])
            let params = String(t[t.index(after: open)..<close])
            var ret = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
            // `method()$ int` also carries the classifier straight after the parentheses.
            if ret.hasPrefix("$") { m.isStatic = true; ret.removeFirst() } else if ret.hasPrefix("*") { m.isAbstract = true; ret.removeFirst() }
            ret = ret.trimmingCharacters(in: .whitespaces)
            m.text = visibility + generics(name) + "(" + generics(params) + ")" + (ret.isEmpty ? "" : " : " + generics(ret))
        } else {
            m.text = visibility + generics(t)
        }
        return m
    }

    /// `List~List~int~~` → `List<List<int>>`: a `~` before a name opens a type argument, any other
    /// `~` inside one closes it. A stray `~` is kept.
    static func generics(_ s: String) -> String {
        guard s.contains("~") else { return s }
        let chars = Array(s)
        var out = ""
        var depth = 0
        for (i, ch) in chars.enumerated() {
            guard ch == "~" else { out.append(ch); continue }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let opens = next.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "?" } ?? false
            if opens {
                out.append("<")
                depth += 1
            } else if depth > 0 {
                out.append(">")
                depth -= 1
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Where a relation's operator sits: the `--`/`..` run and the end markers either side of it.
    struct RelationOperator {
        var start: String.Index
        var lineStart: String.Index
        var end: String.Index
        var fromEnd: End
        var toEnd: End
        var dashed: Bool
    }

    /// The first `--` or `..` outside quotes and backticks, with its end markers: `<|`, `*`, `o`,
    /// `<` or `()` before it and `|>`, `*`, `o`, `>` or `()` after. A bare `o` only counts as a
    /// marker when it stands apart from the class name.
    static func findRelation(_ t: String) -> RelationOperator? {
        let chars = Array(t)
        var quoted = false, ticked = false
        var i = 0
        while i + 1 < chars.count {
            let ch = chars[i]
            if ch == "\"", !ticked { quoted.toggle() }
            if ch == "`", !quoted { ticked.toggle() }
            guard !quoted, !ticked, (ch == "-" || ch == "."), chars[i + 1] == ch else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j] == ch { j += 1 }
            let separates: (Int) -> Bool = { k in k < 0 || k >= chars.count || chars[k] == " " || chars[k] == "\t" || chars[k] == "\"" }
            var start = i
            var from = End.none
            if i >= 2, chars[i - 2] == "<", chars[i - 1] == "|" { from = .inheritance; start = i - 2 }
            else if i >= 2, chars[i - 2] == "(", chars[i - 1] == ")" { from = .lollipop; start = i - 2 }
            else if i >= 1, chars[i - 1] == "*" { from = .composition; start = i - 1 }
            else if i >= 1, chars[i - 1] == "<" { from = .arrow; start = i - 1 }
            else if i >= 1, chars[i - 1] == "o", separates(i - 2) { from = .aggregation; start = i - 1 }
            var end = j
            var to = End.none
            if j + 1 < chars.count, chars[j] == "|", chars[j + 1] == ">" { to = .inheritance; end = j + 2 }
            else if j + 1 < chars.count, chars[j] == "(", chars[j + 1] == ")" { to = .lollipop; end = j + 2 }
            else if j < chars.count, chars[j] == "*" { to = .composition; end = j + 1 }
            else if j < chars.count, chars[j] == ">" { to = .arrow; end = j + 1 }
            else if j < chars.count, chars[j] == "o", separates(j + 1) { to = .aggregation; end = j + 1 }
            let idx = { (k: Int) in t.index(t.startIndex, offsetBy: k) }
            return RelationOperator(start: idx(start), lineStart: idx(i), end: idx(end), fromEnd: from, toEnd: to, dashed: ch == ".")
        }
        return nil
    }

    /// `A ["card"] op ["card"] B [: label]`.
    mutating func parseRelation(_ t: String, op: RelationOperator, line: Int, namespace: String?) throws(NativeMermaidError) {
        var lhs = t[..<op.start].trimmingCharacters(in: .whitespaces)
        var rhs = String(t[op.end...])
        var label: String?
        if let colon = MermaidState.descriptionColon(rhs) {
            label = rhs[rhs.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            rhs = String(rhs[..<colon])
        }
        rhs = rhs.trimmingCharacters(in: .whitespaces)
        var fromCard: String?, toCard: String?
        if lhs.hasSuffix("\""), let open = lhs.dropLast().lastIndex(of: "\"") {
            fromCard = String(lhs[lhs.index(after: open)..<lhs.index(before: lhs.endIndex)])
            lhs = lhs[..<open].trimmingCharacters(in: .whitespaces)
        }
        if rhs.hasPrefix("\""), let close = rhs.dropFirst().firstIndex(of: "\"") {
            toCard = String(rhs[rhs.index(after: rhs.startIndex)..<close])
            rhs = rhs[rhs.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        guard !lhs.isEmpty, !rhs.isEmpty else { throw .syntax(line: line, message: "a relation needs a class on both ends") }
        let a = try Self.reference(lhs, line: line)
        let b = try Self.reference(rhs, line: line)
        declare(a, namespace: namespace)
        declare(b, namespace: namespace)
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        relations.append(Relation(from: a.id, to: b.id, fromEnd: op.fromEnd, toEnd: op.toEnd, dashed: op.dashed,
                                  fromCardinality: nonEmpty(fromCard), toCardinality: nonEmpty(toCard), label: nonEmpty(label)))
    }

    // MARK: Drawing

    static let minWidth = 96.0
    static let headerPad = 8.0
    static let compartmentPad = 6.0
    /// Height of a compartment with no members, so an empty class still shows all three.
    static let emptyCompartment = 10.0
    static let noteWidth = 200.0
    static let cardinalitySize = MermaidText.smallSize

    func style(_ b: Box) -> MermaidStyle {
        var out = classDefs["default"] ?? MermaidStyle()
        for cls in b.classes { if let d = classDefs[cls] { out = d.merged(over: out) } }
        return b.style.merged(over: out)
    }

    /// The name lines: the label or id with its type parameters. `~` becomes `<>` after markup is
    /// reduced, so `List<T>` isn't taken for a tag.
    func nameLines(_ b: Box) -> [String] {
        var name = b.label ?? b.id
        if let g = b.generic { name += "~\(g)~" }
        return MermaidText.wrap(MermaidText.lines(name).map(Self.generics), maxWidth: 320, bold: true)
    }

    func annotationLines(_ b: Box) -> [String] {
        b.annotations.map { "«\(MermaidText.collapse($0))»" }
    }

    private func compartmentHeight(_ members: [Member]) -> Double {
        members.isEmpty ? Self.emptyCompartment : MermaidText.lineHeight() * Double(members.count) + Self.compartmentPad * 2
    }

    private func headerHeight(_ b: Box) -> Double {
        Self.headerPad * 2 + MermaidText.lineHeight(MermaidText.smallSize) * Double(b.annotations.count)
            + MermaidText.lineHeight() * Double(nameLines(b).count)
    }

    func boxSize(_ b: Box) -> CGSize {
        let memberWidth = (b.attributes + b.methods).map { MermaidText.width($0.text, italic: $0.isAbstract) }.max() ?? 0
        let w = max(MermaidText.width(lines: nameLines(b), bold: true),
                    MermaidText.width(lines: annotationLines(b), size: MermaidText.smallSize), memberWidth) + MermaidShape.padX * 2
        let h = headerHeight(b) + compartmentHeight(b.attributes) + compartmentHeight(b.methods)
        return CGSize(width: max(w, Self.minWidth), height: h)
    }

    func noteLines(_ n: Note) -> [String] {
        MermaidText.wrap(MermaidText.lines(n.text), maxWidth: Self.noteWidth)
    }

    func noteSize(_ n: Note) -> CGSize {
        let lines = noteLines(n)
        return CGSize(width: MermaidText.width(lines: lines) + 20, height: MermaidText.lineHeight() * Double(lines.count) + 14)
    }

    static func clusterID(_ namespace: String) -> String { "\u{1F}ns\u{1F}\(namespace)" }

    func draw(_ theme: MermaidTheme, title: String?) throws(NativeMermaidError) -> MermaidDrawing {
        var input = MermaidGraphInput()
        input.direction = direction
        let lh = MermaidText.lineHeight()
        // Cardinalities sit beside each end of an edge, so layers need room for two of them.
        let hasCardinalities = relations.contains(where: { $0.fromCardinality != nil || $0.toCardinality != nil })
        if hasCardinalities { input.layerSpacing = 64 }
        // A chip on an edge entering a class at the top of a namespace would sit on the title, so
        // the header grows by a chip's height below it.
        let titleLine = lh + 12
        let titleBand = titleLine + (hasCardinalities ? MermaidText.lineHeight(Self.cardinalitySize) + 6 : 0)

        var added: Set<String> = []
        func addNamespace(_ ns: String) {
            guard !added.contains(ns) else { return }
            added.insert(ns)
            if let p = namespaceParent[ns] { addNamespace(p) }
            input.add(MermaidGraphInput.Cluster(id: Self.clusterID(ns), parent: namespaceParent[ns].map(Self.clusterID),
                                                header: titleBand, minWidth: MermaidText.width(ns, bold: true) + 32))
        }
        for id in order {
            guard let b = boxes[id] else { continue }
            if let ns = b.namespace { addNamespace(ns) }
            input.add(MermaidGraphInput.Node(id: id, size: boxSize(b), parent: b.namespace.map(Self.clusterID)))
        }
        for n in notes {
            let parent = n.target.flatMap { boxes[$0]?.namespace }.map(Self.clusterID)
            input.add(MermaidGraphInput.Node(id: n.id, size: noteSize(n), parent: parent))
        }

        var edgeLabels: [Int: [String]] = [:]
        for (i, r) in relations.enumerated() {
            var size: CGSize?
            if let label = r.label {
                let lines = MermaidText.wrap(MermaidText.lines(label), maxWidth: 200)
                edgeLabels[i] = lines
                size = CGSize(width: MermaidText.width(lines: lines) + 8, height: lh * Double(lines.count) + 4)
            }
            input.edges.append(MermaidGraphInput.Edge(id: "e\(i)", source: r.from, target: r.to, label: size))
        }
        for (i, n) in notes.enumerated() {
            guard let target = n.target else { continue }
            input.edges.append(MermaidGraphInput.Edge(id: "n\(i)", source: n.id, target: target, label: nil))
        }
        let layout = try MermaidLayered.layout(input, diagram: "classDiagram")

        // Cardinality chips can reach past the laid-out area at the diagram's edge, so the canvas
        // grows to hold them.
        // Each chip takes the first of its candidate spots that's clear of boxes, labels, namespace
        // titles, other edges, their markers and chips already placed.
        var obstacles: [CGRect] = Array(layout.nodes.values) + Array(layout.labels.values)
        for ns in namespaces {
            guard let r = layout.clusters[Self.clusterID(ns)] else { continue }
            obstacles.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: titleLine))
        }
        var routes: [(id: String, pts: [CGPoint])] = []
        for (i, r) in relations.enumerated() {
            guard let pts = layout.edges["e\(i)"], pts.count >= 2 else { continue }
            routes.append(("e\(i)", pts))
            if r.fromEnd != .none, let p = pts.first { obstacles.append(CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)) }
            if r.toEnd != .none, let p = pts.last { obstacles.append(CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)) }
        }
        for i in notes.indices { if let pts = layout.edges["n\(i)"], pts.count >= 2 { routes.append(("n\(i)", pts)) } }
        var cardinalities: [(lines: [String], rect: CGRect)] = []
        for (i, r) in relations.enumerated() {
            guard let pts = layout.edges["e\(i)"], pts.count >= 2 else { continue }
            for (text, atEnd) in [(r.fromCardinality, false), (r.toCardinality, true)] {
                guard let text else { continue }
                let (lines, candidates) = Self.cardinalityCandidates(text, at: pts, atEnd: atEnd)
                func hits(_ c: CGRect) -> Int {
                    obstacles.filter { $0.intersects(c) }.count
                        + routes.filter { $0.id != "e\(i)" && Self.polyline($0.pts, intersects: c) }.count
                }
                let rect = candidates.first(where: { hits($0) == 0 }) ?? candidates.min(by: { hits($0) < hits($1) }) ?? candidates[0]
                cardinalities.append((lines, rect))
                obstacles.append(rect)
            }
        }
        let content = cardinalities.reduce(CGRect(origin: .zero, size: layout.size)) { $0.union($1.rect) }

        var svg = MermaidSVG(theme: theme)
        let size = svg.beginDiagram(content: content.size, title: title)
        let shifted = content.minX < 0 || content.minY < 0
        if shifted { svg.open("g", [("transform", "translate(\(MermaidSVG.num(-content.minX)) \(MermaidSVG.num(-content.minY)))")]) }

        let depthOf: (String) -> Int = { ns in
            var d = 0, p = namespaceParent[ns]
            while let q = p, d < 64 { d += 1; p = namespaceParent[q] }
            return d
        }
        for ns in namespaces.sorted(by: { (depthOf($0), $0) < (depthOf($1), $1) }) {
            guard let r = layout.clusters[Self.clusterID(ns)] else { continue }
            svg.rect(r, rx: 6, fill: theme.clusterFill, stroke: theme.clusterStroke, strokeWidth: 1)
            svg.text(ns, x: r.midX, y: r.minY + 6 + lh / 2, bold: true)
        }

        for (i, r) in relations.enumerated() {
            guard let pts = layout.edges["e\(i)"], pts.count >= 2 else { continue }
            svg.edge(pts, stroke: theme.line, width: 1.5, dash: r.dashed ? "6 4" : nil, start: r.fromEnd.marker, end: r.toEnd.marker)
        }
        for i in notes.indices {
            guard let pts = layout.edges["n\(i)"], pts.count >= 2 else { continue }
            svg.path(MermaidSVG.roundedPath(pts), stroke: theme.noteStroke, strokeWidth: 1, dash: "3 3")
        }

        var frames: [CGRect] = []
        for id in order {
            guard let b = boxes[id], let r = layout.nodes[id] else { continue }
            drawBox(&svg, b, in: r, theme: theme)
            frames.append(r)
        }
        for n in notes {
            guard let r = layout.nodes[n.id] else { continue }
            svg.rect(r, rx: 2, fill: theme.noteFill, stroke: theme.noteStroke, strokeWidth: 1)
            let lines = noteLines(n)
            svg.lines(lines, x: r.midX, top: r.midY - lh * Double(lines.count) / 2)
            frames.append(r)
        }

        for i in relations.indices {
            guard let lines = edgeLabels[i], let r = layout.labels["e\(i)"] else { continue }
            svg.edgeLabel(lines, in: r)
        }
        for c in cardinalities {
            svg.edgeLabel(c.lines, in: c.rect, size: Self.cardinalitySize)
        }
        if shifted { svg.close("g") }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), nodeFrames: frames, texts: svg.texts)
    }

    /// Where a cardinality chip may go beside one end of an edge, best first: just off the box
    /// along the edge and to the right of a vertical end segment (above a horizontal one), then the
    /// other side, then both sides a chip further along. Every spot is clear of the end's marker.
    static func cardinalityCandidates(_ text: String, at pts: [CGPoint], atEnd: Bool) -> (lines: [String], rects: [CGRect]) {
        let lines = MermaidText.lines(text)
        let w = MermaidText.width(lines: lines, size: cardinalitySize) + 8
        let h = MermaidText.lineHeight(cardinalitySize) * Double(lines.count) + 2
        let ordered = atEnd ? Array(pts.reversed()) : pts
        let p = ordered[0]
        let q = ordered.dropFirst().first(where: { $0 != p }) ?? p
        let len = max(hypot(q.x - p.x, q.y - p.y), 0.001)
        let d = CGPoint(x: (q.x - p.x) / len, y: (q.y - p.y) / len)
        let vertical = abs(d.y) >= abs(d.x)
        // Half a marker's width (the triangle is 16) plus a gap keeps the chip off the marker.
        let near = 3 + (vertical ? h / 2 : w / 2)
        let far = near + (vertical ? h : w) + 4
        var rects: [CGRect] = []
        for along in [near, far] {
            for side in [1.0, -1.0] {
                let center = vertical
                    ? CGPoint(x: p.x + side * (11 + w / 2), y: p.y + d.y * along)
                    : CGPoint(x: p.x + d.x * along, y: p.y - side * (11 + h / 2))
                rects.append(CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
            }
        }
        return (lines, rects)
    }

    /// Whether an orthogonal route (ELK's) passes through `r`, segment by segment.
    static func polyline(_ pts: [CGPoint], intersects r: CGRect) -> Bool {
        zip(pts, pts.dropFirst()).contains { a, b in
            CGRect(x: min(a.x, b.x) - 1, y: min(a.y, b.y) - 1, width: abs(b.x - a.x) + 2, height: abs(b.y - a.y) + 2).intersects(r)
        }
    }

    private func drawBox(_ svg: inout MermaidSVG, _ b: Box, in r: CGRect, theme: MermaidTheme) {
        let st = style(b)
        let lh = MermaidText.lineHeight()
        let slh = MermaidText.lineHeight(MermaidText.smallSize)
        let stroke = st.stroke ?? theme.nodeStroke
        svg.rect(r, rx: 3, fill: st.fill ?? theme.nodeFill, stroke: stroke, strokeWidth: st.strokeWidth ?? 1.5, dash: st.dash)
        var y = r.minY + Self.headerPad
        for a in annotationLines(b) {
            svg.text(a, x: r.midX, y: y + slh / 2, size: MermaidText.smallSize, fill: st.color)
            y += slh
        }
        for line in nameLines(b) {
            svg.text(line, x: r.midX, y: y + lh / 2, bold: true, fill: st.color)
            y += lh
        }
        y += Self.headerPad
        for members in [b.attributes, b.methods] {
            svg.line(CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y), stroke: stroke, width: 1)
            guard !members.isEmpty else { y += Self.emptyCompartment; continue }
            y += Self.compartmentPad
            for m in members {
                svg.text(m.text, x: r.minX + MermaidShape.padX, y: y + lh / 2, anchor: "start",
                         italic: m.isAbstract, underline: m.isStatic, fill: st.color)
                y += lh
            }
            y += Self.compartmentPad
        }
    }
}
