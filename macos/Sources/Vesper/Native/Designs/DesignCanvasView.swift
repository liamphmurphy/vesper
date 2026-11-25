import AppKit
import SwiftUI
import VesperCore

// MARK: - Design Asset Image Cache

@MainActor
@Observable
final class DesignAssetCache {
    private(set) var images: [String: CGImage] = [:]
    private var inFlight = Set<String>()

    func ensureLoaded(canvasId: String, assetIds: [String], client: APIClient?) {
        guard let client else { return }
        for id in assetIds where images[id] == nil && !inFlight.contains(id) {
            inFlight.insert(id)
            Task {
                defer { inFlight.remove(id) }
                if let data = try? await client.send(API.getDesignAsset(canvasId: canvasId, assetId: id)),
                   let nsImg = NSImage(data: data),
                   let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    images[id] = cg
                }
            }
        }
    }

    func store(assetId: String, data: Data) {
        if let nsImg = NSImage(data: data),
           let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            images[assetId] = cg
        }
    }
}

// MARK: - Design Tool & Camera Models

enum DesignTool: String, CaseIterable, Identifiable {
    case select, hand, frame, rect, ellipse, line, pen, text, sticky, section, connector

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: "Move (V)"
        case .hand: "Hand (H)"
        case .frame: "Frame (F)"
        case .rect: "Rectangle (R)"
        case .ellipse: "Ellipse (O)"
        case .line: "Line (L)"
        case .pen: "Pen (P)"
        case .text: "Text (T)"
        case .sticky: "Sticky (S)"
        case .section: "Section (⇧S)"
        case .connector: "Connector (C)"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .frame: "number"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .sticky: "note.text"
        case .section: "rectangle.dashed"
        case .connector: "arrow.right.circle"
        }
    }
}

// MARK: - Static Frame Canvas (Used by Prototype Present Mode & Review Previews)

struct DesignFrameCanvas: View {
    let ops: [DesignDrawOp]
    let box: DesignBox
    let background: String?
    let images: [String: CGImage]

    var body: some View {
        Canvas { gc, size in
            guard size.width > 0, size.height > 0, box.w > 0, box.h > 0 else { return }
            let sx = size.width / box.w
            let sy = size.height / box.h
            gc.withCGContext { ctx in
                ctx.saveGState()
                if let bg = background {
                    ctx.setFillColor(SlideCGDrawer.cgColor(bg))
                    ctx.fill(CGRect(origin: .zero, size: size))
                }
                ctx.scaleBy(x: sx, y: sy)
                ctx.translateBy(x: -box.x, y: -box.y)
                DesignCGDrawer.draw(ops: ops, images: images, in: ctx)
                ctx.restoreGState()
            }
        }
    }
}

// MARK: - Interactive Infinite Design Canvas

struct InteractiveDesignCanvas: View {
    enum Handle: CaseIterable { case nw, n, ne, e, se, s, sw, w }

    @Environment(\.vesperTheme) private var theme

    let design: DesignDocument
    let page: DesignPage
    let laid: DesignLaidPage
    let images: [String: CGImage]
    let readOnly: Bool
    let showPrototypeWires: Bool
    let reviewChanges: [DesignReviewChange]
    @Binding var selectedIds: [String]
    @Binding var tool: DesignTool
    @Binding var camera: DesignCamera
    @Binding var editingNodeId: String?
    let onCommitDesign: (DesignDocument) -> Void
    let onViewportChange: (CGSize) -> Void

    @State private var draftDesign: DesignDocument?
    @State private var panOriginCamera: DesignCamera?
    @State private var magnifyOriginCamera: DesignCamera?
    @State private var dragStartPositions: [String: (x: Double, y: Double)] = [:]
    @State private var drawBoxStart: CGPoint?
    @State private var drawBoxCurrent: CGPoint?
    @State private var penPoints: [DesignPt] = []
    @State private var connectStartId: String?
    @State private var connectCurrentWorld: CGPoint?
    @State private var inlineText: String = ""
    @FocusState private var inlineFocused: Bool

