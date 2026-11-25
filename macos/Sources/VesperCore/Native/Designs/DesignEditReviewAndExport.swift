import CoreGraphics
import Foundation

// MARK: - Design Tree Edits & Hit Testing (parity with edit.ts & hit.ts)

public struct DesignFound: Sendable {
    public var node: DesignNode
    public var parentId: String?
    public var pageId: String
    public var index: Int
    public var depth: Int
}

public struct DesignDevicePreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let w: Double
    public let h: Double
}

public enum DesignEditLogic: Sendable {
    public static let presets: [DesignDevicePreset] = [
        .init(id: "iphone-15", label: "iPhone 15", w: 393, h: 852),
        .init(id: "iphone-15-pro-max", label: "iPhone 15 Pro Max", w: 430, h: 932),
        .init(id: "android", label: "Android", w: 412, h: 915),
        .init(id: "ipad", label: "iPad", w: 820, h: 1180),
        .init(id: "desktop", label: "Desktop", w: 1440, h: 900),
        .init(id: "web", label: "Web", w: 1280, h: 800),
    ]

    public static func find(_ d: DesignDocument, id: String) -> DesignFound? {
        for page in d.pages {
            func go(_ list: [DesignNode], parentId: String?, depth: Int) -> DesignFound? {
                for (i, n) in list.enumerated() {
                    if n.id == id { return DesignFound(node: n, parentId: parentId, pageId: page.id, index: i, depth: depth) }
                    if let ch = n.children, let hit = go(ch, parentId: n.id, depth: depth + 1) { return hit }
                }
                return nil
            }
            if let hit = go(page.children, parentId: nil, depth: 0) { return hit }
        }
        return nil
    }

    public static func ancestors(_ d: DesignDocument, id: String) -> [DesignNode] {
        var out: [DesignNode] = []
        var cur = find(d, id: id)
        while let pid = cur?.parentId, let parent = find(d, id: pid) {
            out.append(parent.node)
            cur = parent
        }
        return out
    }

    public static func mapTree(_ d: DesignDocument, _ fn: (DesignNode) -> DesignNode?) -> DesignDocument {
        func mapList(_ list: [DesignNode]) -> [DesignNode] {
            var out: [DesignNode] = []
            for n in list {
                guard var m = fn(n) else { continue }
                if let ch = m.children { m.children = mapList(ch) }
                out.append(m)
            }
            return out
        }
        var out = d
        for i in out.pages.indices { out.pages[i].children = mapList(out.pages[i].children) }
        return out
    }

    public static func mapNode(_ d: DesignDocument, id: String, _ fn: (DesignNode) -> DesignNode) -> DesignDocument {
        mapTree(d) { $0.id == id ? fn($0) : $0 }
    }

    public static func mapPage(_ d: DesignDocument, pageId: String, _ fn: (DesignPage) -> DesignPage) -> DesignDocument {
        var out = d
        for i in out.pages.indices where out.pages[i].id == pageId { out.pages[i] = fn(out.pages[i]) }
        return out
    }

    public static func subtreeIds(_ n: DesignNode) -> Set<String> {
        var ids: Set<String> = [n.id]
        for c in n.children ?? [] { ids.formUnion(subtreeIds(c)) }
        return ids
    }

    public static func removeNodes(_ d: DesignDocument, ids: Set<String>) -> DesignDocument {
        var gone = Set<String>()
        for id in ids { if let f = find(d, id: id) { gone.formUnion(subtreeIds(f.node)) } }
        guard !gone.isEmpty else { return d }
        var changed = true
        while changed {
            changed = false
            _ = mapTree(d) { n in
                if n.type == .instance, !gone.contains(n.id), let comp = n.component, gone.contains(comp) {
                    gone.formUnion(subtreeIds(n))
                    changed = true
                }
                return n
            }
        }
        var out = mapTree(d) { n in
            if gone.contains(n.id) { return nil }
            if n.type == .connector, let f = n.from?.node, let t = n.to?.node, gone.contains(f) || gone.contains(t) { return nil }
            if n.type == .instance, let ov = n.overrides {
                var m = n
                let kept = ov.filter { !gone.contains($0.key) }
                m.overrides = kept.isEmpty ? nil : kept
                return m
            }
            return n
        }
        out.links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
        return out
    }

    public static func insertNodes(_ d: DesignDocument, parent: String, nodes: [DesignNode], at index: Int? = nil) -> DesignDocument {
        func put(_ list: [DesignNode]) -> [DesignNode] {
            var res = list
            let i = index.map { max(0, min($0, list.count)) } ?? list.count
            res.insert(contentsOf: nodes, at: i)
            return res
        }
        if d.pages.contains(where: { $0.id == parent }) {
            return mapPage(d, pageId: parent) { var p = $0; p.children = put(p.children); return p }
        }
        return mapNode(d, id: parent) { n in
            guard n.children != nil else { return n }
            var m = n; m.children = put(m.children ?? []); return m
        }
    }

