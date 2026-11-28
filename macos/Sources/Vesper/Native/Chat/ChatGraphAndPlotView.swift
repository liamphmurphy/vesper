import SwiftUI
import VesperCore

// MARK: - Relationship Graph View (LAZYAGENTS-326)

struct ChatGraphCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatGraphSpec

    @State private var positions: [String: ChatGraphPosition] = [:]
    @State private var draggedNodeID: String?
    @State private var hoveredNodeID: String?
    @State private var pan: CGSize = .zero
    @State private var dragPanStart: CGSize?
    @State private var zoom: CGFloat = 1.0
    @State private var showLightbox = false
    @State private var savingLibrary = false
    @State private var savedLibrary = false

    private let baseWidth: CGFloat = 700
    private let baseHeight: CGFloat = 420

    private var viz: ChatVizPalette { ChatVizPalette(theme: theme) }

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "point.3.connected.trianglepath.dotted",
            title: spec.title ?? "Relationship Graph",
            subtitle: spec.subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            HStack(spacing: 6) {
                Button { zoom = max(0.5, zoom - 0.2) } label: {
                    Image(systemName: "minus.magnifyingglass").imageScale(.small)
                }
                .buttonStyle(.plain)
                Button { zoom = min(2.8, zoom + 0.2) } label: {
                    Image(systemName: "plus.magnifyingglass").imageScale(.small)
                }
                .buttonStyle(.plain)
                Button("Reset") {
                    zoom = 1.0
                    pan = .zero
                    positions = spec.computeLayout(width: Double(baseWidth), height: Double(baseHeight))
                }
                .buttonStyle(.plain)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)

                Button {
                    ChatVizExporter.copyPNG(
                        of: graphCanvas(height: 360)
                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                            .environment(\.vesperTheme, theme),
                        context: context
                    )
                } label: {
                    Image(systemName: "photo.on.rectangle").imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Copy graph as PNG")

                Button {
                    guard !savingLibrary else { return }
                    savingLibrary = true
                    Task {
                        defer { savingLibrary = false }
                        if await ChatVizExporter.savePNGToLibrary(
                            of: graphCanvas(height: 360)
                                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                                .environment(\.vesperTheme, theme),
                            title: spec.title ?? "graph",
                            context: context
                        ) {
                            savedLibrary = true
                        }
                    }
                } label: {
                    Image(systemName: savedLibrary ? "checkmark" : "bookmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .disabled(savingLibrary)
                .help(savedLibrary ? "Saved to Library" : "Save graph PNG to Library")
            }
            .foregroundStyle(p.tertiaryText)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if !spec.groups.isEmpty {
                    groupLegend
                    Rectangle().fill(p.rowBorder).frame(height: 1)
                }
                graphCanvas(height: 360)
            }
        }
        .onAppear {
            if positions.isEmpty {
                positions = spec.computeLayout(width: Double(baseWidth), height: Double(baseHeight))
            }
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Relationship Graph", subtitle: "\(spec.nodes.count) nodes · \(spec.edges.count) edges") {
                graphCanvas(height: 540)
            }
        }
    }

    private var groupLegend: some View {
        let palette = viz
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(spec.groups.enumerated()), id: \.element) { idx, group in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(palette.seriesColor(at: idx))
                            .frame(width: 8, height: 8)
                        Text(group)
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(theme.palette.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func colorForGroup(_ group: String?) -> Color {
        guard let group, let idx = spec.groups.firstIndex(of: group) else {
            return viz.seriesColor(at: 0)
        }
        return viz.seriesColor(at: idx)
    }

    private func screenPoint(for pos: ChatGraphPosition, in size: CGSize) -> CGPoint {
        let sx = (CGFloat(pos.x) - baseWidth / 2) * zoom + size.width / 2 + pan.width
        let sy = (CGFloat(pos.y) - baseHeight / 2) * zoom + size.height / 2 + pan.height
        return CGPoint(x: sx, y: sy)
    }

    private func worldPoint(from pt: CGPoint, in size: CGSize) -> ChatGraphPosition {
        let wx = (pt.x - size.width / 2 - pan.width) / max(zoom, 0.1) + baseWidth / 2
        let wy = (pt.y - size.height / 2 - pan.height) / max(zoom, 0.1) + baseHeight / 2
        return ChatGraphPosition(x: Double(wx), y: Double(wy))
    }

    private func hitTestNode(at pt: CGPoint, in size: CGSize) -> String? {
        for node in spec.nodes.reversed() {
            guard let pos = positions[node.id] else { continue }
            let sp = screenPoint(for: pos, in: size)
            let hitR = max(14, CGFloat(10 * node.size) * zoom + 4)
            let dx = pt.x - sp.x, dy = pt.y - sp.y
            if dx * dx + dy * dy <= hitR * hitR {
                return node.id
            }
        }
        return nil
    }

    private func graphCanvas(height: CGFloat) -> some View {
        let palette = viz
        let neighbors: Set<String>? = hoveredNodeID.map { spec.neighbors(of: $0) }

        return GeometryReader { geo in
            Canvas { ctx, size in
                // Draw edges
                for edge in spec.edges {
                    guard let p1 = positions[edge.from], let p2 = positions[edge.to] else { continue }
                    let a = screenPoint(for: p1, in: size)
                    let b = screenPoint(for: p2, in: size)
                    let isHighlighted = hoveredNodeID == nil || edge.from == hoveredNodeID || edge.to == hoveredNodeID
                    let strokeColor = isHighlighted ? palette.line : palette.line.opacity(0.22)

                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    ctx.stroke(path, with: .color(strokeColor), lineWidth: isHighlighted && hoveredNodeID != nil ? 2.0 : 1.2)

                    if edge.directed {
                        let dx = b.x - a.x, dy = b.y - a.y
                        let len = max(hypot(dx, dy), 1)
                        let ux = dx / len, uy = dy / len
                        let tip = CGPoint(x: b.x - ux * 13, y: b.y - uy * 13)
                        let wing1 = CGPoint(x: tip.x - ux * 7 - uy * 4, y: tip.y - uy * 7 + ux * 4)
                        let wing2 = CGPoint(x: tip.x - ux * 7 + uy * 4, y: tip.y - uy * 7 - ux * 4)
                        var arrow = Path()
                        arrow.move(to: tip)
                        arrow.addLine(to: wing1)
                        arrow.addLine(to: wing2)
                        arrow.closeSubpath()
                        ctx.fill(arrow, with: .color(strokeColor))
                    }

                    if let label = edge.label, !label.isEmpty, isHighlighted {
                        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 6)
                        let resolved = ctx.resolve(Text(label).font(.system(size: 9.5)).foregroundStyle(palette.muted))
                        ctx.draw(resolved, at: mid, anchor: .center)
                    }
                }

                // Draw nodes and labels
                for node in spec.nodes {
                    guard let pos = positions[node.id] else { continue }
                    let pt = screenPoint(for: pos, in: size)
                    let r = CGFloat(8.5 * node.size) * max(0.75, min(1.3, zoom))
                    let isActive = neighbors == nil || neighbors!.contains(node.id)
                    let isFocus = hoveredNodeID == node.id
                    let fill = colorForGroup(node.group).opacity(isActive ? 0.92 : 0.22)

                    let circle = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                    ctx.fill(circle, with: .color(fill))
                    ctx.stroke(circle, with: .color(isFocus ? palette.ink : palette.surface), lineWidth: isFocus ? 2.2 : 1.4)

                    let labelView = Text(node.label)
                        .font(.system(size: isFocus ? 11 : 10, weight: isFocus ? .semibold : .medium))
                        .foregroundStyle(isActive ? palette.ink : palette.muted.opacity(0.35))
                    ctx.draw(ctx.resolve(labelView), at: CGPoint(x: pt.x, y: pt.y + r + 8), anchor: .center)
                }
            }
            .background(palette.surface)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    hoveredNodeID = hitTestNode(at: pt, in: geo.size)
                case .ended:
                    hoveredNodeID = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if draggedNodeID == nil && dragPanStart == nil {
                            if let hit = hitTestNode(at: value.startLocation, in: geo.size) {
                                draggedNodeID = hit
                            } else {
                                dragPanStart = pan
                            }
                        }
                        if let nodeID = draggedNodeID {
                            positions[nodeID] = worldPoint(from: value.location, in: geo.size)
                        } else if let startPan = dragPanStart {
                            pan = CGSize(
                                width: startPan.width + value.translation.width,
                                height: startPan.height + value.translation.height
                            )
                        }
                    }
                    .onEnded { _ in
                        draggedNodeID = nil
                        dragPanStart = nil
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        zoom = max(0.5, min(2.8, val))
                    }
            )
        }
        .frame(height: height)
    }
}

