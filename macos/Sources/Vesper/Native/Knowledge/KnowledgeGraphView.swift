import SwiftUI
import VesperCore

/// Native SwiftUI Canvas renderer for the Knowledge vault graph.
struct KnowledgeGraphView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var filter = KnowledgeGraphFilter()
    @State private var viewport = KnowledgeGraphViewport()
    @State private var dragStartViewport: KnowledgeGraphViewport?
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
    }

    private var graphCanvas: some View {
        let p = theme.palette
        let accentColor = p.accent
        let borderStrong = theme.swiftUIColor("border-strong", fallback: p.border)
        let textColor = p.text
        let secondaryText = p.secondaryText
        let tertiaryText = p.tertiaryText

        let activeFocus = hoveredNodeId ?? selectedNodeId
        let layoutLinks = snapshot.edges.map { KnowledgeGraphInputLink(source: $0.source, target: $0.target) }
        let activeNeighbors: Set<String>? = activeFocus.map {
            KnowledgeGraphLogic.neighborhood(of: $0, edges: layoutLinks, hops: 1)
        }
        let searchQuery = filter.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nodeById = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let labelAll = snapshot.nodes.count < 60 || viewport.scale > 2.0

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

                    let strokeColor = lit ? accentColor : borderStrong
                    let style = edge.isUnresolved
                        ? StrokeStyle(lineWidth: lit ? 1.5 : 1.0, dash: [4, 3])
                        : StrokeStyle(lineWidth: lit ? 1.8 : 1.0)
                    gc.opacity = dimmed ? 0.2 : (edge.isUnresolved ? 0.65 : 0.9)
                    gc.stroke(path, with: .color(strokeColor), style: style)
                }

                for node in snapshot.nodes {
                    let pt = viewport.worldToScreen(x: node.x, y: node.y, bounds: snapshot.bounds, canvasWidth: w, canvasHeight: h)
                    let screenRadius = max(3.0, min(16.0, node.radius * ppu))
                    let matchesSearch = searchQuery.isEmpty
                        || node.title.lowercased().contains(searchQuery)
                        || node.path.lowercased().contains(searchQuery)
                    let inNeighborhood = activeNeighbors?.contains(node.id) ?? true
                    let isDimmed = !inNeighborhood || !matchesSearch
                    let isFocused = node.id == hoveredNodeId || node.id == selectedNodeId
                    let showLabel = labelAll || node.degree >= 6 || isFocused || (!searchQuery.isEmpty && matchesSearch)

                    let circleRect = CGRect(
                        x: pt.x - screenRadius,
                        y: pt.y - screenRadius,
                        width: screenRadius * 2,
                        height: screenRadius * 2
                    )
                    let circle = Path(ellipseIn: circleRect)

                    gc.opacity = isDimmed ? 0.2 : 1.0
                    if node.isUnresolved {
                        gc.stroke(circle, with: .color(tertiaryText), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                    } else {
                        let fill = Color(cssHex: node.colorHex) ?? tertiaryText
                        gc.fill(circle, with: .color(fill))
                    }
                    if isFocused {
                        gc.stroke(circle, with: .color(textColor), lineWidth: 1.6)
                    }

                    if showLabel {
                        let displayTitle = node.title.count > 28 ? String(node.title.prefix(27)) + "…" : node.title
                        let text = Text(displayTitle)
                            .font(.system(size: 10.5, weight: isFocused ? .semibold : .regular))
                            .foregroundStyle(isFocused ? textColor : secondaryText)
                        gc.draw(
                            gc.resolve(text),
                            at: CGPoint(x: pt.x, y: pt.y + screenRadius + 9),
                            anchor: .center
                        )
                    }
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
                        let start = dragStartViewport ?? viewport
                        if dragStartViewport == nil { dragStartViewport = start }
                        viewport = start.panned(
                            deltaX: Double(value.translation.width),
                            deltaY: Double(value.translation.height),
                            canvasWidth: Double(proxy.size.width),
                            canvasHeight: Double(proxy.size.height),
                            bounds: snapshot.bounds
                        )
                    }
                    .onEnded { _ in
                        dragStartViewport = nil
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

            Text("Drag or scroll to pan, pinch or ⌘+scroll to zoom, click a node to open.")
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

    private func rebuildSnapshot(network: KnowledgeNetwork?) {
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