    public static func cloneFresh(_ n: DesignNode) -> DesignNode {
        var idMap: [String: String] = [:]
        func assign(_ m: DesignNode) {
            idMap[m.id] = DesignSchema.newId(prefix: "n")
            for c in m.children ?? [] { assign(c) }
        }
        assign(n)
        func copy(_ m: DesignNode) -> DesignNode {
            var c = m
            c.id = idMap[m.id] ?? DesignSchema.newId(prefix: "n")
            if let ch = m.children { c.children = ch.map(copy) }
            if c.type == .connector {
                if var f = c.from { f.node = idMap[f.node] ?? f.node; c.from = f }
                if var t = c.to { t.node = idMap[t.node] ?? t.node; c.to = t }
            }
            return c
        }
        return copy(n)
    }

    public static func duplicateNodes(_ d: DesignDocument, ids: [String], offset: Double = 24) -> (design: DesignDocument, ids: [String]) {
        var out = d
        var made: [String] = []
        for id in ids {
            guard let f = find(out, id: id), f.node.type != .connector else { continue }
            var c = cloneFresh(f.node)
            let parentInAutoLayout = f.parentId.flatMap { find(out, id: $0)?.node.autoLayout } != nil
            if !parentInAutoLayout { c.x += offset; c.y += offset }
            out = insertNodes(out, parent: f.parentId ?? f.pageId, nodes: [c], at: f.index + 1)
            made.append(c.id)
        }
        return (out, made)
    }

    public static func reorder(_ d: DesignDocument, ids: Set<String>, op: SlideZOrder) -> DesignDocument {
        func reorderList(_ list: [DesignNode]) -> [DesignNode] {
            var out = list
            switch op {
            case .front: out = list.filter { !ids.contains($0.id) } + list.filter { ids.contains($0.id) }
            case .back: out = list.filter { ids.contains($0.id) } + list.filter { !ids.contains($0.id) }
            case .forward:
                if out.count >= 2 {
                    for i in stride(from: out.count - 2, through: 0, by: -1) where ids.contains(out[i].id) && !ids.contains(out[i + 1].id) {
                        out.swapAt(i, i + 1)
                    }
                }
            case .backward:
                if out.count >= 2 {
                    for i in 1..<out.count where ids.contains(out[i].id) && !ids.contains(out[i - 1].id) {
                        out.swapAt(i, i - 1)
                    }
                }
            }
            return out
        }
        var out = d
        for i in out.pages.indices { out.pages[i].children = reorderList(out.pages[i].children) }
        return mapTree(out) { n in
            guard let ch = n.children else { return n }
            var m = n; m.children = reorderList(ch); return m
        }
    }

    public static func resizeNode(_ n: DesignNode, to b: DesignBox) -> DesignNode {
        guard n.type != .connector else { return n }
        let nw = max(1, DesignSchema.round2(b.w))
        let nh = max(1, DesignSchema.round2(b.h))
        var out = n
        out.x = DesignSchema.round2(b.x)
        out.y = DesignSchema.round2(b.y)
        out.w = nw; out.h = nh
        if nw != n.w || nh != n.h {
            if out.type == .group, let kids = n.children, n.w > 0, n.h > 0 {
                let kx = nw / n.w, ky = nh / n.h
                out.children = kids.map { c in
                    c.type == .connector ? c : resizeNode(c, to: DesignBox(x: c.x * kx, y: c.y * ky, w: c.w * kx, h: c.h * ky))
                }
            } else if n.type.isBoard && n.autoLayout == nil, let kids = n.children {
                out.children = kids.map { DesignLayoutEngine.constrain($0, ow: n.w, oh: n.h, nw: nw, nh: nh) }
            }
            if var sz = out.sizing {
                if nw != n.w && sz.w == "hug" { sz.w = nil }
                if nh != n.h && sz.h == "hug" { sz.h = nil }
                out.sizing = (sz.w != nil || sz.h != nil) ? sz : nil
            }
        }
        return out
    }

    public static func groupNodes(_ d: DesignDocument, ids: [String]) -> (design: DesignDocument, id: String)? {
        let settled = DesignLayoutEngine.settle(d)
        let fs = ids.compactMap { find(settled, id: $0) }.filter { $0.node.type != .connector }
        guard fs.count >= 2 else { return nil }
        let parent = fs[0].parentId ?? fs[0].pageId
        guard fs.allSatisfy({ ($0.parentId ?? $0.pageId) == parent }) else { return nil }
        let sorted = fs.sorted { $0.index < $1.index }
        let nodes = sorted.map(\.node)
        let l = nodes.map(\.x).min()!, t = nodes.map(\.y).min()!
        let r = nodes.map { $0.x + $0.w }.max()!, b = nodes.map { $0.y + $0.h }.max()!
        let gid = DesignSchema.newId(prefix: "n")
        let children = nodes.map { n -> DesignNode in var c = n; c.x -= l; c.y -= t; return c }
        let group = DesignNode(id: gid, type: .group, name: "Group", x: l, y: t, w: r - l, h: b - t, children: children)
        let topIdx = sorted.last!.index - (sorted.count - 1)
        let idSet = Set(ids)
        let stripped = mapTree(settled) { idSet.contains($0.id) && $0.type != .connector ? nil : $0 }
        return (insertNodes(stripped, parent: parent, nodes: [group], at: topIdx), gid)
    }