    private var shownDesign: DesignDocument { draftDesign ?? design }
    private var shownLaid: DesignLaidPage {
        if let d = draftDesign, let p = d.pages.first(where: { $0.id == page.id }) {
            return DesignLayoutEngine(design: d).layoutPage(p)
        }
        return laid
    }

    var body: some View {
        let curLaid = shownLaid
        let backdrop = CanvasBackdropLogic.resolveDesignBackdrop(pageBackgroundHex: curLaid.background)
        let bgColor: Color = switch backdrop {
        case .explicitHex(let hex): Color(cgColor: SlideCGDrawer.cgColor(hex))
        case .themeSurfaceSunken: theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)
        }

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                bgColor

                // Main vector canvas (120Hz CoreGraphics)
                Canvas { gc, size in
                    gc.withCGContext { ctx in
                        ctx.saveGState()
                        // Subtle dot grid at zoomed-in scales
                        if camera.z >= 0.45 {
                            drawDotGrid(in: ctx, size: size, backdrop: backdrop)
                        }
                        ctx.scaleBy(x: camera.z, y: camera.z)
                        ctx.translateBy(x: -camera.x, y: -camera.y)
                        DesignCGDrawer.draw(ops: curLaid.allOps, images: images, in: ctx)

                        // Prototype wires overlay
                        if showPrototypeWires {
                            drawPrototypeWires(in: ctx, laid: curLaid)
                        }
                        ctx.restoreGState()
                    }
                }
                .allowsHitTesting(false)

                // Top-level frame title labels
                ForEach(page.children.filter { $0.type == .frame || $0.type == .component }, id: \.id) { frame in
                    if let b = curLaid.boxes[frame.id] {
                        let pt = camera.worldToScreen(CGPoint(x: b.x, y: b.y))
                        Text(frame.name ?? "Frame")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(frame.type == .component ? Color.purple : theme.palette.secondaryText)
                            .position(x: pt.x + 40, y: pt.y - 10)
                            .allowsHitTesting(false)
                    }
                }

                // Selection outline & resize handles
                if !readOnly {
                    selectionOverlay(laid: curLaid)
                }

