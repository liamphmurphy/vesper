import SwiftUI
import VesperCore

/// Native SwiftUI Canvas renderer for the Knowledge vault graph.
struct KnowledgeGraphView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var filter = KnowledgeGraphFilter()
    @State private var viewport = KnowledgeGraphViewport()
    @State private var dragStartViewport: KnowledgeGraphViewport?
    @State private var draggedNodeId: String?
    @State private var isPanningCanvas = false
    @State private var settleTask: Task<Void, Never>?
    @State private var magnifyStartScale: Double?
    @State private var hoveredNodeId: String?
    @State private var selectedNodeId: String?
    @State private var snapshot = KnowledgeGraphSnapshot()
    @State private var showFilters = true

    private var structuralFilterKey: String {
        "\(filter.showOrphans)|\(filter.showUnresolved)|\(filter.includeAgent)|\(filter.audience?.rawValue ?? "all")|\(filter.scope.rawValue)|\(filter.focusPageId ?? "")|\(filter.hops)"
    }

    private var networkRequest: APIRequest<KnowledgeNetwork> {
        KnowledgeAPI.getNetwork(includeAgent: filter.includeAgent)
    }

    var body: some View {
        let p = theme.palette
        let entry = context.store.entry(networkRequest)

        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                theme.swiftUIColor("surface-sunken", fallback: p.surface)
                    .ignoresSafeArea()

                if entry.data == nil && entry.error == nil {
                    VStack(spacing: 12) {
                        SkeletonBar(height: 24).frame(maxWidth: 220)
                        SkeletonBar(height: 260)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = entry.error, entry.data == nil {
                    QueryErrorView(message: "Could not load graph: \(error.userMessage)") {
                        Task { _ = await context.store.refetch(networkRequest) }
                    }
                } else if snapshot.nodes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 28))
                            .foregroundStyle(p.tertiaryText)
                        Text("No pages to draw yet")
                            .vesperText(.heading, theme)
                            .foregroundStyle(p.text)
                        Text("Pages and the links between them appear here as you write.")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    graphCanvas
                }

                VStack(alignment: .trailing, spacing: 8) {
                    toolbarControls
                    if showFilters {
                        filtersCard
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(p.border)
            statusBar
        }
        .task(id: filter.includeAgent) {
            context.store.load(networkRequest)
        }
        .onChange(of: entry.data, initial: true) { _, network in
            rebuildSnapshot(network: network)
        }
        .onChange(of: structuralFilterKey) { _, _ in
            rebuildSnapshot(network: entry.data)
        }
        .onDisappear {
            settleTask?.cancel()
            settleTask = nil
        }
    }

    private struct LabelCandidate {
        let node: KnowledgeGraphRenderNode
        let screenPoint: (x: Double, y: Double)
        let screenRadius: Double
        let opacity: Double
        let isFocused: Bool
        let matchesSearch: Bool
        let isDimmed: Bool
    }

    private var graphCanvas: some View {
        let p = theme.palette
        let accentColor = p.accent
        let textColor = p.text
        let secondaryText = p.secondaryText
        let tertiaryText = p.tertiaryText

        let activeFocus = draggedNodeId ?? hoveredNodeId ?? selectedNodeId
        let layoutLinks = snapshot.edges.map { KnowledgeGraphInputLink(source: $0.source, target: $0.target) }
        let activeNeighbors: Set<String>? = activeFocus.map {
            KnowledgeGraphLogic.neighborhood(of: $0, edges: layoutLinks, hops: 1)
        }
        let searchQuery = filter.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSearch = !searchQuery.isEmpty
        let nodeById = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        return GeometryReader { proxy in
            Canvas { gc, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let ppu = KnowledgeGraphViewport.pixelsPerWorldUnit(
                    bounds: snapshot.bounds,
                    canvasWidth: w,
                    canvasHeight: h,
                    scale: viewport.scale
                )

                for edge in snapshot.edges {
                    guard let a = nodeById[edge.source], let b = nodeById[edge.target] else { continue }
                    let pa = viewport.worldToScreen(x: a.x, y: a.y, bounds: snapshot.bounds, canvasWidth: w, canvasHeight: h)
                    let pb = viewport.worldToScreen(x: b.x, y: b.y, bounds: snapshot.bounds, canvasWidth: w, canvasHeight: h)

                    let lit = activeFocus != nil && (edge.source == activeFocus || edge.target == activeFocus)
                    let dimmed = activeNeighbors != nil && !lit
                    var path = Path()
                    path.move(to: CGPoint(x: pa.x, y: pa.y))
                    path.addLine(to: CGPoint(x: pb.x, y: pb.y))

                    let baseEdgeColor = Color(cssHex: a.colorHex) ?? Color(cssHex: b.colorHex) ?? secondaryText
                    let strokeColor = lit ? accentColor : (dimmed ? secondaryText : baseEdgeColor)
                    let lineWidth: CGFloat = lit ? 1.6 : (dimmed ? 0.75 : (edge.isUnresolved ? 0.9 : 1.0))
                    let style = edge.isUnresolved
                        ? StrokeStyle(lineWidth: lineWidth, dash: [4, 3])
                        : StrokeStyle(lineWidth: lineWidth)
                    gc.opacity = dimmed ? 0.1 : (lit ? 0.95 : (edge.isUnresolved ? 0.4 : 0.48))
                    gc.stroke(path, with: .color(strokeColor), style: style)
                }

                var labelCandidates: [LabelCandidate] = []
                labelCandidates.reserveCapacity(min(snapshot.nodes.count, 128))

                for node in snapshot.nodes {
                    let pt = viewport.worldToScreen(x: node.x, y: node.y, bounds: snapshot.bounds, canvasWidth: w, canvasHeight: h)
                    let matchesSearch = !hasSearch
                        || node.title.lowercased().contains(searchQuery)
                        || node.path.lowercased().contains(searchQuery)
                    let inNeighborhood = activeNeighbors?.contains(node.id) ?? true
                    let isDimmed = !inNeighborhood || !matchesSearch
                    let isFocused = node.id == draggedNodeId || node.id == hoveredNodeId || node.id == selectedNodeId
                    let baseScreenRadius = max(node.degree == 0 ? 1.8 : 2.2, min(9.5, node.radius * ppu))
                    let screenRadius = isFocused ? baseScreenRadius + 1.2 : baseScreenRadius

                    let circleRect = CGRect(
                        x: pt.x - screenRadius,
                        y: pt.y - screenRadius,
                        width: screenRadius * 2,
                        height: screenRadius * 2
                    )
                    let circle = Path(ellipseIn: circleRect)

                    gc.opacity = isDimmed ? 0.18 : 1.0
                    if node.isUnresolved {
                        gc.stroke(circle, with: .color(tertiaryText), style: StrokeStyle(lineWidth: 1.1, dash: [2, 2]))
                    } else {
                        let fill = Color(cssHex: node.colorHex) ?? tertiaryText
                        gc.fill(circle, with: .color(fill))
                    }
                    if isFocused {
                        gc.stroke(circle, with: .color(textColor), lineWidth: 1.5)
                    }

                    let opacity = KnowledgeGraphLogic.labelOpacity(
                        scale: viewport.scale,
                        nodeCount: snapshot.nodes.count,
                        degree: node.degree,
                        isFocused: isFocused,
                        matchesSearch: matchesSearch,
                        hasSearch: hasSearch
                    )
                    if opacity > 0.04 && (!isDimmed || isFocused) {
                        labelCandidates.append(LabelCandidate(
                            node: node,
                            screenPoint: pt,
                            screenRadius: screenRadius,
                            opacity: opacity,
                            isFocused: isFocused,
                            matchesSearch: hasSearch && matchesSearch,
                            isDimmed: isDimmed
                        ))
                    }
                }

                labelCandidates.sort { lhs, rhs in
                    if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
                    if lhs.matchesSearch != rhs.matchesSearch { return lhs.matchesSearch }
                    if lhs.node.degree != rhs.node.degree { return lhs.node.degree > rhs.node.degree }
                    return lhs.node.id < rhs.node.id
                }

                var placedLabelRects: [CGRect] = []
                placedLabelRects.reserveCapacity(labelCandidates.count)
                for candidate in labelCandidates {
                    let displayTitle = candidate.node.title.count > 28
                        ? String(candidate.node.title.prefix(27)) + "…"
                        : candidate.node.title
                    let text = Text(displayTitle)
                        .font(.system(size: 10.5, weight: candidate.isFocused ? .semibold : .regular))
                        .foregroundStyle(candidate.isFocused ? textColor : secondaryText)
                    let resolved = gc.resolve(text)
                    let measured = resolved.measure(in: CGSize(width: 240, height: 32))
                    let center = CGPoint(x: candidate.screenPoint.x, y: candidate.screenPoint.y + candidate.screenRadius + 9)
                    let paddedRect = CGRect(
                        x: center.x - measured.width * 0.5 - 4,
                        y: center.y - measured.height * 0.5 - 2,
                        width: measured.width + 8,
                        height: measured.height + 4
                    )
                    if !candidate.isFocused && placedLabelRects.contains(where: { $0.intersects(paddedRect) }) {
                        continue
                    }
                    placedLabelRects.append(paddedRect)
                    gc.opacity = candidate.isDimmed ? 0.25 : candidate.opacity
                    gc.draw(resolved, at: center, anchor: .center)
                }
            }
            .contentShape(Rectangle())
            .onCanvasScrollWheel { action in
                switch action {
                case .zoom(let factor, let ax, let ay):
                    viewport = viewport.zoomed(
                        by: factor,
                        aroundX: ax,
                        aroundY: ay,
                        bounds: snapshot.bounds,
                        canvasWidth: Double(proxy.size.width),
                        canvasHeight: Double(proxy.size.height)
                    )
                    return true
                case .pan(let dx, let dy):
                    viewport = viewport.panned(
                        deltaX: dx,
                        deltaY: dy,
                        canvasWidth: Double(proxy.size.width),
                        canvasHeight: Double(proxy.size.height),
                        bounds: snapshot.bounds
                    )
                    return true
                case .ignore:
                    return false
                }
            }
            .onContinuousHover { phase in
                guard draggedNodeId == nil else { return }
                switch phase {
                case .active(let loc):
                    let world = viewport.screenToWorld(
                        x: Double(loc.x),
                        y: Double(loc.y),
                        bounds: snapshot.bounds,
                        canvasWidth: Double(proxy.size.width),
                        canvasHeight: Double(proxy.size.height)
                    )
                    let minHit = max(8.0, 12.0 / KnowledgeGraphViewport.pixelsPerWorldUnit(
                        bounds: snapshot.bounds,
                        canvasWidth: Double(proxy.size.width),
                        canvasHeight: Double(proxy.size.height),
                        scale: viewport.scale
                    ))
                    hoveredNodeId = KnowledgeGraphLogic.hitTest(worldPoint: world, nodes: snapshot.nodes, minHitRadius: minHit)?.id
                case .ended:
                    hoveredNodeId = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let canvasW = Double(proxy.size.width)
                        let canvasH = Double(proxy.size.height)
                        if draggedNodeId == nil && !isPanningCanvas {
                            let startWorld = viewport.screenToWorld(
                                x: Double(value.startLocation.x),
                                y: Double(value.startLocation.y),
                                bounds: snapshot.bounds,
                                canvasWidth: canvasW,
                                canvasHeight: canvasH
                            )
                            let minHit = max(8.0, 12.0 / KnowledgeGraphViewport.pixelsPerWorldUnit(
                                bounds: snapshot.bounds,
                                canvasWidth: canvasW,
                                canvasHeight: canvasH,
                                scale: viewport.scale
                            ))
                            if let hit = KnowledgeGraphLogic.hitTest(worldPoint: startWorld, nodes: snapshot.nodes, minHitRadius: minHit) {
                                settleTask?.cancel()
                                settleTask = nil
                                draggedNodeId = hit.id
                                hoveredNodeId = hit.id
                            } else {
                                isPanningCanvas = true
                                dragStartViewport = viewport
                            }
                        }

                        if let nodeId = draggedNodeId {
                            let world = viewport.screenToWorld(
                                x: Double(value.location.x),
                                y: Double(value.location.y),
                                bounds: snapshot.bounds,
                                canvasWidth: canvasW,
                                canvasHeight: canvasH
                            )
                            if let idx = snapshot.nodes.firstIndex(where: { $0.id == nodeId }) {
                                snapshot.nodes[idx].x = world.x
                                snapshot.nodes[idx].y = world.y
                                KnowledgeGraphLogic.relaxStep(
                                    nodes: &snapshot.nodes,
                                    edges: snapshot.edges,
                                    pinnedNodeId: nodeId,
                                    alpha: 0.45
                                )
                            }
                        } else if isPanningCanvas, let start = dragStartViewport {
                            viewport = start.panned(
                                deltaX: Double(value.translation.width),
                                deltaY: Double(value.translation.height),
                                canvasWidth: canvasW,
                                canvasHeight: canvasH,
                                bounds: snapshot.bounds
                            )
                        }
                    }
                    .onEnded { _ in
                        let wasDraggingNode = draggedNodeId != nil
                        draggedNodeId = nil
                        isPanningCanvas = false
                        dragStartViewport = nil
                        if wasDraggingNode {
                            startSettleAnimation()
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        let base = magnifyStartScale ?? viewport.scale
                        if magnifyStartScale == nil { magnifyStartScale = base }
                        viewport.scale = KnowledgeGraphViewport.clampScale(base * Double(value))
                    }
                    .onEnded { _ in
                        magnifyStartScale = nil
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let world = viewport.screenToWorld(
                            x: Double(value.location.x),
                            y: Double(value.location.y),
                            bounds: snapshot.bounds,
                            canvasWidth: Double(proxy.size.width),
                            canvasHeight: Double(proxy.size.height)
                        )
                        let minHit = max(8.0, 12.0 / KnowledgeGraphViewport.pixelsPerWorldUnit(
                            bounds: snapshot.bounds,
                            canvasWidth: Double(proxy.size.width),
                            canvasHeight: Double(proxy.size.height),
                            scale: viewport.scale
                        ))
                        if let hit = KnowledgeGraphLogic.hitTest(worldPoint: world, nodes: snapshot.nodes, minHitRadius: minHit) {
                            selectedNodeId = hit.id
                            if !hit.isUnresolved {
                                context.navigate(KnowledgeShellLogic.pageHref(id: hit.id, title: hit.title))
                            }
                        } else {
                            selectedNodeId = nil
                        }
                    }
            )
        }
    }

    private var toolbarControls: some View {
        let p = theme.palette
        return HStack(spacing: 4) {
            Button {
                viewport = viewport.zoomed(by: 0.8)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.vesper())
            .controlSize(.small)
            .help("Zoom out")

            Button {
                viewport = viewport.reset()
            } label: {
                Text("\(Int(round(viewport.scale * 100)))%")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium, design: .monospaced))
            }
            .buttonStyle(.vesper())
            .controlSize(.small)
            .help("Reset zoom & pan")

            Button {
                viewport = viewport.zoomed(by: 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.vesper())
            .controlSize(.small)
            .help("Zoom in")

            Button {
                showFilters.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(showFilters ? p.accent : p.text)
            }
            .buttonStyle(.vesper())
            .controlSize(.small)
            .help("Toggle filters")
        }
    }

    private var filtersCard: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                Text("Filters")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                Spacer()
            }
            .foregroundStyle(p.text)

            TextField("Find a page…", text: $filter.search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: theme.pointSize(.small)))

            Picker("Scope", selection: $filter.scope) {
                ForEach(KnowledgeGraphScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if filter.scope == .local {
                HStack {
                    Text("Depth: \(filter.hops) \(filter.hops == 1 ? "hop" : "hops")")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                    Spacer()
                    Stepper("", value: $filter.hops, in: 1...3)
                        .labelsHidden()
                        .controlSize(.small)
                }
                if filter.focusPageId == nil {
                    Text("Select a node to focus local graph.")
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }

            Picker("Audience", selection: Binding(
                get: { filter.audience?.rawValue ?? "all" },
                set: { raw in filter.audience = KnowledgeAudience(rawValue: raw) }
            )) {
                Text("All audiences").tag("all")
                Text("Private").tag(KnowledgeAudience.private.rawValue)
                Text("Shared").tag(KnowledgeAudience.shared.rawValue)
                Text("Agent").tag(KnowledgeAudience.agent.rawValue)
            }
            .controlSize(.small)

            Toggle("Orphans", isOn: $filter.showOrphans)
                .font(.system(size: theme.pointSize(.small)))
            Toggle("Unresolved links", isOn: $filter.showUnresolved)
                .font(.system(size: theme.pointSize(.small)))
            Toggle("Agent knowledge", isOn: $filter.includeAgent)
                .font(.system(size: theme.pointSize(.small)))

            if !snapshot.groups.isEmpty {
                Divider().overlay(p.border)
                Text("Groups")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.groups) { group in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(cssHex: group.colorHex) ?? p.accent)
                                .frame(width: 8, height: 8)
                            Text("path:\(group.name)")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.count)")
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                        }
                    }
                }
            }

            Text("Drag a node to move it, drag canvas or scroll to pan, pinch or ⌘+scroll to zoom, click a node to open.")
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.tertiaryText)
        }
        .padding(12)
        .frame(width: 248)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.swiftUIColor("border-strong", fallback: p.border)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .onChange(of: selectedNodeId) { _, next in
            if let next, !next.hasPrefix(KnowledgeGraphLogic.unresolvedNodePrefix) {
                filter.focusPageId = next
            }
        }
    }

    private var statusBar: some View {
        let p = theme.palette
        return HStack {
            Text("\(snapshot.nodes.count) pages · \(snapshot.totalLinkCount) links · \(snapshot.unresolvedCount) unresolved")
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.secondaryText)
            Spacer()
            Text(filter.includeAgent ? "Including agent knowledge" : "Graph of your knowledge")
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(p.surface)
    }

    private func startSettleAnimation() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            let totalFrames = 36
            for frame in 0..<totalFrames {
                if Task.isCancelled { return }
                let progress = Double(frame) / Double(totalFrames)
                let alpha = 0.35 * (1.0 - progress)
                let maxDisp = KnowledgeGraphLogic.relaxStep(
                    nodes: &snapshot.nodes,
                    edges: snapshot.edges,
                    pinnedNodeId: nil,
                    alpha: alpha
                )
                if maxDisp < 0.05 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func rebuildSnapshot(network: KnowledgeNetwork?) {
        settleTask?.cancel()
        settleTask = nil
        draggedNodeId = nil
        guard let network else {
            snapshot = KnowledgeGraphSnapshot()
            return
        }
        snapshot = KnowledgeGraphLogic.buildSnapshot(
            network: network,
            filter: filter,
            hoveredNodeId: hoveredNodeId,
            selectedNodeId: selectedNodeId,
            viewport: viewport
        )
    }
}