    public static func ungroupNodes(_ d: DesignDocument, ids: [String]) -> (design: DesignDocument, ids: [String]) {
        var out = d
        var freed: [String] = []
        for id in ids {
            guard let f = find(out, id: id), f.node.type == .group else { continue }
            let g = f.node
            let ch = (g.children ?? []).map { c -> DesignNode in
                guard c.type != .connector else { return c }
                var m = c; m.x += g.x; m.y += g.y; return m
            }
            freed.append(contentsOf: ch.map(\.id))
            out = mapTree(out) { $0.id == id ? nil : $0 }
            out = insertNodes(out, parent: f.parentId ?? f.pageId, nodes: ch, at: f.index)
        }
        return (out, freed)
    }

    public static func connectNodes(_ d: DesignDocument, from: String, to: String) -> (design: DesignDocument, id: String)? {
        guard from != to, let a = find(d, id: from), let b = find(d, id: to),
              a.pageId == b.pageId, a.node.type != .connector, b.node.type != .connector else { return nil }
        let bUp = Set(ancestors(d, id: to).map(\.id))
        var container = a.pageId
        for anc in ancestors(d, id: from) where bUp.contains(anc.id) {
            container = anc.id
            break
        }
        while container != a.pageId, let cf = find(d, id: container), cf.node.type == .group {
            container = cf.parentId ?? a.pageId
        }
        let cid = DesignSchema.newId(prefix: "n")
        let conn = DesignNode(id: cid, type: .connector, from: DesignEndpoint(node: from), to: DesignEndpoint(node: to))
        return (insertNodes(d, parent: container, nodes: [conn]), cid)
    }

    public static func pathFrom(points: [DesignPt], closed: Bool, name: String = "Path") -> DesignNode? {
        guard points.count >= 2 else { return nil }
        let x = points.map(\.x).min()!, y = points.map(\.y).min()!
        let w = max(1, points.map(\.x).max()! - x), h = max(1, points.map(\.y).max()! - y)
        let d = points.enumerated().map { i, p in
            "\(i == 0 ? "M" : "L")\(DesignSchema.round2(p.x - x)) \(DesignSchema.round2(p.y - y))"
        }.joined(separator: " ") + (closed ? " Z" : "")
        return DesignNode(
            id: DesignSchema.newId(prefix: "n"), type: .path, name: name,
            x: DesignSchema.round2(x), y: DesignSchema.round2(y), w: DesignSchema.round2(w), h: DesignSchema.round2(h),
            fill: closed ? .color("#D9D9E3") : nil, stroke: "#16161D", strokeWidth: 2,
            d: d, cap: "round", join: "round"
        )
    }

    public static func plainText(_ ps: [DesignParagraph]) -> String {
        ps.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
    }

    public static func withPlainText(_ ps: [DesignParagraph], text: String) -> [DesignParagraph] {
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { i, line in
            let src = ps[min(i, max(0, ps.count - 1))]
            let r0 = src.runs.first ?? DesignRun(text: "", size: 16)
            var r = r0; r.text = line
            var p = src; p.runs = [r]
            return p
        }
    }

    public static func labelOf(_ n: DesignNode) -> String {
        if let name = n.name, !name.isEmpty { return name }
        if n.type == .text {
            let txt = plainText(n.paragraphs ?? []).prefix(40)
            return txt.isEmpty ? "Text" : String(txt)
        }
        if n.type == .shape { return n.shape == "ellipse" ? "Ellipse" : "Rectangle" }
        if n.type == .sticky { return n.author.map { "Sticky \u{00B7} \($0)" } ?? "Sticky" }
        return n.type.rawValue.capitalized
    }

    public static func newFrame(_ b: DesignBox, preset: String? = nil, name: String = "Frame") -> DesignNode {
        DesignNode(id: DesignSchema.newId(prefix: "n"), type: .frame, name: name, x: b.x, y: b.y, w: b.w, h: b.h, fill: .color("#FFFFFF"), children: [], clip: true, preset: preset)
    }

    public static func newShape(_ shape: String, _ b: DesignBox) -> DesignNode {
        DesignNode(id: DesignSchema.newId(prefix: "n"), type: .shape, name: shape == "ellipse" ? "Ellipse" : "Rectangle", x: b.x, y: b.y, w: b.w, h: b.h, fill: .color("#D9D9E3"), shape: shape)
    }

    public static func newText(x: Double, y: Double, text: String = "Text", size: Double = 16) -> DesignNode {
        DesignNode(id: DesignSchema.newId(prefix: "n"), type: .text, name: "Text", x: x, y: y, w: max(60, Double(text.count) * size * 0.6), h: size * 1.4, sizing: DesignSizing(w: "hug", h: "hug"), paragraphs: [DesignParagraph(runs: [DesignRun(text: text, size: size)])])
    }

    public static func newSticky(x: Double, y: Double, text: String = "", author: String? = nil) -> DesignNode {
        DesignNode(id: DesignSchema.newId(prefix: "n"), type: .sticky, x: x, y: y, w: 200, h: 200, stickyText: text, stickyColor: "yellow", author: author)
    }