                // Active drawing preview (Frame/Rect/Ellipse/Section/Line/Marquee)
                if let a = drawBoxStart, let b = drawBoxCurrent {
                    let sa = camera.worldToScreen(a)
                    let sb = camera.worldToScreen(b)
                    if tool == .line {
                        Path { p in
                            p.move(to: sa)
                            p.addLine(to: sb)
                        }
                        .stroke(Color.accentColor, lineWidth: 2)
                    } else {
                        let rect = CGRect(x: min(sa.x, sb.x), y: min(sa.y, sb.y), width: abs(sb.x - sa.x), height: abs(sb.y - sa.y))
                        Rectangle()
                            .fill(Color.accentColor.opacity(tool == .select ? 0.12 : 0.08))
                            .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: tool == .section ? [6, 4] : [])))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }

                // Active connector preview
                if let cid = connectStartId, let fb = curLaid.boxes[cid], let cur = connectCurrentWorld {
                    let p0 = camera.worldToScreen(CGPoint(x: fb.x + fb.w / 2, y: fb.y + fb.h / 2))
                    let p1 = camera.worldToScreen(cur)
                    Path { p in p.move(to: p0); p.addLine(to: p1) }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }

                // Active pen polyline preview
                if penPoints.count >= 2 {
                    Path { p in
                        let first = camera.worldToScreen(CGPoint(x: penPoints[0].x, y: penPoints[0].y))
                        p.move(to: first)
                        for pt in penPoints.dropFirst() {
                            p.addLine(to: camera.worldToScreen(CGPoint(x: pt.x, y: pt.y)))
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 2)
                }

                // Review pins
                ForEach(reviewChanges.filter { $0.page == page.id && $0.box != nil }) { c in
                    if let b = c.box {
                        let pt = camera.worldToScreen(CGPoint(x: b.x, y: b.y))
                        let color: Color = c.kind == .added ? .green : c.kind == .removed ? .red : .orange
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: c.kind == .removed ? [6, 4] : []))
                                .frame(width: max(8, b.w * camera.z), height: max(8, b.h * camera.z))
                            Text("\(c.id + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(color, in: Capsule())
                                .offset(x: -6, y: -10)
                        }
                        .offset(x: pt.x, y: pt.y)
                        .allowsHitTesting(false)
                    }
                }

                // Inline text / sticky editor
                if !readOnly, let editId = editingNodeId, let found = DesignEditLogic.find(shownDesign, id: editId), let b = curLaid.boxes[editId] {
                    let pt = camera.worldToScreen(CGPoint(x: b.x, y: b.y))
                    let w = max(90, b.w * camera.z)
                    let h = max(36, b.h * camera.z)
                    TextEditor(text: $inlineText)
                        .font(.system(size: max(11, (found.node.paragraphs?.first?.runs.first?.size ?? 14) * camera.z)))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(
                            found.node.type == .sticky
                                ? Color(red: 0.99, green: 0.90, blue: 0.54)
                                : (theme.mode == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5))
                        .focused($inlineFocused)
                        .frame(width: w, height: h)
                        .offset(x: pt.x, y: pt.y)
                        .onExitCommand { commitInlineText() }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onCanvasScrollWheel { action in
                switch action {
                case .zoom(let factor, let ax, let ay):
                    camera = camera.zoomed(by: factor, around: CGPoint(x: ax, y: ay))
                    return true
                case .pan(let dx, let dy):
                    guard editingNodeId == nil else { return false }
                    camera = camera.panned(dx: dx, dy: dy)
                    return true
                case .ignore:
                    return false
                }
            }
            .gesture(mainGesture(viewport: geo.size, laid: curLaid))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { val in
                        let base = magnifyOriginCamera ?? camera
                        if magnifyOriginCamera == nil { magnifyOriginCamera = base }
                        camera = base.zoomed(by: Double(val.magnification), around: val.startLocation)
                    }
                    .onEnded { _ in
                        magnifyOriginCamera = nil
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { val in
                    guard !readOnly else { return }
                    let wpt = camera.screenToWorld(val.location)
                    let path = DesignHitTest.hitPath(page: page, boxes: curLaid.boxes, x: wpt.x, y: wpt.y, slop: 4 / camera.z)
                    if let hit = DesignHitTest.pick(path: path, selected: selectedIds, deeper: true) {
                        selectedIds = [hit.id]
                        if hit.type == .text || hit.type == .sticky {
                            inlineText = hit.type == .sticky ? (hit.stickyText ?? "") : DesignEditLogic.plainText(hit.paragraphs ?? [])
                            editingNodeId = hit.id
                            inlineFocused = true
                        }
                    }
                }
            )
            .onAppear { onViewportChange(geo.size) }
            .onChange(of: geo.size) { _, newSize in onViewportChange(newSize) }
            .onChange(of: editingNodeId) { oldId, newId in
                if let oldId, newId == nil { commitInlineText(for: oldId) }
            }
        }
    }

    private func drawDotGrid(in ctx: CGContext, size: CGSize, backdrop: CanvasBackdropColor) {
        let step = 20.0 * camera.z
        guard step >= 8 else { return }
        let dotColor: CGColor = switch backdrop {
        case .explicitHex(let hex):
            CanvasBackdropLogic.isHexDark(hex) ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.10)
        case .themeSurfaceSunken:
            if let c = theme.color("text-tertiary") {
                CGColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.35)
            } else {
                theme.mode == .dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.10)
            }
        }
        ctx.setFillColor(dotColor)
        let rawOffX = (-camera.x * camera.z).truncatingRemainder(dividingBy: step)
        let rawOffY = (-camera.y * camera.z).truncatingRemainder(dividingBy: step)
        let offX = rawOffX < 0 ? rawOffX + step : rawOffX
        let offY = rawOffY < 0 ? rawOffY + step : rawOffY
        var x = offX
        while x < size.width {
            var y = offY
            while y < size.height {
                ctx.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
                y += step
            }
            x += step
        }
    }

    private func drawPrototypeWires(in ctx: CGContext, laid: DesignLaidPage) {
        ctx.setStrokeColor(CGColor(red: 0.44, green: 0.49, blue: 0.96, alpha: 0.85))
        ctx.setLineWidth(2 / camera.z)
        for link in design.links {
            guard let fb = laid.boxes[link.from], let tb = laid.boxes[link.to] else { continue }
            let p0 = CGPoint(x: fb.x + fb.w, y: fb.y + fb.h / 2)
            let p1 = CGPoint(x: tb.x, y: tb.y + tb.h / 2)
            let ctrl = max(40, abs(p1.x - p0.x) * 0.45)
            ctx.beginPath()
            ctx.move(to: p0)
            ctx.addCurve(to: p1, control1: CGPoint(x: p0.x + ctrl, y: p0.y), control2: CGPoint(x: p1.x - ctrl, y: p1.y))
            ctx.strokePath()
        }
    }

    @ViewBuilder
    private func selectionOverlay(laid: DesignLaidPage) -> some View {
        let selBoxes = selectedIds.compactMap { laid.boxes[$0] }
        if !selBoxes.isEmpty {
            let l = selBoxes.map(\.x).min()!
            let t = selBoxes.map(\.y).min()!
            let r = selBoxes.map { $0.x + $0.w }.max()!
            let b = selBoxes.map { $0.y + $0.h }.max()!
            let p0 = camera.worldToScreen(CGPoint(x: l, y: t))
            let w = max(6, (r - l) * camera.z)
            let h = max(6, (b - t) * camera.z)

            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: w, height: h)
                .offset(x: p0.x, y: p0.y)
                .allowsHitTesting(false)

            if selectedIds.count == 1, let onlyId = selectedIds.first,
               let found = DesignEditLogic.find(shownDesign, id: onlyId),
               found.node.type != .connector,
               editingNodeId != onlyId {
                ForEach(Handle.allCases, id: \.self) { handle in
                    let pt = handlePos(handle, rect: CGRect(x: p0.x, y: p0.y, width: w, height: h))
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(pt)
                        .gesture(resizeGesture(node: found.node, handle: handle))
                }
            }
        }
    }

    private func handlePos(_ h: Handle, rect: CGRect) -> CGPoint {
        switch h {
        case .nw: CGPoint(x: rect.minX, y: rect.minY)
        case .n:  CGPoint(x: rect.midX, y: rect.minY)
        case .ne: CGPoint(x: rect.maxX, y: rect.minY)
        case .e:  CGPoint(x: rect.maxX, y: rect.midY)
        case .se: CGPoint(x: rect.maxX, y: rect.maxY)
        case .s:  CGPoint(x: rect.midX, y: rect.maxY)
        case .sw: CGPoint(x: rect.minX, y: rect.maxY)
        case .w:  CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func mainGesture(viewport: CGSize, laid: DesignLaidPage) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { val in
                let wStart = camera.screenToWorld(val.startLocation)
                let wCur = camera.screenToWorld(val.location)

                // Hand tool or Option-drag pans the infinite canvas
                if tool == .hand || NSEvent.modifierFlags.contains(.option) {
                    if panOriginCamera == nil { panOriginCamera = camera }
                    if let orig = panOriginCamera {
                        camera = DesignCamera(x: orig.x - val.translation.width / orig.z, y: orig.y - val.translation.height / orig.z, z: orig.z)
                    }
                    return
                }
                guard !readOnly else { return }

                switch tool {
                case .select:
                    if dragStartPositions.isEmpty && drawBoxStart == nil {
                        commitInlineText()
                        let path = DesignHitTest.hitPath(page: page, boxes: laid.boxes, x: wStart.x, y: wStart.y, slop: 4 / camera.z)
                        let deep = NSEvent.modifierFlags.contains(.command)
                        if let hit = DesignHitTest.pick(path: path, selected: selectedIds, deep: deep) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                if selectedIds.contains(hit.id) { selectedIds.removeAll { $0 == hit.id } }
                                else { selectedIds.append(hit.id) }
                            } else if !selectedIds.contains(hit.id) {
                                selectedIds = [hit.id]
                            }
                            dragStartPositions = Dictionary(uniqueKeysWithValues: selectedIds.compactMap { id -> (String, (Double, Double))? in
                                guard let f = DesignEditLogic.find(design, id: id), f.node.type != .connector else { return nil }
                                return (id, (f.node.x, f.node.y))
                            })
                        } else {
                            selectedIds = []
                            drawBoxStart = wStart
                            drawBoxCurrent = wCur
                        }
                    } else if drawBoxStart != nil {
                        drawBoxCurrent = wCur
                    } else if !dragStartPositions.isEmpty {
                        let dx = val.translation.width / camera.z
                        let dy = val.translation.height / camera.z
                        if abs(dx) > 0.5 || abs(dy) > 0.5 {
                            draftDesign = DesignEditLogic.mapTree(design) { n in
                                guard let orig = dragStartPositions[n.id] else { return n }
                                var m = n
                                m.x = DesignSchema.round2(orig.x + dx)
                                m.y = DesignSchema.round2(orig.y + dy)
                                return m
                            }
                        }
                    }
                case .frame, .rect, .ellipse, .section, .line:
                    if drawBoxStart == nil { drawBoxStart = wStart }
                    drawBoxCurrent = wCur
                case .pen:
                    penPoints.append(DesignPt(wCur.x, wCur.y))
                case .connector:
                    if connectStartId == nil {
                        let path = DesignHitTest.hitPath(page: page, boxes: laid.boxes, x: wStart.x, y: wStart.y, slop: 6 / camera.z)
                        connectStartId = DesignHitTest.connectTarget(path: path)?.id
                    }
                    connectCurrentWorld = wCur
                case .text, .sticky, .hand:
                    break
                }
            }
            .onEnded { val in
                defer {
                    panOriginCamera = nil
                    dragStartPositions = [:]
                    drawBoxStart = nil
                    drawBoxCurrent = nil
                    connectStartId = nil
                    connectCurrentWorld = nil
                    penPoints = []
                }
                if panOriginCamera != nil || readOnly { return }
                let wStart = camera.screenToWorld(val.startLocation)
                let wEnd = camera.screenToWorld(val.location)

                switch tool {
                case .select:
                    if let a = drawBoxStart, let b = drawBoxCurrent {
                        let m = DesignBox(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(b.x - a.x), h: abs(b.y - a.y))
                        if m.w > 4 || m.h > 4 {
                            selectedIds = page.children.compactMap { n in
                                guard n.type != .connector, let nb = laid.boxes[n.id] else { return nil }
                                return (nb.x >= m.x && nb.y >= m.y && nb.x + nb.w <= m.x + m.w && nb.y + nb.h <= m.y + m.h) ? n.id : nil
                            }
                        }
                    } else if let finalDoc = draftDesign, finalDoc != design {
                        onCommitDesign(DesignLayoutEngine.settle(finalDoc))
                    }
                    draftDesign = nil
                case .frame, .rect, .ellipse, .section:
                    let bx = min(wStart.x, wEnd.x), by = min(wStart.y, wEnd.y)
                    let bw = max(abs(wEnd.x - wStart.x), tool == .frame ? 393 : 160)
                    let bh = max(abs(wEnd.y - wStart.y), tool == .frame ? 852 : 120)
                    let box = DesignBox(x: DesignSchema.round2(bx), y: DesignSchema.round2(by), w: DesignSchema.round2(bw), h: DesignSchema.round2(bh))
                    let node: DesignNode = switch tool {
                    case .frame: DesignEditLogic.newFrame(box)
                    case .ellipse: DesignEditLogic.newShape("ellipse", box)
                    case .section: DesignEditLogic.newSection(in: design, box)
                    default: DesignEditLogic.newShape("rect", box)
                    }
                    let next = DesignEditLogic.insertNodes(design, parent: page.id, nodes: [node])
                    onCommitDesign(DesignLayoutEngine.settle(next))
                    selectedIds = [node.id]
                    tool = .select
                case .line:
                    if let p = DesignEditLogic.pathFrom(points: [DesignPt(wStart.x, wStart.y), DesignPt(wEnd.x, wEnd.y)], closed: false, name: "Line") {
                        onCommitDesign(DesignLayoutEngine.settle(DesignEditLogic.insertNodes(design, parent: page.id, nodes: [p])))
                        selectedIds = [p.id]
                    }
                    tool = .select
                case .pen:
                    if penPoints.count >= 2, let p = DesignEditLogic.pathFrom(points: penPoints, closed: false) {
                        onCommitDesign(DesignLayoutEngine.settle(DesignEditLogic.insertNodes(design, parent: page.id, nodes: [p])))
                        selectedIds = [p.id]
                    }
                    tool = .select
                case .text:
                    let node = DesignEditLogic.newText(x: DesignSchema.round2(wEnd.x), y: DesignSchema.round2(wEnd.y))
                    onCommitDesign(DesignLayoutEngine.settle(DesignEditLogic.insertNodes(design, parent: page.id, nodes: [node])))
                    selectedIds = [node.id]
                    inlineText = "Text"
                    editingNodeId = node.id
                    inlineFocused = true
                    tool = .select
                case .sticky:
                    let node = DesignEditLogic.newSticky(x: DesignSchema.round2(wEnd.x - 100), y: DesignSchema.round2(wEnd.y - 100), text: "Note")
                    onCommitDesign(DesignLayoutEngine.settle(DesignEditLogic.insertNodes(design, parent: page.id, nodes: [node])))
                    selectedIds = [node.id]
                    inlineText = "Note"
                    editingNodeId = node.id
                    inlineFocused = true
                    tool = .select
                case .connector:
                    if let fromId = connectStartId {
                        let endPath = DesignHitTest.hitPath(page: page, boxes: laid.boxes, x: wEnd.x, y: wEnd.y, slop: 8 / camera.z)
                        if let toId = DesignHitTest.connectTarget(path: endPath)?.id,
                           let res = DesignEditLogic.connectNodes(design, from: fromId, to: toId) {
                            onCommitDesign(DesignLayoutEngine.settle(res.design))
                            selectedIds = [res.id]
                        }
                    }
                    tool = .select
                case .hand:
                    break
                }
            }
    }

    private func resizeGesture(node: DesignNode, handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { val in
                let dx = val.translation.width / camera.z
                let dy = val.translation.height / camera.z
                var x = node.x, y = node.y, w = node.w, h = node.h
                switch handle {
                case .nw: x += dx; y += dy; w -= dx; h -= dy
                case .n:  y += dy; h -= dy
                case .ne: y += dy; w += dx; h -= dy
                case .e:  w += dx
                case .se: w += dx; h += dy
                case .s:  h += dy
                case .sw: x += dx; w -= dx; h += dy
                case .w:  x += dx; w -= dx
                }
                let nextBox = DesignBox(x: x, y: y, w: max(8, w), h: max(8, h))
                draftDesign = DesignEditLogic.mapNode(design, id: node.id) { DesignEditLogic.resizeNode($0, to: nextBox) }
            }
            .onEnded { _ in
                if let finalDoc = draftDesign, finalDoc != design {
                    onCommitDesign(DesignLayoutEngine.settle(finalDoc))
                }
                draftDesign = nil
            }
    }

    private func commitInlineText() {
        guard let id = editingNodeId else { return }
        editingNodeId = nil
        commitInlineText(for: id)
    }

    private func commitInlineText(for id: String) {
        let updated = DesignEditLogic.mapNode(design, id: id) { n in
            var m = n
            if m.type == .sticky { m.stickyText = inlineText }
            else if m.type == .text { m.paragraphs = DesignEditLogic.withPlainText(m.paragraphs ?? [], text: inlineText) }
            return m
        }
        if updated != design { onCommitDesign(DesignLayoutEngine.settle(updated)) }
    }
}
