import CoreGraphics
import Foundation
import JavaScriptCore

/// A graph to lay out with ELK's layered algorithm: leaf nodes with their drawn sizes, clusters
/// (subgraphs, composite states, namespaces) that contain them, and edges with optional label
/// boxes. Order matters: ELK keeps the model order where it can, so diagrams read in source order.
struct MermaidGraphInput {
    enum Direction: String {
        case down = "DOWN", up = "UP", right = "RIGHT", left = "LEFT"

        /// `TD`/`TB`/`BT`/`LR`/`RL` (and `<`/`>`/`^`/`v`).
        init?(mermaid s: String) {
            switch s.uppercased() {
            case "TD", "TB", "V": self = .down
            case "BT", "^": self = .up
            case "LR", ">": self = .right
            case "RL", "<": self = .left
            default: return nil
            }
        }
    }

    struct Node {
        var id: String
        var size: CGSize
        var parent: String?
        var seq = 0
    }

    struct Cluster {
        var id: String
        var parent: String?
        /// Room at the top for the title.
        var header: Double
        /// At least wide enough for the title.
        var minWidth: Double
        var seq = 0
    }

    struct Edge {
        var id: String
        var source: String
        var target: String
        var label: CGSize?
    }

    var direction: Direction = .down
    var nodes: [Node] = []
    var clusters: [Cluster] = []
    var edges: [Edge] = []
    var nodeSpacing = 32.0
    var layerSpacing = 44.0

    /// Adds in declaration order, which the layout keeps among siblings.
    mutating func add(_ n: Node) {
        var n = n
        n.seq = nodes.count + clusters.count
        nodes.append(n)
    }

    mutating func add(_ c: Cluster) {
        var c = c
        c.seq = nodes.count + clusters.count
        clusters.append(c)
    }
}

/// Where everything went, in absolute coordinates with the origin at the top-left of the content.
struct MermaidGraphLayout {
    var nodes: [String: CGRect] = [:]
    var clusters: [String: CGRect] = [:]
    var edges: [String: [CGPoint]] = [:]
    var labels: [String: CGRect] = [:]
    var size: CGSize = .zero
}