    public static func newSection(in design: DesignDocument, _ b: DesignBox, name: String = "Section") -> DesignNode {
        let fill = design.mode == .dark ? "#1B1A27" : "#F6F5FA"
        return DesignNode(id: DesignSchema.newId(prefix: "n"), type: .section, name: name, x: b.x, y: b.y, w: b.w, h: b.h, fill: .color(fill), children: [])
    }
}

// MARK: - Hit Testing

public enum DesignHitTest: Sendable {
    public static func hitPath(page: DesignPage, boxes: [String: DesignBox], x: Double, y: Double, slop: Double = 0) -> [DesignNode] {
        func inside(_ b: DesignBox, s: Double) -> Bool {
            x >= b.x - s && x <= b.x + b.w + s && y >= b.y - s && y <= b.y + b.h + s
        }
        func go(_ list: [DesignNode]) -> [DesignNode] {
            for n in list.reversed() {
                if n.type == .connector || n.visible == false || n.locked == true { continue }
                guard let b = boxes[n.id], inside(b, s: n.type == .path ? max(slop, 4) : slop) else { continue }
                let deeper = n.type == .instance ? [] : go(n.children ?? [])
                if !deeper.isEmpty || n.type != .group { return [n] + deeper }
            }
            return []
        }
        return go(page.children)
    }

    public static func pick(path: [DesignNode], selected: [String], deeper: Bool = false, deep: Bool = false) -> DesignNode? {
        guard !path.isEmpty else { return nil }
        if deep { return path.last }
        if deeper, let idx = path.firstIndex(where: { selected.contains($0.id) }) {
            return path[min(idx + 1, path.count - 1)]
        }
        if let sel = path.first(where: { selected.contains($0.id) }) { return sel }
        return path[0].type.isBoard && path.count > 1 ? path[1] : path[0]
    }

    public static func connectTarget(path: [DesignNode]) -> DesignNode? {
        path.reversed().first { $0.type != .section && $0.type != .group } ?? path.last
    }
}

// MARK: - 3-Way Merge (parity with web/lib/designs/merge.ts)

public enum DesignMergeLogic: Sendable {
    public static func mergeDesigns(base: DesignDocument, mine: DesignDocument, theirs: DesignDocument) -> DesignDocument? {
        // Disjoint page-level & node-level merge; returns nil on overlapping edits so user resolves.
        let bS = DesignLayoutEngine.settle(base)
        let mS = DesignLayoutEngine.settle(mine)
        let tS = DesignLayoutEngine.settle(theirs)

        if mS.mode != bS.mode && tS.mode != bS.mode && mS.mode != tS.mode { return nil }
        if mS.tokenSets != bS.tokenSets && tS.tokenSets != bS.tokenSets && mS.tokenSets != tS.tokenSets { return nil }

        let bPages = Dictionary(uniqueKeysWithValues: bS.pages.map { ($0.id, $0) })
        let mPages = Dictionary(uniqueKeysWithValues: mS.pages.map { ($0.id, $0) })
        let tPages = Dictionary(uniqueKeysWithValues: tS.pages.map { ($0.id, $0) })
        var mergedPages: [DesignPage] = []
        let allPageIds = tS.pages.map(\.id) + mS.pages.map(\.id).filter { tPages[$0] == nil }

        for pid in allPageIds {
            let bp = bPages[pid], mp = mPages[pid], tp = tPages[pid]
            if mp == tp {
                if let p = tp { mergedPages.append(p) }
            } else if mp == bp {
                if let p = tp { mergedPages.append(p) }
            } else if tp == bp {
                if let p = mp { mergedPages.append(p) }
            } else if let bp, let mp, let tp {
                guard let mergedKids = mergeNodeList(base: bp.children, mine: mp.children, theirs: tp.children) else { return nil }
                mergedPages.append(DesignPage(id: pid, name: mp.name != bp.name ? mp.name : tp.name, background: mp.background != bp.background ? mp.background : tp.background, children: mergedKids))
            } else {
                return nil
            }
        }
        guard !mergedPages.isEmpty else { return nil }
        var assets = tS.assets
        for (k, v) in mS.assets { assets[k] = v }
        var links = tS.links
        for l in mS.links where !links.contains(where: { $0.id == l.id }) { links.append(l) }
        return DesignLayoutEngine.settle(DesignDocument(
            schema: tS.schema,
            mode: mS.mode != bS.mode ? mS.mode : tS.mode,
            tokensRef: mS.tokensRef != bS.tokensRef ? mS.tokensRef : tS.tokensRef,
            tokenSets: mS.tokenSets != bS.tokenSets ? mS.tokenSets : tS.tokenSets,
            assets: assets,
            pages: mergedPages,
            links: links
        ))
    }

