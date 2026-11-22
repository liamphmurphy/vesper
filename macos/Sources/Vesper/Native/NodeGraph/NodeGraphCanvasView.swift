import SwiftUI
import VesperCore

/// Reusable pure-SwiftUI `Canvas` node graph view for both the Run Graph DAG and the Workflow Editor/Run.
/// Supports smooth pan, `MagnificationGesture` zoom, fit-to-view, orthogonal/bezier edges with arrows,
/// selection, and interactive editing (drag nodes, drag output port -> input port to connect).
struct NodeGraphCanvasView: View {
    @Environment(\.vesperTheme) private var theme

    let document: NodeGraphDocument
    @Binding var viewport: NodeGraphViewport
    var interactive: Bool = false
    var showGrid: Bool = true
    var showControls: Bool = true

    var onSelectNode: ((String?) -> Void)?
    var onActivateNode: ((String) -> Void)?
    var onSelectEdge: ((String?) -> Void)?
    var onMoveNode: ((String, GraphPoint) -> Void)?
    var onConnect: ((String, String) -> Void)?

    @State private var dragMode: DragMode = .none
    @State private var lastDragLocation: CGPoint?
    @State private var dragNodeInitialOrigin: GraphPoint?
    @State private var connectingFromNodeId: String?
    @State private var connectingCursor: GraphPoint?
    @State private var magnificationBaseScale: Double?
    @State private var canvasSize: CGSize = .zero
    @State private var didInitialFit = false

