import Foundation

// MARK: - Platform-Neutral Geometry

public struct GraphPoint: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public static let zero = GraphPoint(x: 0, y: 0)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: GraphPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

public struct GraphSize: Codable, Sendable, Equatable, Hashable {
    public var width: Double
    public var height: Double

    public static let zero = GraphSize(width: 0, height: 0)

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct GraphRect: Codable, Sendable, Equatable, Hashable {
    public var origin: GraphPoint
    public var size: GraphSize

    public init(origin: GraphPoint, size: GraphSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = GraphPoint(x: x, y: y)
        self.size = GraphSize(width: width, height: height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width * 0.5 }
    public var midY: Double { origin.y + size.height * 0.5 }

    public func contains(_ point: GraphPoint, inset: Double = 0) -> Bool {
        point.x >= minX + inset && point.x <= maxX - inset
            && point.y >= minY + inset && point.y <= maxY - inset
    }

    public func union(_ other: GraphRect) -> GraphRect {
        let x0 = min(minX, other.minX)
        let y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX)
        let y1 = max(maxY, other.maxY)
        return GraphRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

// MARK: - Viewport (Pan / Zoom / Momentum / Fit)

public struct NodeGraphViewport: Codable, Sendable, Equatable {
    public var offset: GraphPoint
    public var scale: Double
    public var velocity: GraphPoint

    public static let minScale: Double = 0.25
    public static let maxScale: Double = 2.5

    public init(offset: GraphPoint = .zero, scale: Double = 1.0, velocity: GraphPoint = .zero) {
        self.offset = offset
        self.scale = Self.clampScale(scale)
        self.velocity = velocity
    }

    public static func clampScale(_ value: Double) -> Double {
        min(maxScale, max(minScale, value))
    }

    public func graphToScreen(_ point: GraphPoint) -> GraphPoint {
        GraphPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    public func screenToGraph(_ point: GraphPoint) -> GraphPoint {
        GraphPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    public mutating func pan(by delta: GraphPoint) {
        offset.x += delta.x
        offset.y += delta.y
    }

    /// Zooms by `factor` while keeping `screenAnchor` stationary on screen.
    public mutating func zoom(factor: Double, around screenAnchor: GraphPoint) {
        let target = Self.clampScale(scale * factor)
        guard abs(target - scale) > 1e-6 else { return }
        let graphAnchor = screenToGraph(screenAnchor)
        scale = target
        offset.x = screenAnchor.x - graphAnchor.x * scale
        offset.y = screenAnchor.y - graphAnchor.y * scale
    }

    public mutating func setZoom(_ newScale: Double, around screenAnchor: GraphPoint) {
        let target = Self.clampScale(newScale)
        zoom(factor: target / scale, around: screenAnchor)
    }

    /// Advances inertial pan momentum; returns true while velocity remains non-trivial.
    @discardableResult
    public mutating func stepMomentum(dt: Double, damping: Double = 0.90) -> Bool {
        guard dt > 0 else { return false }
        let speed = hypot(velocity.x, velocity.y)
        if speed < 1.0 {
            velocity = .zero
            return false
        }
        offset.x += velocity.x * dt
        offset.y += velocity.y * dt
        let decay = pow(damping, dt * 60.0)
        velocity.x *= decay
        velocity.y *= decay
        return hypot(velocity.x, velocity.y) >= 1.0
    }

    /// Centers and scales `contentBounds` inside `viewportSize` with `padding`.
    public mutating func fitToView(
        contentBounds: GraphRect,
        viewportSize: GraphSize,
        padding: Double = 36,
        maxFitScale: Double = 1.15
    ) {
        guard contentBounds.size.width > 0, contentBounds.size.height > 0,
              viewportSize.width > padding * 2, viewportSize.height > padding * 2 else {
            return
        }
        let availW = viewportSize.width - padding * 2
        let availH = viewportSize.height - padding * 2
        let fit = min(availW / contentBounds.size.width, availH / contentBounds.size.height, maxFitScale)
        scale = Self.clampScale(fit)
        let scaledW = contentBounds.size.width * scale
        let scaledH = contentBounds.size.height * scale
        offset = GraphPoint(
            x: (viewportSize.width - scaledW) * 0.5 - contentBounds.minX * scale,
            y: (viewportSize.height - scaledH) * 0.5 - contentBounds.minY * scale
        )
        velocity = .zero
    }
}

// MARK: - Graph Nodes, Ports, Edges & Document

public enum NodeGraphPortKind: String, Codable, Sendable, Equatable, Hashable {
    case input
    case output
}

public enum NodeGraphShape: String, Codable, Sendable, Equatable, Hashable {
    case card
    case diamond
    case pill
}

public enum NodeGraphTone: String, Codable, Sendable, Equatable, Hashable {
    case neutral
    case accent
    case done
    case human
    case blocked
}

public enum NodeGraphDiffKind: String, Codable, Sendable, Equatable, Hashable {
    case added
    case changed
    case removed
}

public struct NodeGraphNodeModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var eyebrow: String?
    public var title: String
    public var subtitle: String
    public var frame: GraphRect
    public var shape: NodeGraphShape
    public var tone: NodeGraphTone
    public var isLive: Bool
    public var isDashed: Bool
    public var diff: NodeGraphDiffKind?
    public var hasInputPort: Bool
    public var hasOutputPort: Bool
    public var deletable: Bool

    public init(
        id: String,
        eyebrow: String? = nil,
        title: String,
        subtitle: String = "",
        frame: GraphRect,
        shape: NodeGraphShape = .card,
        tone: NodeGraphTone = .neutral,
        isLive: Bool = false,
        isDashed: Bool = false,
        diff: NodeGraphDiffKind? = nil,
        hasInputPort: Bool = true,
        hasOutputPort: Bool = true,
        deletable: Bool = true
    ) {
        self.id = id
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.frame = frame
        self.shape = shape
        self.tone = tone
        self.isLive = isLive
        self.isDashed = isDashed
        self.diff = diff
        self.hasInputPort = hasInputPort
        self.hasOutputPort = hasOutputPort
        self.deletable = deletable
    }

    public var inputPortPosition: GraphPoint {
        GraphPoint(x: frame.minX, y: frame.midY)
    }

    public var outputPortPosition: GraphPoint {
        GraphPoint(x: frame.maxX, y: frame.midY)
    }
}

public struct NodeGraphEdgeModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var from: String
    public var to: String
    public var tone: NodeGraphTone
    public var isDashed: Bool
    public var points: [GraphPoint]

    public init(
        id: String,
        from: String,
        to: String,
        tone: NodeGraphTone = .neutral,
        isDashed: Bool = false,
        points: [GraphPoint] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.tone = tone
        self.isDashed = isDashed
        self.points = points
    }
}

public enum NodeGraphHitTarget: Sendable, Equatable {
    case port(nodeId: String, kind: NodeGraphPortKind)
    case node(id: String)
    case edge(id: String)
    case none
}

/// Platform-neutral editable/viewable graph document with hit-testing, selection, drag-move,
/// cycle-safe connection, and add/delete operations.
public struct NodeGraphDocument: Sendable, Equatable {
    public var nodes: [NodeGraphNodeModel]
    public var edges: [NodeGraphEdgeModel]
    public var selectedNodeId: String?
    public var selectedEdgeId: String?

    public init(
        nodes: [NodeGraphNodeModel] = [],
        edges: [NodeGraphEdgeModel] = [],
        selectedNodeId: String? = nil,
        selectedEdgeId: String? = nil
    ) {
        self.nodes = nodes
        self.edges = edges
        self.selectedNodeId = selectedNodeId
        self.selectedEdgeId = selectedEdgeId
    }

    public var contentBounds: GraphRect? {
        guard let first = nodes.first else { return nil }
        return nodes.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    public func node(id: String) -> NodeGraphNodeModel? {
        nodes.first { $0.id == id }
    }

    public func edgePolyline(_ edge: NodeGraphEdgeModel) -> [GraphPoint] {
        if edge.points.count >= 2 { return edge.points }
        guard let source = node(id: edge.from), let target = node(id: edge.to) else { return [] }
        return [source.outputPortPosition, target.inputPortPosition]
    }

    /// Hit-tests in priority order: ports (when `interactive`) -> topmost node -> edge.
    public func hitTest(
        graphPoint: GraphPoint,
        interactive: Bool,
        portRadius: Double = 10,
        edgeTolerance: Double = 8
    ) -> NodeGraphHitTarget {
        if interactive {
            for node in nodes.reversed() {
                if node.hasOutputPort, graphPoint.distance(to: node.outputPortPosition) <= portRadius {
                    return .port(nodeId: node.id, kind: .output)
                }
                if node.hasInputPort, graphPoint.distance(to: node.inputPortPosition) <= portRadius {
                    return .port(nodeId: node.id, kind: .input)
                }
            }
        }
        for node in nodes.reversed() where node.frame.contains(graphPoint) {
            return .node(id: node.id)
        }
        for edge in edges.reversed() {
            let pts = edgePolyline(edge)
            if pts.count >= 2, Self.distanceToPolyline(point: graphPoint, polyline: pts) <= edgeTolerance {
                return .edge(id: edge.id)
            }
        }
        return .none
    }

    public mutating func selectNode(_ id: String?) {
        selectedNodeId = id
        selectedEdgeId = nil
    }

    public mutating func selectEdge(_ id: String?) {
        selectedNodeId = nil
        selectedEdgeId = id
    }

    public mutating func clearSelection() {
        selectedNodeId = nil
        selectedEdgeId = nil
    }

    public mutating func moveNode(id: String, to origin: GraphPoint) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[idx].frame.origin = origin
        // Clear cached routed points for incident edges so live rendering follows the dragged node.
        for i in edges.indices where edges[i].from == id || edges[i].to == id {
            edges[i].points = []
        }
    }

    /// Returns true if connecting `from -> to` is valid and does not introduce a cycle.
    public func canConnect(from: String, to: String) -> Bool {
        guard from != to,
              let a = node(id: from),
              let b = node(id: to),
              a.hasOutputPort,
              b.hasInputPort else {
            return false
        }
        if edges.contains(where: { $0.from == from && $0.to == to }) {
            return false
        }
        return !hasPath(from: to, to: from)
    }

    @discardableResult
    public mutating func connect(from: String, to: String) -> NodeGraphEdgeModel? {
        guard canConnect(from: from, to: to) else { return nil }
        let edge = NodeGraphEdgeModel(id: "\(from)->\(to)", from: from, to: to)
        edges.append(edge)
        return edge
    }

    @discardableResult
    public mutating func disconnect(edgeId: String) -> Bool {
        let before = edges.count
        edges.removeAll { $0.id == edgeId }
        if selectedEdgeId == edgeId { selectedEdgeId = nil }
        return edges.count != before
    }

    public mutating func addNode(_ node: NodeGraphNodeModel) {
        nodes.append(node)
        selectNode(node.id)
    }

    @discardableResult
    public mutating func removeNode(id: String) -> Bool {
        guard let existing = node(id: id), existing.deletable else { return false }
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id }
        if selectedNodeId == id { selectedNodeId = nil }
        return true
    }

    public func hasPath(from start: String, to goal: String) -> Bool {
        var visited: Set<String> = [start]
        var stack: [String] = [start]
        while let current = stack.popLast() {
            if current == goal { return true }
            for edge in edges where edge.from == current && !visited.contains(edge.to) {
                visited.insert(edge.to)
                stack.append(edge.to)
            }
        }
        return false
    }

    /// Applies ELK layout output coordinates and edge sections back onto this document.
    public mutating func applyELKLayout(_ layout: ELKGraph) {
        let posById = Dictionary(layout.children.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for idx in nodes.indices {
            if let laid = posById[nodes[idx].id], let x = laid.x, let y = laid.y {
                nodes[idx].frame = GraphRect(x: x, y: y, width: laid.width, height: laid.height)
            }
        }
        let edgesById = Dictionary(layout.edges.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for idx in edges.indices {
            if let laid = edgesById[edges[idx].id], let section = laid.sections?.first {
                edges[idx].points = section.polyline.map { GraphPoint(x: $0.x, y: $0.y) }
            }
        }
    }

    public static func distanceToPolyline(point: GraphPoint, polyline: [GraphPoint]) -> Double {
        guard polyline.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in 0..<(polyline.count - 1) {
            best = min(best, distanceToSegment(point: point, a: polyline[i], b: polyline[i + 1]))
        }
        return best
    }

    public static func distanceToSegment(point: GraphPoint, a: GraphPoint, b: GraphPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq <= 1e-9 { return point.distance(to: a) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq))
        let proj = GraphPoint(x: a.x + t * dx, y: a.y + t * dy)
        return point.distance(to: proj)
    }
}