enum MermaidLayered {
    static func layout(_ g: MermaidGraphInput, diagram: String) throws(NativeMermaidError) -> MermaidGraphLayout {
        guard g.nodes.count + g.clusters.count <= NativeMermaid.maxNodes else { throw .tooLarge }
        guard g.edges.count <= NativeMermaid.maxEdges else { throw .tooLarge }

        // ELK ids are namespaced so a node and a cluster can't collide, and edges are numbered.
        func nid(_ id: String) -> String { "n\u{1F}" + id }
        func cid(_ id: String) -> String { "c\u{1F}" + id }
        let clusterIDs = Set(g.clusters.map(\.id))
        func ref(_ id: String) -> String { clusterIDs.contains(id) ? cid(id) : nid(id) }

        // Children keep their declaration order (nodes and clusters interleaved), which ELK's
        // model-order strategy then respects.
        var kids: [String: [(seq: Int, node: Int?, cluster: Int?)]] = [:]
        for (i, n) in g.nodes.enumerated() { kids[n.parent ?? "", default: []].append((n.seq, i, nil)) }
        for (i, c) in g.clusters.enumerated() { kids[c.parent ?? "", default: []].append((c.seq, nil, i)) }
        var visiting: Set<String> = []
        func children(of parent: String) -> [ELKJSONNode] {
            guard !visiting.contains(parent) else { return [] }
            visiting.insert(parent)
            defer { visiting.remove(parent) }
            return (kids[parent] ?? []).sorted { $0.seq < $1.seq }.map { item in
                if let i = item.node {
                    let n = g.nodes[i]
                    return ELKJSONNode(id: nid(n.id), width: n.size.width.rounded(.up), height: n.size.height.rounded(.up))
                }
                let c = g.clusters[item.cluster ?? 0]
                var node = ELKJSONNode(id: cid(c.id))
                node.layoutOptions = [
                    "elk.padding": "[top=\(MermaidSVG.num(c.header)),left=14,bottom=14,right=14]",
                    "elk.nodeSize.constraints": "[MINIMUM_SIZE]",
                    "elk.nodeSize.minimum": "(\(MermaidSVG.num(c.minWidth)),\(MermaidSVG.num(c.header + 20)))",
                ]
                let inner = children(of: c.id)
                if inner.isEmpty {
                    node.width = c.minWidth
                    node.height = c.header + 20
                } else {
                    node.children = inner
                }
                return node
            }
        }
        let edges = g.edges.map { e in
            ELKJSONEdge(id: e.id, sources: [ref(e.source)], targets: [ref(e.target)],
                        labels: e.label.map { [ELKJSONLabel(width: $0.width.rounded(.up), height: $0.height.rounded(.up))] })
        }
        var root = ELKJSONNode(id: "root")
        root.children = children(of: "")
        root.edges = edges
        root.layoutOptions = [
            "elk.algorithm": "layered",
            "elk.direction": g.direction.rawValue,
            "elk.hierarchyHandling": "INCLUDE_CHILDREN",
            "elk.edgeRouting": "ORTHOGONAL",
            "elk.json.shapeCoords": "ROOT",
            "elk.json.edgeCoords": "ROOT",
            "elk.padding": "[top=0,left=0,bottom=0,right=0]",
            "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
            "elk.layered.nodePlacement.bk.fixedAlignment": "BALANCED",
            "elk.edgeLabels.placement": "CENTER",
            "elk.edgeLabels.inline": "true",
            "elk.spacing.nodeNode": MermaidSVG.num(g.nodeSpacing),
            "elk.layered.spacing.nodeNodeBetweenLayers": MermaidSVG.num(g.layerSpacing),
            "elk.spacing.edgeNode": "16",
            "elk.spacing.edgeEdge": "12",
            "elk.layered.spacing.edgeNodeBetweenLayers": "18",
            "elk.layered.spacing.edgeEdgeBetweenLayers": "12",
            "elk.spacing.edgeLabel": "4",
            "elk.spacing.labelNode": "6",
            "elk.randomSeed": "1",
        ]

        let laid: ELKJSONNode
        do {
            laid = try MermaidELK.shared.layout(root)
        } catch {
            throw .unsupportedDiagram(diagram)
        }

        var out = MermaidGraphLayout()
        func visit(_ n: ELKJSONNode) {
            let r = CGRect(x: n.x ?? 0, y: n.y ?? 0, width: n.width ?? 0, height: n.height ?? 0)
            if n.id.hasPrefix("n\u{1F}") { out.nodes[String(n.id.dropFirst(2))] = r }
            if n.id.hasPrefix("c\u{1F}") { out.clusters[String(n.id.dropFirst(2))] = r }
            for c in n.children ?? [] { visit(c) }
        }
        for c in laid.children ?? [] { visit(c) }
        for e in laid.edges ?? [] {
            var pts: [CGPoint] = []
            for s in e.sections ?? [] {
                for p in s.polyline {
                    let q = CGPoint(x: p.x, y: p.y)
                    if pts.last != q { pts.append(q) }
                }
            }
            out.edges[e.id] = pts
            // ELK reserves room for inline labels but doesn't reliably report where it put them
            // (labels come back at their container's origin, or without coordinates), so each
            // label is centred on its routed edge, halfway along it, as mermaid places them.
            if let l = e.labels?.first, let mid = Self.midpoint(pts) {
                out.labels[e.id] = CGRect(x: mid.x - l.width / 2, y: mid.y - l.height / 2, width: l.width, height: l.height)
            }
        }
        out.size = CGSize(width: laid.width ?? 0, height: laid.height ?? 0)
        return out
    }