    private enum DragMode: Equatable {
        case none
        case pan
        case moveNode(String)
        case connect(String)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    drawCanvas(ctx: &ctx, size: size)
                }
                .background(theme.palette.surface)
                .contentShape(Rectangle())
                .gesture(canvasDragGesture)
                .gesture(canvasMagnifyGesture)
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                    handleDoubleTap(at: value.location)
                })
                .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { value in
                    handleSingleTap(at: value.location)
                })

                if showControls {
                    controlsOverlay(size: geo.size)
                        .padding(10)
                }
            }
            .onAppear {
                canvasSize = geo.size
                fitIfNeeded(size: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                fitIfNeeded(size: newSize)
            }
            .onChange(of: document.nodes.count) { oldCount, newCount in
                if oldCount == 0 && newCount > 0 {
                    fitToView(size: geo.size)
                }
            }
        }
    }

    // MARK: - Gestures

    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragMode == .none {
                    let startGraph = viewport.screenToGraph(GraphPoint(x: value.startLocation.x, y: value.startLocation.y))
                    let hit = document.hitTest(graphPoint: startGraph, interactive: interactive)
                    switch hit {
                    case .port(let nodeId, .output) where interactive:
                        dragMode = .connect(nodeId)
                        connectingFromNodeId = nodeId
                        connectingCursor = viewport.screenToGraph(GraphPoint(x: value.location.x, y: value.location.y))
                    case .node(let nodeId) where interactive:
                        dragMode = .moveNode(nodeId)
                        dragNodeInitialOrigin = document.node(id: nodeId)?.frame.origin
                        onSelectNode?(nodeId)
                    default:
                        dragMode = .pan
                        lastDragLocation = value.startLocation
                    }
                }

                switch dragMode {
                case .pan:
                    let prev = lastDragLocation ?? value.startLocation
                    let dx = value.location.x - prev.x
                    let dy = value.location.y - prev.y
                    viewport.pan(by: GraphPoint(x: dx, y: dy))
                    lastDragLocation = value.location
                case .moveNode(let nodeId):
                    guard let initial = dragNodeInitialOrigin else { return }
                    let dx = value.translation.width / viewport.scale
                    let dy = value.translation.height / viewport.scale
                    onMoveNode?(nodeId, GraphPoint(x: initial.x + dx, y: initial.y + dy))
                case .connect:
                    connectingCursor = viewport.screenToGraph(GraphPoint(x: value.location.x, y: value.location.y))
                case .none:
                    break
                }
            }
            .onEnded { value in
                if case .connect(let sourceId) = dragMode {
                    let endGraph = viewport.screenToGraph(GraphPoint(x: value.location.x, y: value.location.y))
                    let hit = document.hitTest(graphPoint: endGraph, interactive: interactive, portRadius: 16)
                    switch hit {
                    case .port(let targetId, .input), .node(let targetId):
                        if sourceId != targetId {
                            onConnect?(sourceId, targetId)
                        }
                    default:
                        break
                    }
                }
                dragMode = .none
                lastDragLocation = nil
                dragNodeInitialOrigin = nil
                connectingFromNodeId = nil
                connectingCursor = nil
            }
    }

    private var canvasMagnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = magnificationBaseScale ?? viewport.scale
                if magnificationBaseScale == nil { magnificationBaseScale = base }
                let anchor = GraphPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
                viewport.setZoom(base * Double(value), around: anchor)
            }
            .onEnded { _ in
                magnificationBaseScale = nil
            }
    }

    private func handleSingleTap(at location: CGPoint) {
        let gp = viewport.screenToGraph(GraphPoint(x: location.x, y: location.y))
        switch document.hitTest(graphPoint: gp, interactive: interactive) {
        case .node(let id):
            onSelectNode?(id)
        case .edge(let id):
            onSelectEdge?(id)
        case .port(let nodeId, _):
            onSelectNode?(nodeId)
        case .none:
            onSelectNode?(nil)
            onSelectEdge?(nil)
        }
    }

    private func handleDoubleTap(at location: CGPoint) {
        let gp = viewport.screenToGraph(GraphPoint(x: location.x, y: location.y))
        if case .node(let id) = document.hitTest(graphPoint: gp, interactive: interactive) {
            onActivateNode?(id)
        }
    }

    // MARK: - Controls

    private func fitIfNeeded(size: CGSize) {
        guard !didInitialFit, size.width > 40, size.height > 40, document.contentBounds != nil else { return }
        fitToView(size: size)
        didInitialFit = true
    }

    private func fitToView(size: CGSize) {
        guard let bounds = document.contentBounds else { return }
        viewport.fitToView(
            contentBounds: bounds,
            viewportSize: GraphSize(width: size.width, height: size.height),
            padding: 32,
            maxFitScale: 1.05
        )
    }

    private func controlsOverlay(size: CGSize) -> some View {
        let anchor = GraphPoint(x: size.width * 0.5, y: size.height * 0.5)
        return HStack(spacing: 4) {
            Button {
                viewport.zoom(factor: 0.85, around: anchor)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")

            Text("\(Int(round(viewport.scale * 100)))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 40)

            Button {
                viewport.zoom(factor: 1.18, around: anchor)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")

            Divider().frame(height: 14)

            Button("Fit") {
                fitToView(size: size)
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.palette.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }

    // MARK: - Canvas Rendering

    private func drawCanvas(ctx: inout GraphicsContext, size: CGSize) {
        if showGrid {
            drawDotGrid(ctx: &ctx, size: size)
        }
        for edge in document.edges {
            drawEdge(ctx: &ctx, edge: edge)
        }
        if let fromId = connectingFromNodeId,
           let source = document.node(id: fromId),
           let cursor = connectingCursor {
            drawDraftConnection(ctx: &ctx, from: source.outputPortPosition, to: cursor)
        }
        for node in document.nodes {
            drawNode(ctx: &ctx, node: node)
        }
    }

    private func drawDotGrid(ctx: inout GraphicsContext, size: CGSize) {
        let spacing = max(12.0, 22.0 * viewport.scale)
        let ox = viewport.offset.x.truncatingRemainder(dividingBy: spacing)
        let oy = viewport.offset.y.truncatingRemainder(dividingBy: spacing)
        let dotColor = theme.palette.border.opacity(0.65)
        var x = ox < 0 ? ox + spacing : ox
        while x < size.width {
            var y = oy < 0 ? oy + spacing : oy
            while y < size.height {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(dotColor))
                y += spacing
            }
            x += spacing
        }
    }

    private func drawEdge(ctx: inout GraphicsContext, edge: NodeGraphEdgeModel) {
        let pts = document.edgePolyline(edge).map { p -> CGPoint in
            let s = viewport.graphToScreen(p)
            return CGPoint(x: s.x, y: s.y)
        }
        guard pts.count >= 2 else { return }

        let isSelected = document.selectedEdgeId == edge.id
        let strokeColor: Color = isSelected ? theme.palette.accent : toneStroke(edge.tone, fallback: theme.palette.secondaryText.opacity(0.65))
        let lineWidth: CGFloat = isSelected ? 2.4 : 1.5

        var path = Path()
        if pts.count == 2 {
            let p0 = pts[0], p1 = pts[1]
            let dx = max(24, abs(p1.x - p0.x) * 0.45)
            path.move(to: p0)
            path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
        } else {
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
        }

        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: edge.isDashed ? [5, 4] : [])
        ctx.stroke(path, with: .color(strokeColor), style: style)

        // Arrowhead at end of edge
        let tip = pts[pts.count - 1]
        let prev = pts[pts.count - 2]
        let angle = atan2(tip.y - prev.y, tip.x - prev.x)
        let arrowLen: CGFloat = 7
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - arrowLen * cos(angle - 0.42), y: tip.y - arrowLen * sin(angle - 0.42)))
        arrow.addLine(to: CGPoint(x: tip.x - arrowLen * cos(angle + 0.42), y: tip.y - arrowLen * sin(angle + 0.42)))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(strokeColor))
    }

    private func drawDraftConnection(ctx: inout GraphicsContext, from: GraphPoint, to: GraphPoint) {
        let p0s = viewport.graphToScreen(from)
        let p1s = viewport.graphToScreen(to)
        let p0 = CGPoint(x: p0s.x, y: p0s.y)
        let p1 = CGPoint(x: p1s.x, y: p1s.y)
        let dx = max(24, abs(p1.x - p0.x) * 0.45)
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
        ctx.stroke(path, with: .color(theme.palette.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }

    private func drawNode(ctx: inout GraphicsContext, node: NodeGraphNodeModel) {
        let tl = viewport.graphToScreen(node.frame.origin)
        let rect = CGRect(
            x: tl.x,
            y: tl.y,
            width: node.frame.size.width * viewport.scale,
            height: node.frame.size.height * viewport.scale
        )
        let isSelected = document.selectedNodeId == node.id
        let opacity: Double = node.diff == .removed ? 0.58 : 1.0

        let bg = toneFill(node.tone)
        let border = isSelected ? theme.palette.accent : toneStroke(node.tone, fallback: theme.palette.border)
        let borderWidth: CGFloat = (isSelected || node.isLive || node.tone == .human) ? 2.0 : 1.2
        let strokeStyle = StrokeStyle(lineWidth: borderWidth, dash: node.isDashed ? [5, 3] : [])

        let shapePath: Path
        switch node.shape {
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            shapePath = p
        case .pill:
            shapePath = Path(roundedRect: rect, cornerRadius: rect.height * 0.5)
        case .card:
            shapePath = Path(roundedRect: rect, cornerRadius: max(6, 10 * viewport.scale))
        }

        ctx.drawLayer { layer in
            layer.opacity = opacity
            layer.fill(shapePath, with: .color(bg))
            layer.stroke(shapePath, with: .color(border), style: strokeStyle)

            if viewport.scale >= 0.45 {
                drawNodeLabels(ctx: &layer, node: node, rect: rect)
            }
            if interactive {
                drawNodePorts(ctx: &layer, node: node, rect: rect)
            }
        }
    }

    private func drawNodeLabels(ctx: inout GraphicsContext, node: NodeGraphNodeModel, rect: CGRect) {
        let pad = 8 * viewport.scale
        let scale = viewport.scale

        if node.shape == .diamond {
            let text = Text(node.title)
                .font(.system(size: max(9, 11.5 * scale), weight: .semibold))
                .foregroundStyle(toneText(node.tone))
            ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            return
        }

        var y = rect.minY + pad
        if let eyebrow = node.eyebrow, !eyebrow.isEmpty {
            let eText = Text(eyebrow)
                .font(.system(size: max(8, 9.5 * scale), weight: .semibold))
                .foregroundStyle(node.tone == .human ? toneStroke(.human, fallback: .orange) : theme.palette.tertiaryText)
            ctx.draw(eText, at: CGPoint(x: rect.minX + pad, y: y), anchor: .topLeading)
            y += 13 * scale
        }

        let title = Text(node.title)
            .font(.system(size: max(9, 12.5 * scale), weight: .semibold))
            .foregroundStyle(toneText(node.tone))
        ctx.draw(title, at: CGPoint(x: rect.minX + pad, y: y), anchor: .topLeading)

        if node.isLive {
            let r = 4 * scale
            let dotRect = CGRect(x: rect.maxX - pad - r * 2, y: y + 2 * scale, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: dotRect), with: .color(theme.palette.accent))
        }

        if !node.subtitle.isEmpty {
            let sub = Text(node.subtitle)
                .font(.system(size: max(8, 10.5 * scale)))
                .foregroundStyle(theme.palette.secondaryText)
            ctx.draw(sub, at: CGPoint(x: rect.minX + pad, y: y + 16 * scale), anchor: .topLeading)
        }
    }

    private func drawNodePorts(ctx: inout GraphicsContext, node: NodeGraphNodeModel, rect: CGRect) {
        let r = max(4.0, 5.0 * viewport.scale)
        let fill = theme.palette.background
        let stroke = theme.palette.accent
        if node.hasInputPort {
            let p = CGRect(x: rect.minX - r, y: rect.midY - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: p), with: .color(fill))
            ctx.stroke(Path(ellipseIn: p), with: .color(stroke), lineWidth: 1.5)
        }
        if node.hasOutputPort {
            let p = CGRect(x: rect.maxX - r, y: rect.midY - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: p), with: .color(fill))
            ctx.stroke(Path(ellipseIn: p), with: .color(stroke), lineWidth: 1.5)
        }
    }

    // MARK: - Theme Mapping

    private func toneFill(_ tone: NodeGraphTone) -> Color {
        switch tone {
        case .done: theme.swiftUIColor("pill-done-bg", fallback: Color.green.opacity(0.12))
        case .accent: theme.swiftUIColor("accent-soft", fallback: theme.palette.accent.opacity(0.12))
        case .human: theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.14))
        case .blocked: theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.12))
        case .neutral: theme.palette.background
        }
    }

    private func toneStroke(_ tone: NodeGraphTone, fallback: Color) -> Color {
        switch tone {
        case .done: theme.swiftUIColor("state-done", fallback: .green)
        case .accent: theme.palette.accent
        case .human: theme.swiftUIColor("state-human", fallback: .orange)
        case .blocked: theme.swiftUIColor("state-blocked", fallback: .red)
        case .neutral: fallback
        }
    }

    private func toneText(_ tone: NodeGraphTone) -> Color {
        switch tone {
        case .done: theme.swiftUIColor("pill-done-fg", fallback: theme.palette.text)
        case .human: theme.swiftUIColor("pill-human-fg", fallback: theme.palette.text)
        case .blocked: theme.swiftUIColor("pill-blocked-fg", fallback: theme.palette.text)
        case .accent, .neutral: theme.palette.text
        }
    }
}