    private static func mergeNodeList(base: [DesignNode], mine: [DesignNode], theirs: [DesignNode]) -> [DesignNode]? {
        let bMap = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let mMap = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
        let tMap = Dictionary(uniqueKeysWithValues: theirs.map { ($0.id, $0) })
        let order = theirs.map(\.id) + mine.map(\.id).filter { tMap[$0] == nil }
        var out: [DesignNode] = []
        for id in order {
            let bn = bMap[id], mn = mMap[id], tn = tMap[id]
            if mn == tn { if let n = tn { out.append(n) } }
            else if mn == bn { if let n = tn { out.append(n) } }
            else if tn == bn { if let n = mn { out.append(n) } }
            else { return nil }
        }
        return out
    }
}

// MARK: - Design Proposal Review (parity with web/lib/designs/review.ts)

public struct DesignReviewChange: Sendable, Identifiable {
    public enum Kind: String, Sendable { case added, changed, removed }
    public let id: Int
    public let op: [String: JSONValue]
    public let kind: Kind
    public let title: String
    public let why: String
    public let target: String?
    public let page: String?
    public let box: DesignBox?
    public let needs: [Int]
}

public struct DesignOpDecision: Sendable, Equatable {
    public var state: API.ResolveDesignProposalBody.DecisionsItem.State
    public var reason: String?

    public init(state: API.ResolveDesignProposalBody.DecisionsItem.State, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}

public enum DesignReviewLogic: Sendable {
    public static func dependencies(ops: [[String: JSONValue]]) -> [[Int]] {
        var createdBy: [String: Int] = [:]
        let refKeys = ["id", "parent", "after", "before", "page", "from", "to", "component", "node"]
        return ops.enumerated().map { j, op in
            let made = creates(op)
            var needs: [Int] = []
            for k in refKeys {
                if let r = op[k]?.stringValue, !made.contains(r), let i = createdBy[r], !needs.contains(i) {
                    needs.append(i)
                }
            }
            for id in made { createdBy[id] = j }
            return needs
        }
    }

    public static func creates(_ op: [String: JSONValue]) -> [String] {
        var out: [String] = []
        func collect(_ val: JSONValue) {
            guard case .object(let o) = val else { return }
            if let id = o["id"]?.stringValue { out.append(id) }
            if case .array(let arr) = o["children"] { arr.forEach(collect) }
        }
        switch op["op"]?.stringValue ?? "" {
        case "add_node": if let n = op["node"] { collect(n) }
        case "add_page": if let p = op["page"] { collect(p) }
        case "connect", "add_sticky", "instantiate", "add_link":
            if let id = op["id"]?.stringValue { out.append(id) }
        default: break
        }
        return out
    }

    public static func decide(deps: [[Int]], decisions: [Int: DesignOpDecision], index i: Int, state: API.ResolveDesignProposalBody.DecisionsItem.State, reason: String? = nil) -> [Int: DesignOpDecision] {
        var out = decisions
        func closure(_ start: Int, next: (Int) -> [Int]) -> Set<Int> {
            var seen = Set<Int>()
            func go(_ x: Int) {
                for k in next(x) where seen.insert(k).inserted { go(k) }
            }
            go(start)
            return seen
        }
        if state == .accepted {
            out[i] = DesignOpDecision(state: .accepted)
            for k in closure(i, next: { $0 < deps.count ? deps[$0] : [] }) {
                out[k] = DesignOpDecision(state: .accepted)
            }
        } else {
            let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            out[i] = DesignOpDecision(state: .rejected, reason: trimmed?.isEmpty == false ? trimmed : nil)
            for k in closure(i, next: { x in deps.indices.filter { deps[$0].contains(x) } }) {
                out[k] = DesignOpDecision(state: .rejected)
            }
        }
        return out
    }

    public static func applyOps(_ d: DesignDocument, ops: [[String: JSONValue]], keep: (Int) -> Bool = { _ in true }) -> DesignDocument {
        var cur = d
        for (i, op) in ops.enumerated() where keep(i) {
            if let next = applyOp(cur, op: op) { cur = next }
        }
        return DesignLayoutEngine.settle(cur)
    }

    private static func applyOp(_ d: DesignDocument, op: [String: JSONValue]) -> DesignDocument? {
        let kind = op["op"]?.stringValue ?? ""
        let id = op["id"]?.stringValue ?? ""
        switch kind {
        case "add_node":
            guard let parent = op["parent"]?.stringValue,
                  let nodeVal = op["node"],
                  let data = try? JSONEncoder().encode(nodeVal),
                  let node = try? JSONDecoder().decode(DesignNode.self, from: data) else { return nil }
            return DesignEditLogic.insertNodes(d, parent: parent, nodes: [node])
        case "remove_node":
            return DesignEditLogic.removeNodes(d, ids: [id])
        case "set_text":
            guard let text = op["text"]?.stringValue else { return nil }
            return DesignEditLogic.mapNode(d, id: id) { n in
                guard n.type == .text else { return n }
                var m = n; m.paragraphs = DesignEditLogic.withPlainText(n.paragraphs ?? [], text: text); return m
            }
        case "move_node":
            return DesignEditLogic.mapNode(d, id: id) { n in
                var m = n
                if let xv = numberValue(op["x"]) { m.x = xv }
                if let yv = numberValue(op["y"]) { m.y = yv }
                return m
            }
        case "add_sticky":
            guard let pageId = op["page"]?.stringValue, let text = op["text"]?.stringValue else { return nil }
            let node = DesignNode(id: id.isEmpty ? DesignSchema.newId(prefix: "n") : id, type: .sticky, x: numberValue(op["x"]) ?? 0, y: numberValue(op["y"]) ?? 0, w: 160, h: 120, stickyText: text, stickyColor: op["color"]?.stringValue ?? "yellow", author: op["author"]?.stringValue)
            return DesignEditLogic.insertNodes(d, parent: pageId, nodes: [node])
        default:
            return nil
        }
    }

