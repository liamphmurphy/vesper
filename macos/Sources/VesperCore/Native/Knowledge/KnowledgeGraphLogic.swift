import Foundation

// MARK: - Graph Layout & Render Models

public struct KnowledgeGraphInputNode: Sendable, Equatable, Hashable {
    public var id: String
    public var group: String

    public init(id: String, group: String) {
        self.id = id
        self.group = group
    }
}

public struct KnowledgeGraphInputLink: Sendable, Equatable, Hashable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct KnowledgeGraphPlacedNode: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var x: Double
    public var y: Double
    public var degree: Int

    public init(id: String, x: Double, y: Double, degree: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.degree = degree
    }
}

public struct KnowledgeGraphBounds: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct KnowledgeGraphGroup: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var colorHex: String
    public var count: Int

    public init(name: String, colorHex: String, count: Int) {
        self.name = name
        self.colorHex = colorHex
        self.count = count
    }
}

public enum KnowledgeGraphScope: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case global = "Global"
    case local = "Local"
    public var id: String { rawValue }
}

public struct KnowledgeGraphFilter: Sendable, Equatable {
    public var search: String
    public var showOrphans: Bool
    public var showUnresolved: Bool
    public var includeAgent: Bool
    public var audience: KnowledgeAudience?
    public var scope: KnowledgeGraphScope
    public var focusPageId: String?
    public var hops: Int

    public init(
        search: String = "",
        showOrphans: Bool = true,
        showUnresolved: Bool = false,
        includeAgent: Bool = false,
        audience: KnowledgeAudience? = nil,
        scope: KnowledgeGraphScope = .global,
        focusPageId: String? = nil,
        hops: Int = 1
    ) {
        self.search = search
        self.showOrphans = showOrphans
        self.showUnresolved = showUnresolved
        self.includeAgent = includeAgent
        self.audience = audience
        self.scope = scope
        self.focusPageId = focusPageId
        self.hops = max(1, min(3, hops))
    }
}

public struct KnowledgeGraphViewport: Sendable, Equatable {
    public static let minScale: Double = 0.3
    public static let maxScale: Double = 6.0

    public var panX: Double
    public var panY: Double
    public var scale: Double

    public init(panX: Double = 0, panY: Double = 0, scale: Double = 1) {
        self.panX = panX
        self.panY = panY
        self.scale = Self.clampScale(scale)
    }

    public static func clampScale(_ value: Double) -> Double {
        min(maxScale, max(minScale, value))
    }

    public func zoomed(by factor: Double) -> KnowledgeGraphViewport {
        KnowledgeGraphViewport(panX: panX, panY: panY, scale: Self.clampScale(scale * factor))
    }