    /// The point halfway along a polyline by length; nil for one with no points.
    static func midpoint(_ pts: [CGPoint]) -> CGPoint? {
        guard let first = pts.first else { return nil }
        let lengths = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) / 2
        for (i, len) in lengths.enumerated() {
            if remaining <= len, len > 0 {
                let t = remaining / len, a = pts[i], b = pts[i + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= len
        }
        return pts.last ?? first
    }

    /// Moves an edge end that ELK attached to a node's bounding box onto the node's real outline
    /// (diamonds, circles, hexagons), continuing along the end segment's direction.
    static func clip(_ pts: inout [CGPoint], atEnd: Bool, to outline: [CGPoint]) {
        guard pts.count >= 2, outline.count >= 3 else { return }
        let i = atEnd ? pts.count - 1 : 0, j = atEnd ? pts.count - 2 : 1
        let p = pts[i], q = pts[j]
        let len = hypot(p.x - q.x, p.y - q.y)
        guard len > 0 else { return }
        let dir = CGPoint(x: (p.x - q.x) / len, y: (p.y - q.y) / len)
        var best: Double?
        for k in outline.indices {
            let a = outline[k], b = outline[(k + 1) % outline.count]
            // Solve p + t·dir = a + u·(b − a).
            let ex = b.x - a.x, ey = b.y - a.y
            let den = dir.x * ey - dir.y * ex
            guard abs(den) > 1e-9 else { continue }
            let t = ((a.x - p.x) * ey - (a.y - p.y) * ex) / den
            let u = ((a.x - p.x) * dir.y - (a.y - p.y) * dir.x) / den
            if t >= -0.01, u >= -0.0001, u <= 1.0001, best.map({ t < $0 }) ?? true { best = t }
        }
        guard let t = best, t > 0.01, t < 400 else { return }
        pts[i] = CGPoint(x: p.x + dir.x * t, y: p.y + dir.y * t)
    }
}

// MARK: - ELK JSON

/// elkjs's JSON graph with the fields the diagrams use. `ELKNode` in NodeGraph has no labels, which
/// edge labels need so ELK reserves room for them.
struct ELKJSONNode: Codable {
    var id: String
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var children: [ELKJSONNode]?
    var edges: [ELKJSONEdge]?
    var layoutOptions: [String: String]?
}

struct ELKJSONEdge: Codable {
    var id: String
    var sources: [String]
    var targets: [String]
    var labels: [ELKJSONLabel]?
    var sections: [ELKEdgeSection]?
}

struct ELKJSONLabel: Codable {
    var width: Double
    var height: Double
    var x: Double?
    var y: Double?
}

/// elkjs in a JavaScriptCore context, called synchronously so `NativeMermaid.svg` can be a plain
/// function the chat calls off the main thread. `ELKLayoutEngine` is an actor for the node-graph
/// screens; this keeps its own context behind a lock rather than hopping actors from sync code.
/// The bundle is the same `Resources/elk/elk.bundled.js`.
final class MermaidELK: @unchecked Sendable {
    static let shared = MermaidELK()

    struct Failure: Error {
        let message: String
    }

    private let lock = NSLock()
    private var context: JSContext?
    private var loadFailure: String?

    func layout(_ graph: ELKJSONNode) throws -> ELKJSONNode {
        lock.lock()
        defer { lock.unlock() }
        let ctx = try loadedContext()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(graph), encoding: .utf8) else { throw Failure(message: "encoding") }
        guard let fn = ctx.objectForKeyedSubscript("__vesperMermaidLayout"), fn.isObject else { throw Failure(message: "bridge missing") }
        ctx.exception = nil
        let result = fn.call(withArguments: [json])
        if let ex = ctx.exception {
            ctx.exception = nil
            throw Failure(message: ex.toString() ?? "exception")
        }
        // The bridge stores the settled promise's value; JSC drains microtasks when the call returns.
        guard let out = ctx.objectForKeyedSubscript("__vesperMermaidResult")?.toString(), out != "undefined", result != nil else {
            throw Failure(message: "layout didn't settle")
        }
        if out.hasPrefix("!") { throw Failure(message: String(out.dropFirst())) }
        return try JSONDecoder().decode(ELKJSONNode.self, from: Data(out.utf8))
    }

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        if let loadFailure { throw Failure(message: loadFailure) }
        guard let url = ELKLayoutEngine.bundledScript(), let source = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else {
            loadFailure = "elk bundle missing"
            throw Failure(message: "elk bundle missing")
        }
        // The same shims ELKLayoutEngine uses: elkjs (GWT) expects browser timers and globals.
        ctx.evaluateScript("""
        var self = this; var window = this;
        var setTimeout = function(fn) { fn(); return 0; }; var clearTimeout = function() {};
        var queueMicrotask = function(fn) { fn(); };
        """)
        ctx.evaluateScript(source, withSourceURL: url)
        ctx.evaluateScript("""
        var __vesperMermaidELK = new ELK();
        var __vesperMermaidResult;
        function __vesperMermaidLayout(json) {
            __vesperMermaidResult = undefined;
            try {
                __vesperMermaidELK.layout(JSON.parse(json)).then(
                    function(r) { __vesperMermaidResult = JSON.stringify(r); },
                    function(e) { __vesperMermaidResult = "!" + String(e && e.message ? e.message : e); });
            } catch (e) { __vesperMermaidResult = "!" + String(e && e.message ? e.message : e); }
            return true;
        }
        """)
        if let ex = ctx.exception {
            loadFailure = ex.toString() ?? "elk failed to load"
            throw Failure(message: loadFailure ?? "")
        }
        context = ctx
        return ctx
    }
}