    public static func classify(before: DesignDocument, ops: [[String: JSONValue]], deps: [[Int]]? = nil) -> [DesignReviewChange] {
        let resolvedDeps = deps ?? dependencies(ops: ops)
        let after = applyOps(before, ops: ops)
        func allBoxes(_ doc: DesignDocument) -> [String: (box: DesignBox, page: String)] {
            var map: [String: (DesignBox, String)] = [:]
            let eng = DesignLayoutEngine(design: doc)
            for p in doc.pages {
                let laid = eng.layoutPage(p)
                for (id, b) in laid.boxes { map[id] = (b, p.id) }
            }
            return map
        }
        let nowBoxes = allBoxes(before)
        let afterBoxes = allBoxes(after)
        return ops.enumerated().map { i, op in
            let opName = op["op"]?.stringValue ?? "change"
            let id = op["id"]?.stringValue
            let (kind, title, target): (DesignReviewChange.Kind, String, String?) = {
                switch opName {
                case "add_node":
                    let nodeObj = op["node"]
                    let label = nodeObj?["name"]?.stringValue ?? nodeObj?["type"]?.stringValue ?? "layer"
                    return (.added, "Add \(label)", nodeObj?["id"]?.stringValue)
                case "remove_node":
                    let lbl = id.flatMap { DesignEditLogic.find(before, id: $0) }.map { DesignEditLogic.labelOf($0.node) } ?? "layer"
                    return (.removed, "Remove \u{201C}\(lbl)\u{201D}", id)
                case "set_text":
                    let lbl = id.flatMap { DesignEditLogic.find(before, id: $0) }.map { DesignEditLogic.labelOf($0.node) } ?? "text"
                    return (.changed, "Edit text \u{201C}\(lbl)\u{201D}", id)
                case "add_sticky":
                    return (.added, "Add sticky note", id)
                case "connect":
                    return (.added, "Connect nodes", id ?? op["from"]?.stringValue)
                default:
                    let lbl = id.flatMap { DesignEditLogic.find(before, id: $0) }.map { DesignEditLogic.labelOf($0.node) }
                    return (.changed, lbl.map { "\(opName.replacingOccurrences(of: "_", with: " ").capitalized) \u{201C}\($0)\u{201D}" } ?? opName.replacingOccurrences(of: "_", with: " ").capitalized, id)
                }
            }()
            let loc = target.flatMap { kind == .removed ? (nowBoxes[$0] ?? afterBoxes[$0]) : (afterBoxes[$0] ?? nowBoxes[$0]) }
            return DesignReviewChange(
                id: i, op: op, kind: kind, title: title, why: op["why"]?.stringValue ?? "",
                target: target, page: loc?.page ?? op["page"]?.stringValue, box: loc?.box,
                needs: i < resolvedDeps.count ? resolvedDeps[i] : []
            )
        }
    }

    private static func numberValue(_ v: JSONValue?) -> Double? {
        switch v {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
}

// MARK: - Prototype Player (parity with web/lib/designs/prototype.ts)

public struct DesignPrototypeScreen: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let pageId: String
    public let pageName: String
}

public struct DesignPrototypePlayer: Sendable, Equatable {
    public var at: String
    public var back: [String]
    public var start: String

    public init(start: String) {
        self.at = start
        self.back = []
        self.start = start
    }

    public mutating func follow(to: String) {
        guard to != at else { return }
        back.append(at)
        if back.count > 100 { back.removeFirst() }
        at = to
    }

    public mutating func goBack() -> String? {
        guard let prev = back.popLast() else { return nil }
        let from = at
        at = prev
        return from
    }

    public mutating func restart() {
        at = start
        back = []
    }
}

public enum DesignPrototypeLogic: Sendable {
    public static func screens(_ d: DesignDocument) -> [DesignPrototypeScreen] {
        d.pages.flatMap { p in
            p.children.filter { $0.type == .frame }.map {
                DesignPrototypeScreen(id: $0.id, name: $0.name ?? "Frame", pageId: p.id, pageName: p.name)
            }
        }
    }

    public static func screenOf(_ d: DesignDocument, nodeId: String) -> DesignNode? {
        guard let f = DesignEditLogic.find(d, id: nodeId) else { return nil }
        return DesignEditLogic.ancestors(d, id: nodeId).last ?? f.node
    }

    public static func startScreen(_ d: DesignDocument, wanted: String?, pageId: String?) -> DesignPrototypeScreen? {
        let all = screens(d)
        if let wanted, let exact = all.first(where: { $0.id == wanted }) { return exact }
        if let wanted, let owner = screenOf(d, nodeId: wanted), let hit = all.first(where: { $0.id == owner.id }) { return hit }
        if let pageId, let hit = all.first(where: { $0.pageId == pageId }) { return hit }
        return all.first
    }

