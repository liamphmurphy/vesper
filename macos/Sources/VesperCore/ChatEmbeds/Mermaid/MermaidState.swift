import CoreGraphics
import Foundation

/// `stateDiagram` / `stateDiagram-v2`: states with descriptions, transitions with labels, `[*]`
/// start and end pseudo-states per composite, `<<choice>>`/`<<fork>>`/`<<join>>`, composite states
/// as nested clusters, `--` concurrent regions (each its own invisible cluster, with a dashed
/// divider drawn between them), notes beside a state, `direction`, and
/// `classDef`/`class`/`style`/`:::` colours.
struct MermaidState {
    enum Kind { case normal, start, end, choice, fork, join, composite, note }

    struct State {
        var id: String
        var label: String
        var descriptions: [String] = []
        var kind: Kind = .normal
        var classes: [String] = []
        var style = MermaidStyle()
    }

    struct Transition {
        var from: String
        var to: String
        var label: String?
    }

    enum NoteSide { case left, right }

    struct Note {
        var id: String
        var state: String
        var side: NoteSide
    }

    var direction: MermaidGraphInput.Direction = .down
    var states: [String: State] = [:]
    var order: [String] = []
    /// The container (composite state or concurrent region) each state or region sits in.
    var parentOf: [String: String] = [:]
    /// Concurrent regions of a composite, in source order. A composite without `--` has none and
    /// holds its states directly.
    var regions: [String: [String]] = [:]
    var transitions: [Transition] = []
    var notes: [Note] = []
    var classDefs: [String: MermaidStyle] = [:]

    // MARK: Parsing