// MARK: - Math Function Plotter View (LAZYAGENTS-327)

struct ChatPlotCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatPlotSpec

    @State private var paramValues: [String: Double]
    @State private var xMin: Double
    @State private var xMax: Double
    @State private var yMin: Double
    @State private var yMax: Double
    @State private var dragStartDomain: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)?
    @State private var hoverPoint: (x: Double, y: Double)?
    @State private var showLightbox = false

    init(spec: ChatPlotSpec) {
        self.spec = spec
        var params: [String: Double] = [:]
        for p in spec.parameters { params[p.name] = p.value }
        self._paramValues = State(initialValue: params)
        self._xMin = State(initialValue: spec.xMin)
        self._xMax = State(initialValue: spec.xMax)
        let defaultY = ChatPlotCardView.autoYDomain(spec: spec, params: params)
        self._yMin = State(initialValue: spec.yMin ?? defaultY.min)
        self._yMax = State(initialValue: spec.yMax ?? defaultY.max)
    }

    private var viz: ChatVizPalette { ChatVizPalette(theme: theme) }

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "function",
            title: spec.title ?? "Function Plot",
            subtitle: spec.subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            HStack(spacing: 6) {
                Button { zoomPlot(factor: 1.35) } label: {
                    Image(systemName: "minus.magnifyingglass").imageScale(.small)
                }
                .buttonStyle(.plain)
                Button { zoomPlot(factor: 0.74) } label: {
                    Image(systemName: "plus.magnifyingglass").imageScale(.small)
                }
                .buttonStyle(.plain)
                Button("Reset") { resetViewport() }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            }
            .foregroundStyle(p.tertiaryText)
        } content: {
            plotContent(height: 280)
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Function Plot", subtitle: spec.subtitle) {
                plotContent(height: 460)
            }
        }
    }

    private func plotContent(height: CGFloat) -> some View {
        let p = theme.palette
        let palette = viz

        return VStack(alignment: .leading, spacing: 0) {
            // Function legend & inline per-function errors
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(spec.functions) { fn in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(fn.error != nil ? theme.swiftUIColor("pill-blocked-fg", fallback: .red) : palette.seriesColor(at: fn.id))
                                .frame(width: 8, height: 8)
                            Text(fn.label)
                                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                .foregroundStyle(p.text)
                            if let err = fn.error {
                                Text("(\(err))")
                                    .font(.system(size: theme.pointSize(.micro)))
                                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                            }
                        }
                    }
                    if let hp = hoverPoint {
                        Text(String(format: "x=%.2f, y=%.2f", hp.x, hp.y))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Rectangle().fill(p.rowBorder).frame(height: 1)

            plotCanvas(height: height)

            if !spec.parameters.isEmpty {
                Rectangle().fill(p.rowBorder).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(spec.parameters) { param in
                        let binding = Binding<Double>(
                            get: { paramValues[param.name] ?? param.value },
                            set: { paramValues[param.name] = $0 }
                        )
                        HStack(spacing: 10) {
                            Text(param.name)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                                .foregroundStyle(p.text)
                                .frame(width: 48, alignment: .leading)
                            Slider(value: binding, in: param.min...param.max, step: param.step)
                            Text(ChatChartSpec.compactNumber(binding.wrappedValue))
                                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                .foregroundStyle(p.secondaryText)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func plotCanvas(height: CGFloat) -> some View {
        let palette = viz
        let vars = paramValues

        return GeometryReader { geo in
            Canvas { ctx, size in
                let w = Double(size.width)
                let h = Double(size.height)
                let dx = max(xMax - xMin, 1e-9)
                let dy = max(yMax - yMin, 1e-9)

                func toScreenX(_ x: Double) -> CGFloat { CGFloat((x - xMin) / dx * w) }
                func toScreenY(_ y: Double) -> CGFloat { CGFloat((1.0 - (y - yMin) / dy) * h) }

                // Gridlines & ticks
                for tx in ChatChartSpec.niceTicks(min: xMin, max: xMax, count: 6) {
                    let sx = toScreenX(tx)
                    var grid = Path()
                    grid.move(to: CGPoint(x: sx, y: 0))
                    grid.addLine(to: CGPoint(x: sx, y: size.height))
                    ctx.stroke(grid, with: .color(palette.grid), lineWidth: 1)
                    let lbl = Text(ChatChartSpec.compactNumber(tx)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(palette.muted)
                    ctx.draw(ctx.resolve(lbl), at: CGPoint(x: sx, y: size.height - 10), anchor: .center)
                }
                for ty in ChatChartSpec.niceTicks(min: yMin, max: yMax, count: 5) {
                    let sy = toScreenY(ty)
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: sy))
                    grid.addLine(to: CGPoint(x: size.width, y: sy))
                    ctx.stroke(grid, with: .color(palette.grid), lineWidth: 1)
                    let lbl = Text(ChatChartSpec.compactNumber(ty)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(palette.muted)
                    ctx.draw(ctx.resolve(lbl), at: CGPoint(x: 18, y: sy - 7), anchor: .leading)
                }

                // Origin axes
                if xMin <= 0 && xMax >= 0 {
                    let sx = toScreenX(0)
                    var axis = Path()
                    axis.move(to: CGPoint(x: sx, y: 0))
                    axis.addLine(to: CGPoint(x: sx, y: size.height))
                    ctx.stroke(axis, with: .color(palette.line), lineWidth: 1.4)
                }
                if yMin <= 0 && yMax >= 0 {
                    let sy = toScreenY(0)
                    var axis = Path()
                    axis.move(to: CGPoint(x: 0, y: sy))
                    axis.addLine(to: CGPoint(x: size.width, y: sy))
                    ctx.stroke(axis, with: .color(palette.line), lineWidth: 1.4)
                }

                // Plot each valid function
                let samples = max(180, Int(w))
                for fn in spec.functions {
                    guard let ast = fn.ast else { continue }
                    let color = palette.seriesColor(at: fn.id)
                    var path = Path()
                    var drawing = false
                    var lastY: Double?
                    var env = vars
                    for i in 0...samples {
                        let x = xMin + (Double(i) / Double(samples)) * dx
                        env["x"] = x
                        let y = ast.evaluate(variables: env)
                        guard y.isFinite, abs(y) < 1e9 else {
                            drawing = false
                            lastY = nil
                            continue
                        }
                        // Break path across vertical asymptotes (e.g. tan(x), 1/x)
                        if let prev = lastY, abs(y - prev) > dy * 4 {
                            drawing = false
                        }
                        let pt = CGPoint(x: toScreenX(x), y: toScreenY(y))
                        if !drawing {
                            path.move(to: pt)
                            drawing = true
                        } else {
                            path.addLine(to: pt)
                        }
                        lastY = y
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .background(palette.surface)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    let x = xMin + (Double(pt.x) / max(Double(geo.size.width), 1)) * (xMax - xMin)
                    let y = yMax - (Double(pt.y) / max(Double(geo.size.height), 1)) * (yMax - yMin)
                    hoverPoint = (x, y)
                case .ended:
                    hoverPoint = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStartDomain == nil {
                            dragStartDomain = (xMin, xMax, yMin, yMax)
                        }
                        guard let start = dragStartDomain else { return }
                        let shiftX = (Double(value.translation.width) / max(Double(geo.size.width), 1)) * (start.xMax - start.xMin)
                        let shiftY = (Double(value.translation.height) / max(Double(geo.size.height), 1)) * (start.yMax - start.yMin)
                        xMin = start.xMin - shiftX
                        xMax = start.xMax - shiftX
                        yMin = start.yMin + shiftY
                        yMax = start.yMax + shiftY
                    }
                    .onEnded { _ in
                        dragStartDomain = nil
                    }
            )
        }
        .frame(height: height)
    }

    private func zoomPlot(factor: Double) {
        let cx = (xMin + xMax) / 2
        let cy = (yMin + yMax) / 2
        let halfX = max(1e-4, (xMax - xMin) / 2 * factor)
        let halfY = max(1e-4, (yMax - yMin) / 2 * factor)
        xMin = cx - halfX; xMax = cx + halfX
        yMin = cy - halfY; yMax = cy + halfY
    }

    private func resetViewport() {
        xMin = spec.xMin
        xMax = spec.xMax
        let defY = Self.autoYDomain(spec: spec, params: paramValues)
        yMin = spec.yMin ?? defY.min
        yMax = spec.yMax ?? defY.max
    }

    private static func autoYDomain(spec: ChatPlotSpec, params: [String: Double]) -> (min: Double, max: Double) {
        var ys: [Double] = []
        let steps = 80
        var env = params
        for fn in spec.functions {
            guard let ast = fn.ast else { continue }
            for i in 0...steps {
                let x = spec.xMin + (Double(i) / Double(steps)) * (spec.xMax - spec.xMin)
                env["x"] = x
                let y = ast.evaluate(variables: env)
                if y.isFinite && abs(y) < 1e4 { ys.append(y) }
            }
        }
        guard let lo = ys.min(), let hi = ys.max() else { return (-5, 5) }
        if lo == hi { return (lo - 2, hi + 2) }
        let pad = (hi - lo) * 0.15
        return (lo - pad, hi + pad)
    }
}