    public static func hotspotsOf(_ d: DesignDocument, frameId: String) -> [DesignLink] {
        let frameIds = Set(screens(d).map(\.id))
        return d.links.filter { l in
            frameIds.contains(l.to) && screenOf(d, nodeId: l.from)?.id == frameId
        }
    }

    public static func addLink(in d: DesignDocument, from: String) -> (design: DesignDocument, id: String)? {
        let all = screens(d)
        let own = screenOf(d, nodeId: from)?.id
        let to = all.first(where: { $0.id != own }) ?? all.first
        guard let to else { return nil }
        let id = DesignSchema.newId(prefix: "k")
        var out = d
        out.links.append(DesignLink(id: id, from: from, to: to.id, trigger: "click", transition: "dissolve", durationMs: 300))
        return (out, id)
    }
}

// MARK: - Inspect Codegen (CSS / Tailwind / React) & SVG / PDF Exporters

public enum DesignInspectTarget: String, Sendable, CaseIterable {
    case css, tailwind, react

    public var label: String {
        switch self {
        case .css: "CSS"
        case .tailwind: "Tailwind"
        case .react: "React"
        }
    }
}

public enum DesignInspectLogic: Sendable {
    public static func generateCode(design: DesignDocument, node: DesignNode, box: DesignBox, target: DesignInspectTarget) -> String {
        let eng = DesignLayoutEngine(design: design)
        let name = DesignEditLogic.labelOf(node)
        let cls = name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let compName = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()

        var cssLines: [String] = [
            "width: \(DesignSchema.round2(box.w))px;",
            "height: \(DesignSchema.round2(box.h))px;",
        ]
        var twClasses: [String] = [
            "w-[\(Int(box.w.rounded()))px]",
            "h-[\(Int(box.h.rounded()))px]",
        ]
        if let al = node.autoLayout {
            cssLines.append("display: flex;")
            cssLines.append("flex-direction: \(al.direction == "horizontal" ? "row" : "column");")
            twClasses.append("flex")
            twClasses.append(al.direction == "horizontal" ? "flex-row" : "flex-col")
            if let gap = al.gap, gap > 0 {
                cssLines.append("gap: \(Int(gap))px;")
                twClasses.append("gap-[\(Int(gap))px]")
            }
            if let p = al.padding, p.count == 4, p.contains(where: { $0 > 0 }) {
                cssLines.append("padding: \(Int(p[0]))px \(Int(p[1]))px \(Int(p[2]))px \(Int(p[3]))px;")
                twClasses.append("pt-[\(Int(p[0]))px] pr-[\(Int(p[1]))px] pb-[\(Int(p[2]))px] pl-[\(Int(p[3]))px]")
            }
        }
        if let fill = node.fill {
            switch fill {
            case .color(let c):
                let val = c.hasPrefix("$") ? "var(--\(c.dropFirst()))" : (eng.resolveColor(c, mode: design.mode) ?? c)
                cssLines.append("background: \(val);")
                twClasses.append("bg-[\(val)]")
            case .gradient(let g):
                let s0 = g.stops.first ?? "#FFFFFF"
                let s1 = g.stops.dropFirst().first ?? s0
                cssLines.append("background: linear-gradient(\(Int(g.angle))deg, \(s0), \(s1));")
            }
        }
        if let stroke = node.stroke {
            let sw = Int((node.strokeWidth ?? 1).rounded())
            let val = stroke.hasPrefix("$") ? "var(--\(stroke.dropFirst()))" : stroke
            cssLines.append("border: \(sw)px solid \(val);")
            twClasses.append("border border-[\(val)]")
        }
        if let r = node.radius, r > 0 {
            cssLines.append("border-radius: \(Int(r))px;")
            twClasses.append("rounded-[\(Int(r))px]")
        }
        if node.type == .text, let r0 = node.paragraphs?.first?.runs.first {
            cssLines.append("font-family: Inter, sans-serif;")
            cssLines.append("font-size: \(Int(r0.size))px;")
            cssLines.append("font-weight: \(r0.effectiveWeight);")
            twClasses.append("text-[\(Int(r0.size))px]")
        }

        switch target {
        case .css:
            return ".\(cls.isEmpty ? "node" : cls) {\n" + cssLines.map { "  \($0)" }.joined(separator: "\n") + "\n}"
        case .tailwind:
            let content = node.type == .text ? DesignEditLogic.plainText(node.paragraphs ?? []) : ""
            return "<div class=\"\(twClasses.joined(separator: " "))\">\(content)</div>"
        case .react:
            let fnName = compName.isEmpty ? "DesignNode" : compName
            let content = node.type == .text ? DesignEditLogic.plainText(node.paragraphs ?? []) : ""
            return "export function \(fnName)() {\n  return (\n    <div className=\"\(twClasses.joined(separator: " "))\">\(content)</div>\n  );\n}"
        }
    }
}

public enum DesignExporters {
    /// Exports a laid page or frame box + ops to a vector PDF via `CGPDFContext` (1 px = 0.75 pt).
    public static func exportPDF(items: [(box: DesignBox, ops: [DesignDrawOp], background: String?)], images: [String: CGImage]) -> Data {
        let pt = 0.75
        guard let first = items.first else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: max(1, first.box.w * pt), height: max(1, first.box.h * pt))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        for item in items {
            let pw = max(1, item.box.w * pt), ph = max(1, item.box.h * pt)
            var box = CGRect(x: 0, y: 0, width: pw, height: ph)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: ph)
            ctx.scaleBy(x: pt, y: -pt)
            ctx.translateBy(x: -item.box.x, y: -item.box.y)
            if let bg = item.background {
                ctx.setFillColor(SlideCGDrawer.cgColor(bg))
                ctx.fill(item.box.cgRect)
            }
            DesignCGDrawer.draw(ops: item.ops, images: images, in: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Exports ops within `box` to a clean standalone SVG document.
    public static func exportSVG(box: DesignBox, ops: [DesignDrawOp], background: String?) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var defs: [String] = []
        var body: [String] = []
        var gradCount = 0
        var clipCount = 0

        if let bg = background {
            body.append("<rect x=\"\(box.x)\" y=\"\(box.y)\" width=\"\(box.w)\" height=\"\(box.h)\" fill=\"\(bg)\"/>")
        }

        func paintAttr(_ fill: DesignResolvedPaint?) -> String {
            guard let fill else { return "none" }
            switch fill {
            case .color(let c): return c
            case .gradient(let angle, let s0, let s1):
                gradCount += 1
                let gid = "g\(gradCount)"
                let rad = angle * .pi / 180
                let x1 = 0.5 - cos(rad) / 2, y1 = 0.5 - sin(rad) / 2
                let x2 = 0.5 + cos(rad) / 2, y2 = 0.5 + sin(rad) / 2
                defs.append("<linearGradient id=\"\(gid)\" x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\"><stop offset=\"0\" stop-color=\"\(s0)\"/><stop offset=\"1\" stop-color=\"\(s1)\"/></linearGradient>")
                return "url(#\(gid))"
            }
        }

        for op in ops {
            switch op {
            case .clip(let x, let y, let w, let h, let r):
                clipCount += 1
                let cid = "c\(clipCount)"
                defs.append("<clipPath id=\"\(cid)\"><rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" rx=\"\(r)\"/></clipPath>")
                body.append("<g clip-path=\"url(#\(cid))\">")
            case .unclip, .unrotate:
                body.append("</g>")
            case .rotate(let deg, let cx, let cy):
                body.append("<g transform=\"rotate(\(deg) \(cx) \(cy))\">")
            case .rect(let x, let y, let w, let h, let r, let fill, let stroke, let sw, let dash, let op, _):
                let st = stroke.map { " stroke=\"\($0)\" stroke-width=\"\(sw)\"" } ?? ""
                let da = dash.isEmpty ? "" : " stroke-dasharray=\"\(dash.map { String($0) }.joined(separator: " "))\""
                body.append("<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" rx=\"\(r)\" fill=\"\(paintAttr(fill))\"\(st)\(da) opacity=\"\(op)\"/>")
            case .ellipse(let x, let y, let w, let h, let fill, let stroke, let sw, _, let op, _):
                let st = stroke.map { " stroke=\"\($0)\" stroke-width=\"\(sw)\"" } ?? ""
                body.append("<ellipse cx=\"\(x + w / 2)\" cy=\"\(y + h / 2)\" rx=\"\(w / 2)\" ry=\"\(h / 2)\" fill=\"\(paintAttr(fill))\"\(st) opacity=\"\(op)\"/>")
            case .path(let d, _, let fill, let stroke, let sw, _, _, _, let op, _):
                let st = stroke.map { " stroke=\"\($0)\" stroke-width=\"\(sw)\"" } ?? ""
                body.append("<path d=\"\(esc(d))\" fill=\"\(paintAttr(fill))\"\(st) opacity=\"\(op)\"/>")
            case .polyline(let pts, let stroke, let sw, _, _, let op, _):
                let pStr = pts.map { "\($0.x),\($0.y)" }.joined(separator: " ")
                body.append("<polyline points=\"\(pStr)\" fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"\(sw)\" opacity=\"\(op)\"/>")
            case .text(let x, let y, let text, let wt, let it, let sz, let fill, let op, _):
                body.append("<text x=\"\(x)\" y=\"\(y)\" font-family=\"Inter, sans-serif\" font-size=\"\(sz)\" font-weight=\"\(wt)\" font-style=\"\(it ? "italic" : "normal")\" fill=\"\(fill)\" opacity=\"\(op)\">\(esc(text))</text>")
            case .image:
                break
            }
        }
        let defsBlock = defs.isEmpty ? "" : "<defs>\(defs.joined())</defs>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(box.x) \(box.y) \(box.w) \(box.h)" width="\(box.w)" height="\(box.h)">\(defsBlock)\(body.joined())</svg>
        """
    }
}