    /// An open `state X {` block: the composite, and the container its statements go into (the
    /// composite itself, or its current region after a `--`).
    struct Scope {
        var composite: String
        var container: String
        var line: Int
    }

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidState {
        var s = MermaidState()
        var stack: [Scope] = []
        var openNote: (note: Note, line: Int, text: [String])?
        var skippingBlock = false
        var statements: [MermaidLine] = []
        // Note bodies are free text, so `;` only separates statements outside them; split lazily.
        var pending = doc.lines[...]
        if !doc.headerRest.isEmpty {
            pending = ([MermaidLine(number: doc.headerLine, text: doc.headerRest)] + doc.lines)[...]
        }
        while true {
            let stmt: MermaidLine
            if !statements.isEmpty {
                stmt = statements.removeFirst()
            } else if let next = pending.popFirst() {
                if openNote != nil {
                    stmt = next
                } else {
                    statements = MermaidScan.splitTopLevel(next.text, separators: [";"]).map { MermaidLine(number: next.number, text: $0) }
                    continue
                }
            } else {
                break
            }
            let t = stmt.text
            if var n = openNote {
                if t.lowercased() == "end note" {
                    s.addNote(n.note, text: n.text.joined(separator: "\n"))
                    openNote = nil
                } else {
                    n.text.append(t)
                    openNote = n
                }
                continue
            }
            if skippingBlock {
                if t.contains("}") { skippingBlock = false }
                continue
            }
            let container = stack.last?.container
            if t == "}" {
                guard !stack.isEmpty else { throw .syntax(line: stmt.number, message: "\"}\" without a composite state") }
                stack.removeLast()
                continue
            }
            if t.allSatisfy({ $0 == "-" }), t.count >= 2 {
                guard let top = stack.last else { throw .syntax(line: stmt.number, message: "\"--\" outside a composite state") }
                stack[stack.count - 1].container = s.addRegion(to: top.composite)
                continue
            }
            if let rest = MermaidScan.keyword(t, "direction") {
                if stack.isEmpty, let d = MermaidGraphInput.Direction(mermaid: rest) { s.direction = d }
                continue
            }
            if let rest = MermaidScan.keyword(t, "classDef") {
                let (names, css) = MermaidScan.firstWord(rest)
                let style = MermaidStyle(css: css)
                for n in names.split(separator: ",") { s.classDefs[String(n)] = style }
                continue
            }
            if let rest = MermaidScan.keyword(t, "class") {
                let (ids, cls) = MermaidScan.firstWord(rest)
                for id in ids.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
                    s.touch(id, in: container)
                    s.states[id]?.classes.append(cls)
                }
                continue
            }
            if let rest = MermaidScan.keyword(t, "style") {
                let (id, css) = MermaidScan.firstWord(rest)
                guard !id.isEmpty else { continue }
                s.touch(id, in: container)
                let base = s.states[id]?.style ?? MermaidStyle()
                s.states[id]?.style = MermaidStyle(css: css).merged(over: base)
                continue
            }
            if t.hasPrefix("accTitle") || t.hasPrefix("accDescr") || t.hasPrefix("click ")
                || MermaidScan.keyword(t, "hide") != nil || MermaidScan.keyword(t, "scale") != nil {
                if t.hasPrefix("accDescr"), t.contains("{"), !t.contains("}") { skippingBlock = true }
                continue
            }
            if let rest = MermaidScan.keyword(t, "note") {
                if let parsed = try s.parseNote(rest, line: stmt.number, container: container) {
                    if let text = parsed.text {
                        s.addNote(parsed.note, text: text)
                    } else {
                        openNote = (parsed.note, stmt.number, [])
                    }
                }
                continue
            }
            if let rest = MermaidScan.keyword(t, "state") {
                if let composite = try s.parseStateDeclaration(rest, line: stmt.number, container: container) {
                    stack.append(Scope(composite: composite, container: composite, line: stmt.number))
                }
                continue
            }
            if let arrow = t.range(of: "-->"), Self.descriptionColon(t).map({ $0 > arrow.lowerBound }) ?? true {
                try s.parseTransition(t, arrow: arrow, line: stmt.number, scope: stack.last)
                continue
            }
            try s.parseStateLine(t, line: stmt.number, container: container)
        }
        if let n = openNote { throw .syntax(line: n.line, message: "note isn't closed with end note") }
        if let top = stack.last { throw .syntax(line: top.line, message: "composite state \"\(top.composite)\" isn't closed with }") }
        guard !s.states.isEmpty else { throw .syntax(line: doc.headerLine, message: "the diagram has no states") }
        let clusters = s.regions.values.reduce(0) { $0 + $1.count }
        guard s.states.count + clusters + s.notes.count <= NativeMermaid.maxNodes,
              s.transitions.count <= NativeMermaid.maxEdges else { throw .tooLarge }
        s.dropTransitionsIntoOwnComposite()
        return s
    }

    /// The `:` that starts a description, skipping `:::class` markers.
    static func descriptionColon(_ t: String) -> String.Index? {
        var i = t.startIndex
        while i < t.endIndex {
            if t[i] == ":" {
                if t[i...].hasPrefix(":::") { i = t.index(i, offsetBy: 3); continue }
                return i
            }
            i = t.index(after: i)
        }
        return nil
    }

    /// Letters, digits and `_`, `-`, `.`: mermaid's state ids, which can't hold spaces.
    static func isValidID(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// `id` or `id:::class`, as written on either side of a transition or alone.
    static func reference(_ s: String, line: Int) throws(NativeMermaidError) -> (String, String?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.components(separatedBy: ":::")
        let id = parts[0].trimmingCharacters(in: .whitespaces)
        let cls = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        guard id == "[*]" || isValidID(id) else {
            throw .syntax(line: line, message: id.isEmpty ? "expected a state" : "\"\(id)\" isn't a state name")
        }
        return (id, cls.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Records a state the first time it's seen, in the container it first appears in.
    mutating func touch(_ id: String, in container: String?, kind: Kind = .normal) {
        if states[id] == nil {
            states[id] = State(id: id, label: id, kind: kind)
            order.append(id)
        }
        if let container, parentOf[id] == nil, id != container { parentOf[id] = container }
    }

    /// `[*]` is a start when a transition leaves it and an end when one arrives, one of each per
    /// composite or region, as mermaid scopes them.
    mutating func pseudoState(start: Bool, container: String?) -> String {
        let id = "\u{1F}\(start ? "start" : "end")\u{1F}\(container ?? "")"
        touch(id, in: container, kind: start ? .start : .end)
        return id
    }

    /// Starts a new concurrent region in `composite`, moving what it held so far into the first.
    mutating func addRegion(to composite: String) -> String {
        var list = regions[composite] ?? []
        if list.isEmpty {
            let first = "\u{1F}region\u{1F}\(composite)\u{1F}0"
            for (child, parent) in parentOf where parent == composite { parentOf[child] = first }
            // `[*]` ids are keyed by container: rename the composite's so the new region owns them.
            for start in [true, false] {
                let old = "\u{1F}\(start ? "start" : "end")\u{1F}\(composite)"
                if let st = states[old] {
                    let new = "\u{1F}\(start ? "start" : "end")\u{1F}\(first)"
                    states[old] = nil
                    states[new] = State(id: new, label: st.label, kind: st.kind)
                    order = order.map { $0 == old ? new : $0 }
                    parentOf[new] = first
                    parentOf[old] = nil
                    for i in transitions.indices {
                        if transitions[i].from == old { transitions[i].from = new }
                        if transitions[i].to == old { transitions[i].to = new }
                    }
                }
            }
            list.append(first)
            parentOf[first] = composite
        }
        let next = "\u{1F}region\u{1F}\(composite)\u{1F}\(list.count)"
        list.append(next)
        parentOf[next] = composite
        regions[composite] = list
        return next
    }

    /// `state "Long name" as id [{]`, `state id <<choice>>`, `state id {`, `state id : text`.
    /// Returns the composite id when the declaration opens a block.
    mutating func parseStateDeclaration(_ rest: String, line: Int, container: String?) throws(NativeMermaidError) -> String? {
        var t = rest.trimmingCharacters(in: .whitespaces)
        var opens = false
        if t.hasSuffix("{") {
            opens = true
            t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var label: String?
        var id: String
        var cls: String?
        var after = ""
        if t.hasPrefix("\"") {
            guard let close = t.dropFirst().firstIndex(of: "\"") else { throw .syntax(line: line, message: "a quoted state name isn't closed") }
            label = String(t[t.index(after: t.startIndex)..<close])
            let tail = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let asRest = MermaidScan.keyword(tail, "as") else { throw .syntax(line: line, message: "expected state \"name\" as id") }
            (id, after) = MermaidScan.firstWord(asRest)
        } else {
            (id, after) = MermaidScan.firstWord(t)
            if let colon = Self.descriptionColon(id) {
                after = String(id[colon...]) + " " + after
                id = String(id[..<colon])
            }
            if let asRest = MermaidScan.keyword(after, "as") {
                // `state id as "Long name"` is mermaid's other order.
                label = MermaidText.unquote(asRest)
                after = ""
            }
        }
        (id, cls) = try Self.reference(id, line: line)
        guard id != "[*]" else { throw .syntax(line: line, message: "[*] can't be declared as a state") }
        touch(id, in: container)
        if let label { states[id]?.label = label }
        if let cls { states[id]?.classes.append(cls) }
        after = after.trimmingCharacters(in: .whitespaces)
        if after.hasPrefix("<<"), after.hasSuffix(">>") {
            switch after.dropFirst(2).dropLast(2).lowercased() {
            case "choice": states[id]?.kind = .choice
            case "fork": states[id]?.kind = .fork
            case "join": states[id]?.kind = .join
            default: break
            }
        } else if after.hasPrefix(":") {
            let text = after.dropFirst().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { states[id]?.descriptions.append(text) }
        } else if !after.isEmpty {
            throw .syntax(line: line, message: "unexpected \"\(after.prefix(24))\" after the state")
        }
        if opens { states[id]?.kind = .composite }
        return opens ? id : nil
    }

    /// `id`, `id:::class` or `id : description` (several description lines accumulate).
    mutating func parseStateLine(_ t: String, line: Int, container: String?) throws(NativeMermaidError) {
        var head = t
        var text: String?
        if let colon = Self.descriptionColon(t) {
            head = String(t[..<colon])
            text = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard !head.trimmingCharacters(in: .whitespaces).contains(" ") else {
            throw .syntax(line: line, message: "expected a state or a transition like A --> B")
        }
        let (id, cls) = try Self.reference(head, line: line)
        guard id != "[*]" else { throw .syntax(line: line, message: "[*] needs a transition") }
        touch(id, in: container)
        if let cls { states[id]?.classes.append(cls) }
        if let text, !text.isEmpty { states[id]?.descriptions.append(text) }
    }

    /// `a --> b` or `a --> b : label`, either end `[*]` or with `:::class`.
    mutating func parseTransition(_ t: String, arrow: Range<String.Index>, line: Int, scope: Scope?) throws(NativeMermaidError) {
        let lhs = String(t[..<arrow.lowerBound])
        var rhs = String(t[arrow.upperBound...])
        var label: String?
        if let colon = Self.descriptionColon(rhs) {
            label = rhs[rhs.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            rhs = String(rhs[..<colon])
        }
        guard !lhs.trimmingCharacters(in: .whitespaces).isEmpty, !rhs.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw .syntax(line: line, message: "a transition needs a state on both ends")
        }
        let container = scope?.container
        let (a, aCls) = try Self.reference(lhs, line: line)
        let (b, bCls) = try Self.reference(rhs, line: line)
        let from = a == "[*]" ? pseudoState(start: true, container: container) : a
        let to = b == "[*]" ? pseudoState(start: false, container: container) : b
        if a != "[*]" { touch(a, in: container) }
        if b != "[*]" { touch(b, in: container) }
        if let aCls { states[from]?.classes.append(aCls) }
        if let bCls { states[to]?.classes.append(bCls) }
        transitions.append(Transition(from: from, to: to, label: label.flatMap { $0.isEmpty ? nil : $0 }))
    }

    /// `left of X : text`, `right of X` (a block until `end note`), or a floating `"text" as N`.
    /// Returns the note and its one-line text (nil text: the body follows), or nil for a floating
    /// note already added.
    mutating func parseNote(_ rest: String, line: Int, container: String?) throws(NativeMermaidError) -> (note: Note, text: String?)? {
        if rest.hasPrefix("\"") {
            guard let close = rest.dropFirst().firstIndex(of: "\"") else { throw .syntax(line: line, message: "a quoted note isn't closed") }
            let text = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let id = MermaidScan.keyword(tail, "as"), Self.isValidID(id) else { throw .syntax(line: line, message: "expected note \"text\" as id") }
            touch(id, in: container, kind: .note)
            states[id]?.label = text
            return nil
        }
        let side: NoteSide
        var body: String
        if let r = MermaidScan.keyword(rest, "left of") {
            side = .left; body = r
        } else if let r = MermaidScan.keyword(rest, "right of") {
            side = .right; body = r
        } else {
            throw .syntax(line: line, message: "a note goes left of or right of a state")
        }
        var text: String?
        if let colon = Self.descriptionColon(body) {
            text = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            body = String(body[..<colon])
        }
        let (target, _) = try Self.reference(body, line: line)
        guard target != "[*]" else { throw .syntax(line: line, message: "a note needs a state") }
        touch(target, in: container)
        let note = Note(id: "\u{1F}note\u{1F}\(notes.count)", state: target, side: side)
        return (note, text)
    }

    mutating func addNote(_ note: Note, text: String) {
        notes.append(note)
        states[note.id] = State(id: note.id, label: text, kind: .note)
    }

    /// A transition between a composite and something inside it has no layered drawing.
    mutating func dropTransitionsIntoOwnComposite() {
        let kept = transitions.filter { t in
            !((states[t.from]?.kind == .composite && isInside(t.to, t.from)) || (states[t.to]?.kind == .composite && isInside(t.from, t.to)))
        }
        transitions = kept
    }

    func isInside(_ id: String, _ composite: String) -> Bool {
        var p = parentOf[id]
        var guardCount = 0
        while let q = p, guardCount < 64 {
            if q == composite { return true }
            p = parentOf[q]
            guardCount += 1
        }
        return false
    }

    // MARK: Drawing

    static let pseudoSize = 16.0
    static let barLength = 72.0
    static let barThickness = 8.0
    static let choiceSize = 28.0

    func style(_ s: State) -> MermaidStyle {
        var out = classDefs["default"] ?? MermaidStyle()
        for cls in s.classes { if let d = classDefs[cls] { out = d.merged(over: out) } }
        return s.style.merged(over: out)
    }

    /// The title and description lines of a state box.
    private func textLines(_ s: State) -> (title: [String], description: [String]) {
        let title = MermaidText.wrap(MermaidText.lines(s.label), maxWidth: 280)
        let description = MermaidText.wrap(s.descriptions.flatMap { MermaidText.lines($0) }, maxWidth: 280)
        return (title, description)
    }

    private func nodeSize(_ s: State) -> CGSize {
        let lh = MermaidText.lineHeight()
        let horizontal = direction == .right || direction == .left
        switch s.kind {
        case .start, .end: return CGSize(width: Self.pseudoSize, height: Self.pseudoSize)
        case .choice: return CGSize(width: Self.choiceSize, height: Self.choiceSize)
        case .fork, .join:
            return horizontal ? CGSize(width: Self.barThickness, height: Self.barLength) : CGSize(width: Self.barLength, height: Self.barThickness)
        case .note:
            let lines = MermaidText.wrap(MermaidText.lines(s.label), maxWidth: 200)
            return CGSize(width: MermaidText.width(lines: lines) + 20, height: lh * Double(lines.count) + 14)
        case .normal, .composite:
            let (title, description) = textLines(s)
            let w = max(MermaidText.width(lines: title), MermaidText.width(lines: description)) + MermaidShape.padX * 2
            var h = lh * Double(title.count) + MermaidShape.padY * 2
            if !description.isEmpty { h += lh * Double(description.count) + 10 }
            return CGSize(width: max(w, 56), height: h)
        }
    }

    private func headerHeight(_ s: State) -> Double {
        let (title, description) = textLines(s)
        return MermaidText.lineHeight() * Double(title.count + description.count) + 22
    }

    func draw(_ theme: MermaidTheme, title: String?) throws(NativeMermaidError) -> MermaidDrawing {
        var input = MermaidGraphInput()
        input.direction = direction
        let lh = MermaidText.lineHeight()

        // A state with notes shares an invisible cluster with them, so the layout keeps each note
        // beside its state (left notes first, so before it in the cross-layer order).
        var noteGroup: [String: String] = [:]
        for n in notes where noteGroup[n.state] == nil { noteGroup[n.state] = "\u{1F}notes\u{1F}\(n.state)" }
        func layoutParent(_ id: String) -> String? { noteGroup[id] ?? parentOf[id] }

        var added: Set<String> = []
        func addNotes(of id: String, side: NoteSide) {
            for n in notes where n.state == id && n.side == side {
                guard let s = states[n.id] else { continue }
                input.add(MermaidGraphInput.Node(id: n.id, size: nodeSize(s), parent: noteGroup[id]))
            }
        }
        func addCluster(_ id: String) {
            guard !added.contains(id) else { return }
            added.insert(id)
            if let group = noteGroup.first(where: { $0.value == id }) {
                if let p = parentOf[group.key] { addCluster(p) }
                input.add(MermaidGraphInput.Cluster(id: id, parent: parentOf[group.key], header: 0, minWidth: 0))
                return
            }
            if let p = layoutParent(id) { addCluster(p) }
            if let s = states[id] {
                addNotes(of: id, side: .left)
                let (titleLines, description) = textLines(s)
                input.add(MermaidGraphInput.Cluster(id: id, parent: layoutParent(id), header: headerHeight(s),
                                                    minWidth: max(MermaidText.width(lines: titleLines), MermaidText.width(lines: description)) + 32))
                addNotes(of: id, side: .right)
            } else {
                // A concurrent region: no title, just room around its states.
                input.add(MermaidGraphInput.Cluster(id: id, parent: layoutParent(id), header: 8, minWidth: 40))
            }
        }
        for id in order {
            guard let s = states[id] else { continue }
            if s.kind == .composite { addCluster(id); continue }
            if let p = layoutParent(id) { addCluster(p) }
            addNotes(of: id, side: .left)
            input.add(MermaidGraphInput.Node(id: id, size: nodeSize(s), parent: layoutParent(id)))
            addNotes(of: id, side: .right)
        }
        for (_, list) in regions.sorted(by: { $0.key < $1.key }) { for r in list { addCluster(r) } }

        var edgeLabels: [Int: [String]] = [:]
        for (i, t) in transitions.enumerated() {
            var size: CGSize?
            if let label = t.label {
                let lines = MermaidText.wrap(MermaidText.lines(label), maxWidth: 200)
                edgeLabels[i] = lines
                size = CGSize(width: MermaidText.width(lines: lines) + 8, height: lh * Double(lines.count) + 4)
            }
            input.edges.append(MermaidGraphInput.Edge(id: "e\(i)", source: t.from, target: t.to, label: size))
        }
        let layout = try MermaidLayered.layout(input, diagram: "stateDiagram")

        var svg = MermaidSVG(theme: theme)
        let size = svg.beginDiagram(content: layout.size, title: title)
        let depthOf: (String) -> Int = { id in
            var d = 0, p = parentOf[id]
            while let q = p, d < 64 { d += 1; p = parentOf[q] }
            return d
        }
        let composites = order.filter { states[$0]?.kind == .composite }
        for id in composites.sorted(by: { (depthOf($0), $0) < (depthOf($1), $1) }) {
            guard let s = states[id], let r = layout.clusters[id] else { continue }
            let st = style(s)
            let stroke = st.stroke ?? theme.nodeStroke
            svg.rect(r, rx: 6, fill: st.fill ?? theme.clusterFill, stroke: stroke, strokeWidth: st.strokeWidth ?? 1, dash: st.dash)
            let (titleLines, description) = textLines(s)
            svg.lines(titleLines + description, x: r.midX, top: r.minY + 6, fill: st.color)
            let divider = r.minY + lh * Double(titleLines.count + description.count) + 12
            svg.line(CGPoint(x: r.minX, y: divider), CGPoint(x: r.maxX, y: divider), stroke: stroke, width: 1)
            // Concurrent regions are separated by dashed lines through the gap between them.
            let boxes = (regions[id] ?? []).compactMap { layout.clusters[$0] }
            for (a, b) in zip(boxes, boxes.dropFirst()) {
                if b.minX >= a.maxX - 1 {
                    let x = (a.maxX + b.minX) / 2
                    svg.line(CGPoint(x: x, y: divider), CGPoint(x: x, y: r.maxY), stroke: theme.clusterStroke, width: 1, dash: "5 4")
                } else {
                    let y = (a.maxY + b.minY) / 2
                    svg.line(CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y), stroke: theme.clusterStroke, width: 1, dash: "5 4")
                }
            }
        }

        var frames: [CGRect] = []
        for id in order {
            guard let s = states[id], s.kind != .composite, let r = layout.nodes[id] else { continue }
            drawState(&svg, s, in: r, theme: theme)
            frames.append(r)
        }
        for n in notes {
            guard let s = states[n.id], let r = layout.nodes[n.id] else { continue }
            drawState(&svg, s, in: r, theme: theme)
            frames.append(r)
            // A dashed tie from the note to the facing side of its state.
            guard let target = layout.nodes[n.state] ?? layout.clusters[n.state] else { continue }
            let (a, b): (CGPoint, CGPoint)
            if r.maxX <= target.minX {
                (a, b) = (CGPoint(x: r.maxX, y: r.midY), CGPoint(x: target.minX, y: r.midY))
            } else if r.minX >= target.maxX {
                (a, b) = (CGPoint(x: r.minX, y: r.midY), CGPoint(x: target.maxX, y: r.midY))
            } else if r.maxY <= target.minY {
                (a, b) = (CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.midX, y: target.minY))
            } else {
                (a, b) = (CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: target.maxY))
            }
            svg.line(a, b, stroke: theme.noteStroke, width: 1, dash: "3 3")
        }

        for (i, t) in transitions.enumerated() {
            guard var pts = layout.edges["e\(i)"], pts.count >= 2 else { continue }
            if let s = states[t.from], let r = layout.nodes[t.from], let o = Self.outline(s, r) { MermaidLayered.clip(&pts, atEnd: false, to: o) }
            if let s = states[t.to], let r = layout.nodes[t.to], let o = Self.outline(s, r) { MermaidLayered.clip(&pts, atEnd: true, to: o) }
            svg.edge(pts, stroke: theme.line, width: 1.5, end: .arrow)
        }
        for i in transitions.indices {
            guard let lines = edgeLabels[i], let r = layout.labels["e\(i)"] else { continue }
            svg.edgeLabel(lines, in: r)
        }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), nodeFrames: frames, texts: svg.texts)
    }

    static func outline(_ s: State, _ r: CGRect) -> [CGPoint]? {
        switch s.kind {
        case .start, .end: MermaidShape.circle.outline(r)
        case .choice: MermaidShape.rhombus.outline(r)
        default: nil
        }
    }

    private func drawState(_ svg: inout MermaidSVG, _ s: State, in r: CGRect, theme: MermaidTheme) {
        let st = style(s)
        let lh = MermaidText.lineHeight()
        let n = MermaidSVG.num
        switch s.kind {
        case .start:
            svg.add("circle", [("cx", n(r.midX)), ("cy", n(r.midY)), ("r", n(r.width / 2)), ("fill", st.fill ?? theme.text)])
        case .end:
            svg.add("circle", [("cx", n(r.midX)), ("cy", n(r.midY)), ("r", n(r.width / 2)), ("fill", theme.background),
                               ("stroke", st.stroke ?? theme.text), ("stroke-width", "1.5")])
            svg.add("circle", [("cx", n(r.midX)), ("cy", n(r.midY)), ("r", n(r.width / 2 - 4)), ("fill", st.fill ?? theme.text)])
        case .choice:
            MermaidShape.rhombus.draw(&svg, r, fill: st.fill ?? theme.nodeFill, stroke: st.stroke ?? theme.nodeStroke,
                                      width: st.strokeWidth ?? 1.5, dash: st.dash)
        case .fork, .join:
            svg.rect(r, rx: 2, fill: st.fill ?? theme.text)
        case .note:
            svg.rect(r, rx: 2, fill: theme.noteFill, stroke: theme.noteStroke, strokeWidth: 1)
            let lines = MermaidText.wrap(MermaidText.lines(s.label), maxWidth: 200)
            svg.lines(lines, x: r.midX, top: r.midY - lh * Double(lines.count) / 2)
        case .normal, .composite:
            let stroke = st.stroke ?? theme.nodeStroke
            svg.rect(r, rx: 6, fill: st.fill ?? theme.nodeFill, stroke: stroke, strokeWidth: st.strokeWidth ?? 1.5, dash: st.dash)
            let (title, description) = textLines(s)
            if description.isEmpty {
                svg.lines(title, x: r.midX, top: r.midY - lh * Double(title.count) / 2, bold: st.bold, fill: st.color)
            } else {
                let top = r.minY + MermaidShape.padY
                svg.lines(title, x: r.midX, top: top, bold: st.bold, fill: st.color)
                let divider = top + lh * Double(title.count) + 5
                svg.line(CGPoint(x: r.minX, y: divider), CGPoint(x: r.maxX, y: divider), stroke: stroke, width: 1)
                svg.lines(description, x: r.midX, top: divider + 5, fill: st.color)
            }
        }
    }
}