    /// Zooms by `factor` keeping the world point under screen `(anchorX, anchorY)` stationary.
    public func zoomed(
        by factor: Double,
        aroundX anchorX: Double,
        aroundY anchorY: Double,
        bounds: KnowledgeGraphBounds,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> KnowledgeGraphViewport {
        let nextScale = Self.clampScale(scale * factor)
        let world = screenToWorld(
            x: anchorX,
            y: anchorY,
            bounds: bounds,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        let nextPpu = Self.pixelsPerWorldUnit(
            bounds: bounds,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            scale: nextScale
        )
        guard nextPpu > 0 else {
            return KnowledgeGraphViewport(panX: panX, panY: panY, scale: nextScale)
        }
        let nextCenterWorldX = world.x - (anchorX - canvasWidth * 0.5) / nextPpu
        let nextCenterWorldY = world.y - (anchorY - canvasHeight * 0.5) / nextPpu
        return KnowledgeGraphViewport(
            panX: nextCenterWorldX - (bounds.x + bounds.width * 0.5),
            panY: nextCenterWorldY - (bounds.y + bounds.height * 0.5),
            scale: nextScale
        )
    }

    public func panned(
        deltaX: Double,
        deltaY: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        bounds: KnowledgeGraphBounds
    ) -> KnowledgeGraphViewport {
        let pixelsPerWorld = Self.pixelsPerWorldUnit(
            bounds: bounds,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            scale: scale
        )
        guard pixelsPerWorld > 0 else { return self }
        return KnowledgeGraphViewport(
            panX: panX - deltaX / pixelsPerWorld,
            panY: panY - deltaY / pixelsPerWorld,
            scale: scale
        )
    }

    public func reset() -> KnowledgeGraphViewport {
        KnowledgeGraphViewport(panX: 0, panY: 0, scale: 1)
    }

    public func unitSize(for bounds: KnowledgeGraphBounds) -> Double {
        let w = bounds.width / scale
        let h = bounds.height / scale
        return max(w, h * 1.6) / 1200.0
    }

    public func worldToScreen(
        x: Double,
        y: Double,
        bounds: KnowledgeGraphBounds,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> (x: Double, y: Double) {
        let ppu = Self.pixelsPerWorldUnit(
            bounds: bounds,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            scale: scale
        )
        let centerWorldX = bounds.x + bounds.width * 0.5 + panX
        let centerWorldY = bounds.y + bounds.height * 0.5 + panY
        return (
            x: canvasWidth * 0.5 + (x - centerWorldX) * ppu,
            y: canvasHeight * 0.5 + (y - centerWorldY) * ppu
        )
    }

    public func screenToWorld(
        x: Double,
        y: Double,
        bounds: KnowledgeGraphBounds,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> (x: Double, y: Double) {
        let ppu = Self.pixelsPerWorldUnit(
            bounds: bounds,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            scale: scale
        )
        guard ppu > 0 else { return (bounds.x, bounds.y) }
        let centerWorldX = bounds.x + bounds.width * 0.5 + panX
        let centerWorldY = bounds.y + bounds.height * 0.5 + panY
        return (
            x: centerWorldX + (x - canvasWidth * 0.5) / ppu,
            y: centerWorldY + (y - canvasHeight * 0.5) / ppu
        )
    }

    public static func pixelsPerWorldUnit(
        bounds: KnowledgeGraphBounds,
        canvasWidth: Double,
        canvasHeight: Double,
        scale: Double
    ) -> Double {
        guard canvasWidth > 0, canvasHeight > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        let viewW = bounds.width / max(minScale, scale)
        let viewH = bounds.height / max(minScale, scale)
        return min(canvasWidth / viewW, canvasHeight / viewH)
    }
}

public struct KnowledgeGraphRenderNode: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var group: String
    public var audience: KnowledgeAudience
    public var isUnresolved: Bool
    public var x: Double
    public var y: Double
    public var degree: Int
    public var radius: Double
    public var colorHex: String?
    public var isDimmed: Bool
    public var isHighlighted: Bool
    public var showLabel: Bool

    public init(
        id: String,
        title: String,
        path: String,
        group: String,
        audience: KnowledgeAudience,
        isUnresolved: Bool,
        x: Double,
        y: Double,
        degree: Int,
        radius: Double,
        colorHex: String?,
        isDimmed: Bool,
        isHighlighted: Bool,
        showLabel: Bool
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.group = group
        self.audience = audience
        self.isUnresolved = isUnresolved
        self.x = x
        self.y = y
        self.degree = degree
        self.radius = radius
        self.colorHex = colorHex
        self.isDimmed = isDimmed
        self.isHighlighted = isHighlighted
        self.showLabel = showLabel
    }
}

public struct KnowledgeGraphRenderEdge: Sendable, Equatable, Hashable {
    public var source: String
    public var target: String
    public var isUnresolved: Bool
    public var isHighlighted: Bool
    public var isDimmed: Bool

    public init(source: String, target: String, isUnresolved: Bool, isHighlighted: Bool, isDimmed: Bool) {
        self.source = source
        self.target = target
        self.isUnresolved = isUnresolved
        self.isHighlighted = isHighlighted
        self.isDimmed = isDimmed
    }
}

public struct KnowledgeGraphSnapshot: Sendable, Equatable {
    public var placed: [KnowledgeGraphPlacedNode]
    public var nodes: [KnowledgeGraphRenderNode]
    public var edges: [KnowledgeGraphRenderEdge]
    public var groups: [KnowledgeGraphGroup]
    public var bounds: KnowledgeGraphBounds
    public var unresolvedCount: Int
    public var totalLinkCount: Int

    public init(
        placed: [KnowledgeGraphPlacedNode] = [],
        nodes: [KnowledgeGraphRenderNode] = [],
        edges: [KnowledgeGraphRenderEdge] = [],
        groups: [KnowledgeGraphGroup] = [],
        bounds: KnowledgeGraphBounds = KnowledgeGraphBounds(x: -100, y: -100, width: 200, height: 200),
        unresolvedCount: Int = 0,
        totalLinkCount: Int = 0
    ) {
        self.placed = placed
        self.nodes = nodes
        self.edges = edges
        self.groups = groups
        self.bounds = bounds
        self.unresolvedCount = unresolvedCount
        self.totalLinkCount = totalLinkCount
    }
}

// MARK: - Deterministic Force Layout & Graph Filtering

public enum KnowledgeGraphLogic: Sendable {
    public static let paletteHex: [String] = [
        "#9B8CFF", "#3FC1B0", "#F0BF4C", "#4EA7FC",
        "#F48A98", "#F59E5B", "#6FCF97", "#C89BFF",
    ]
    public static let fallbackColorHex = "#5E5B6E"
    public static let unresolvedNodePrefix = "unresolved:"

    private struct GridCell: Hashable {
        let x: Int
        let y: Int
    }

    /// Deterministic force layout matching `web/lib/knowledge-graph.ts`:
    /// springs along links, grid-bucketed repulsion, and gentle centering pull.
    public static func layoutGraph(
        nodes: [KnowledgeGraphInputNode],
        links: [KnowledgeGraphInputLink],
        iterations: Int = 220
    ) -> [KnowledgeGraphPlacedNode] {
        let n = nodes.count
        guard n > 0 else { return [] }

        var indexById: [String: Int] = Dictionary(minimumCapacity: n)
        for (i, node) in nodes.enumerated() {
            indexById[node.id] = i
        }

        var seed: UInt32 = UInt32(truncatingIfNeeded: n &* 7919 &+ links.count)
        if seed == 0 { seed = 1 }
        func nextRand() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            return Double(seed % 10_000) / 10_000.0
        }

        var groups: [String] = []
        var groupIndex: [String: Int] = [:]
        for node in nodes where groupIndex[node.group] == nil {
            groupIndex[node.group] = groups.count
            groups.append(node.group)
        }

        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        let radius = Double(n).squareRoot() * 22.0
        let groupDenom = Double(max(1, groups.count))

        for (i, node) in nodes.enumerated() {
            let angle = (Double(groupIndex[node.group] ?? 0) / groupDenom) * Double.pi * 2.0
            let r = radius * (0.35 + nextRand() * 0.6)
            x[i] = cos(angle) * radius * 0.6 + cos(nextRand() * 6.283) * r * 0.5
            y[i] = sin(angle) * radius * 0.6 + sin(nextRand() * 6.283) * r * 0.5
        }

        var edges: [(Int, Int)] = []
        edges.reserveCapacity(links.count)
        var degree = [Int](repeating: 0, count: n)
        for link in links {
            guard let a = indexById[link.source], let b = indexById[link.target], a != b else { continue }
            edges.append((a, b))
            degree[a] += 1
            degree[b] += 1
        }

        let ideal = 34.0
        let cell = ideal * 3.0
        let cellSquared = cell * cell
        let idealSquared = ideal * ideal
        var vx = [Double](repeating: 0, count: n)
        var vy = [Double](repeating: 0, count: n)

        let totalIterations = max(0, iterations)
        for it in 0..<totalIterations {
            let t = 1.0 - Double(it) / Double(totalIterations)
            for i in 0..<n {
                vx[i] = 0
                vy[i] = 0
            }

            var grid: [GridCell: [Int]] = Dictionary(minimumCapacity: n)
            for i in 0..<n {
                let key = GridCell(x: Int(floor(x[i] / cell)), y: Int(floor(y[i] / cell)))
                grid[key, default: []].append(i)
            }

            for i in 0..<n {
                let cx = Int(floor(x[i] / cell))
                let cy = Int(floor(y[i] / cell))
                for gx in (cx - 1)...(cx + 1) {
                    for gy in (cy - 1)...(cy + 1) {
                        guard let bucket = grid[GridCell(x: gx, y: gy)] else { continue }
                        for j in bucket where j > i {
                            let rawDx = x[i] - x[j]
                            let rawDy = y[i] - y[j]
                            let dx = rawDx == 0 ? 0.01 : rawDx
                            let dy = rawDy == 0 ? 0.01 : rawDy
                            let d2 = dx * dx + dy * dy
                            if d2 > cellSquared { continue }
                            let f = idealSquared / d2
                            vx[i] += dx * f * 0.05
                            vy[i] += dy * f * 0.05
                            vx[j] -= dx * f * 0.05
                            vy[j] -= dy * f * 0.05
                        }
                    }
                }
            }

            for (a, b) in edges {
                let dx = x[b] - x[a]
                let dy = y[b] - y[a]
                let rawD = (dx * dx + dy * dy).squareRoot()
                let d = rawD == 0 ? 0.01 : rawD
                let f = ((d - ideal) / d) * 0.06
                vx[a] += dx * f
                vy[a] += dy * f
                vx[b] -= dx * f
                vy[b] -= dy * f
            }

            let step = 6.0 * t + 0.5
            for i in 0..<n {
                vx[i] -= x[i] * 0.004
                vy[i] -= y[i] * 0.004
                let m = (vx[i] * vx[i] + vy[i] * vy[i]).squareRoot()
                let s = m > step ? step / m : 1.0
                x[i] += vx[i] * s
                y[i] += vy[i] * s
            }
        }

        return nodes.enumerated().map { i, node in
            KnowledgeGraphPlacedNode(id: node.id, x: x[i], y: y[i], degree: degree[i])
        }
    }

    public static func bounds(of placed: [KnowledgeGraphPlacedNode], margin: Double = 60) -> KnowledgeGraphBounds {
        guard !placed.isEmpty else {
            return KnowledgeGraphBounds(x: -100, y: -100, width: 200, height: 200)
        }
        var x0 = Double.infinity
        var y0 = Double.infinity
        var x1 = -Double.infinity
        var y1 = -Double.infinity
        for p in placed {
            x0 = min(x0, p.x)
            y0 = min(y0, p.y)
            x1 = max(x1, p.x)
            y1 = max(y1, p.y)
        }
        return KnowledgeGraphBounds(
            x: x0 - margin,
            y: y0 - margin,
            width: x1 - x0 + margin * 2,
            height: y1 - y0 + margin * 2
        )
    }

    public static func groupName(for path: String) -> String {
        if let slash = path.firstIndex(of: "/") {
            let prefix = String(path[..<slash])
            return prefix.isEmpty ? "Top level" : prefix
        }
        return "Top level"
    }

    /// Breadth-first neighborhood of `nodeId` within `hops` undirected steps.
    public static func neighborhood(
        of nodeId: String,
        edges: [KnowledgeGraphInputLink],
        hops: Int = 1
    ) -> Set<String> {
        var adjacency: [String: [String]] = [:]
        for e in edges {
            adjacency[e.source, default: []].append(e.target)
            adjacency[e.target, default: []].append(e.source)
        }
        var visited: Set<String> = [nodeId]
        var frontier: Set<String> = [nodeId]
        for _ in 0..<max(0, hops) {
            var next: Set<String> = []
            for current in frontier {
                for neighbor in adjacency[current] ?? [] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    next.insert(neighbor)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return visited
    }

    /// Builds a filtered, laid-out graph snapshot ready for SwiftUI `Canvas` rendering.
    public static func buildSnapshot(
        network: KnowledgeNetwork,
        filter: KnowledgeGraphFilter,
        hoveredNodeId: String? = nil,
        selectedNodeId: String? = nil,
        viewport: KnowledgeGraphViewport = KnowledgeGraphViewport(),
        iterations: Int = 220
    ) -> KnowledgeGraphSnapshot {
        let unresolvedCount = network.links.filter { ($0.unresolved ?? "").isEmpty == false }.count

        var baseNodes = network.nodes.filter { node in
            if let audience = filter.audience, node.audience != audience { return false }
            if !filter.includeAgent && node.audience == .agent { return false }
            return true
        }
        var allowedIds = Set(baseNodes.map(\.id))

        var rawEdges: [(source: String, target: String, unresolved: Bool)] = []
        var unresolvedNodeMap: [String: KnowledgeNetworkNode] = [:]

        for link in network.links {
            guard allowedIds.contains(link.source) else { continue }
            if let target = link.target, !target.isEmpty, allowedIds.contains(target) {
                rawEdges.append((link.source, target, false))
            } else if filter.showUnresolved, let missing = link.unresolved, !missing.isEmpty {
                let ghostId = "\(unresolvedNodePrefix)\(missing.lowercased())"
                if unresolvedNodeMap[ghostId] == nil {
                    unresolvedNodeMap[ghostId] = KnowledgeNetworkNode(
                        id: ghostId,
                        title: missing,
                        path: "Unresolved/\(missing)",
                        audience: .private
                    )
                }
                rawEdges.append((link.source, ghostId, true))
            }
        }

        if filter.showUnresolved && !unresolvedNodeMap.isEmpty {
            let ghosts = unresolvedNodeMap.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            baseNodes.append(contentsOf: ghosts)
            for g in ghosts { allowedIds.insert(g.id) }
        }

        let inputLinksAll = rawEdges.map { KnowledgeGraphInputLink(source: $0.source, target: $0.target) }
        if filter.scope == .local, let focusId = filter.focusPageId, allowedIds.contains(focusId) {
            let keep = neighborhood(of: focusId, edges: inputLinksAll, hops: filter.hops)
            baseNodes = baseNodes.filter { keep.contains($0.id) }
            allowedIds = Set(baseNodes.map(\.id))
            rawEdges = rawEdges.filter { allowedIds.contains($0.source) && allowedIds.contains($0.target) }
        }

        let linkedIds = Set(rawEdges.flatMap { [$0.source, $0.target] })
        let filteredNodes = baseNodes.filter { filter.showOrphans || linkedIds.contains($0.id) }
        let finalIds = Set(filteredNodes.map(\.id))
        let finalRawEdges = rawEdges.filter { finalIds.contains($0.source) && finalIds.contains($0.target) }

        var groupCounts: [String: Int] = [:]
        var inputNodes: [KnowledgeGraphInputNode] = []
        inputNodes.reserveCapacity(filteredNodes.count)
        for node in filteredNodes {
            let group = node.id.hasPrefix(unresolvedNodePrefix) ? "Unresolved" : groupName(for: node.path)
            groupCounts[group, default: 0] += 1
            inputNodes.append(KnowledgeGraphInputNode(id: node.id, group: group))
        }

        let sortedGroups = groupCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(paletteHex.count)
            .enumerated()
            .map { idx, entry in
                KnowledgeGraphGroup(name: entry.key, colorHex: paletteHex[idx], count: entry.value)
            }
        let colorByGroup = Dictionary(uniqueKeysWithValues: sortedGroups.map { ($0.name, $0.colorHex) })

        let layoutLinks = finalRawEdges.map { KnowledgeGraphInputLink(source: $0.source, target: $0.target) }
        let placed = layoutGraph(nodes: inputNodes, links: layoutLinks, iterations: iterations)
        let graphBounds = bounds(of: placed)
        let unit = viewport.unitSize(for: graphBounds)
        let activeFocus = hoveredNodeId ?? selectedNodeId
        let activeNeighbors: Set<String>? = activeFocus.map { neighborhood(of: $0, edges: layoutLinks, hops: 1) }
        let query = filter.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labelAll = placed.count < 60 || viewport.scale > 2.0

        let nodeMetaById = Dictionary(uniqueKeysWithValues: filteredNodes.map { ($0.id, $0) })
        let renderNodes: [KnowledgeGraphRenderNode] = placed.compactMap { p in
            guard let meta = nodeMetaById[p.id] else { return nil }
            let isUnresolved = p.id.hasPrefix(unresolvedNodePrefix)
            let group = isUnresolved ? "Unresolved" : groupName(for: meta.path)
            let radius = min(12.0, 3.5 + Double(p.degree).squareRoot() * 1.6) * unit
            let matchesSearch = query.isEmpty
                || meta.title.lowercased().contains(query)
                || meta.path.lowercased().contains(query)
            let inNeighborhood = activeNeighbors?.contains(p.id) ?? true
            let isDimmed = !inNeighborhood || !matchesSearch
            let isHighlighted = p.id == hoveredNodeId || p.id == selectedNodeId
            let showLabel = labelAll || p.degree >= 6 || isHighlighted || (!query.isEmpty && matchesSearch)
            let colorHex: String? = isUnresolved
                ? nil
                : (p.degree > 0 ? (colorByGroup[group] ?? fallbackColorHex) : nil)

            return KnowledgeGraphRenderNode(
                id: p.id,
                title: meta.title,
                path: meta.path,
                group: group,
                audience: meta.audience,
                isUnresolved: isUnresolved,
                x: p.x,
                y: p.y,
                degree: p.degree,
                radius: radius,
                colorHex: colorHex,
                isDimmed: isDimmed,
                isHighlighted: isHighlighted,
                showLabel: showLabel
            )
        }

        let renderEdges: [KnowledgeGraphRenderEdge] = finalRawEdges.map { edge in
            let lit: Bool
            if let focus = activeFocus {
                lit = (edge.source == focus || edge.target == focus)
            } else {
                lit = false
            }
            let dimmed = activeNeighbors != nil && !lit
            return KnowledgeGraphRenderEdge(
                source: edge.source,
                target: edge.target,
                isUnresolved: edge.unresolved,
                isHighlighted: lit,
                isDimmed: dimmed
            )
        }

        return KnowledgeGraphSnapshot(
            placed: placed,
            nodes: renderNodes,
            edges: renderEdges,
            groups: sortedGroups,
            bounds: graphBounds,
            unresolvedCount: unresolvedCount,
            totalLinkCount: finalRawEdges.count
        )
    }

    /// Returns the closest node whose hit circle contains `worldPoint`, preferring higher-degree nodes on ties.
    public static func hitTest(
        worldPoint: (x: Double, y: Double),
        nodes: [KnowledgeGraphRenderNode],
        minHitRadius: Double = 8.0
    ) -> KnowledgeGraphRenderNode? {
        var best: KnowledgeGraphRenderNode?
        var bestDistSq = Double.infinity
        for node in nodes {
            let hitR = max(node.radius * 1.4, minHitRadius)
            let dx = worldPoint.x - node.x
            let dy = worldPoint.y - node.y
            let d2 = dx * dx + dy * dy
            if d2 <= hitR * hitR {
                if d2 < bestDistSq || (d2 == bestDistSq && node.degree > (best?.degree ?? -1)) {
                    best = node
                    bestDistSq = d2
                }
            }
        }
        return best
    }
}
