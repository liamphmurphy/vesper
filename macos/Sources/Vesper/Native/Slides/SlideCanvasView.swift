import AppKit
import SwiftUI
import VesperCore

// MARK: - Slide Asset Image Cache

@MainActor
@Observable
final class SlideAssetCache {
    private(set) var images: [String: CGImage] = [:]
    private(set) var rawBytes: [String: Data] = [:]
    private var inFlight = Set<String>()

    func ensureLoaded(canvasId: String, assetIds: [String], client: APIClient?) {
        guard let client else { return }
        for id in assetIds where images[id] == nil && !inFlight.contains(id) {
            inFlight.insert(id)
            Task {
                defer { inFlight.remove(id) }
                if let data = try? await client.send(API.getDeckAsset(canvasId: canvasId, assetId: id)),
                   let nsImg = NSImage(data: data),
                   let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    rawBytes[id] = data
                    images[id] = cg
                }
            }
        }
    }

    func store(assetId: String, data: Data) {
        rawBytes[assetId] = data
        if let nsImg = NSImage(data: data),
           let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            images[assetId] = cg
        }
    }
}

// MARK: - Static Slide Renderer (Thumbnails, Review Previews & Presentation)

struct SlidePreviewCanvas: View {
    let deck: SlideDeck
    let slide: Slide
    let images: [String: CGImage]
    var hideTextOf: String? = nil
    var showOverflow: Bool = false

    var body: some View {
        let laid = SlideLayoutEngine.layoutSlide(deck: deck, slide: slide)
        Canvas { gc, size in
            guard size.width > 0, size.height > 0 else { return }
            let sx = size.width / deck.size.w
            let sy = size.height / deck.size.h
            gc.withCGContext { ctx in
                ctx.saveGState()
                ctx.scaleBy(x: sx, y: sy)
                SlideCGDrawer.draw(laid: laid, deck: deck, images: images, in: ctx, hideTextOf: hideTextOf)
                if showOverflow {
                    ctx.setStrokeColor(CGColor(red: 0.96, green: 0.62, blue: 0.36, alpha: 1))
                    ctx.setLineWidth(6)
                    ctx.setLineDash(phase: 0, lengths: [24, 14])
                    for id in laid.overflow {
                        if let el = SlideArrangeLogic.flatten(slide.elements).first(where: { $0.id == id }) {
                            ctx.stroke(el.frame.cgRect)
                        }
                    }
                }
                ctx.restoreGState()
            }
        }
        .aspectRatio(deck.size.w / max(1, deck.size.h), contentMode: .fit)
    }
}

// MARK: - Interactive Slide Canvas (Select, Multi-Select, Drag + Snap, 8-Handle Resize, Rotate, Inline Text)

struct InteractiveSlideCanvas: View {
    enum Handle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w
    }

    let deck: SlideDeck
    let slide: Slide
    let images: [String: CGImage]
    let readOnly: Bool
    @Binding var selectedIds: Set<String>
    @Binding var editingTextId: String?
    let onCommitSlide: (Slide) -> Void
    let onUploadImageForSlot: (SlideElement) -> Void

    @State private var draftSlide: Slide?
    @State private var dragStartFrames: [String: SlideFrame] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var guidesX: [Double] = []
    @State private var guidesY: [Double] = []
    @State private var inlineDraftText: String = ""
    @FocusState private var inlineFocused: Bool

    private var activeSlide: Slide { draftSlide ?? slide }

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 28
            let availW = max(100, geo.size.width - pad * 2)
            let availH = max(100, geo.size.height - pad * 2)
            let scale = min(availW / deck.size.w, availH / deck.size.h)
            let canvasW = deck.size.w * scale
            let canvasH = deck.size.h * scale
            let originX = (geo.size.width - canvasW) / 2
            let originY = (geo.size.height - canvasH) / 2

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        commitInlineEditIfNeeded()
                        selectedIds = []
                    }

                ZStack(alignment: .topLeading) {
                    SlidePreviewCanvas(
                        deck: deck,
                        slide: activeSlide,
                        images: images,
                        hideTextOf: editingTextId,
                        showOverflow: !readOnly
                    )
                    .frame(width: canvasW, height: canvasH)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)

                    // Empty image slots interactive overlay
                    if !readOnly {
                        ForEach(activeSlide.elements.filter(\.isImageSlot)) { el in
                            let f = el.frame
                            Button {
                                onUploadImageForSlot(el)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: max(14, 34 * scale)))
                                    Text("Click to add image")
                                        .font(.system(size: max(10, 22 * scale), weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .frame(width: f.w * scale, height: f.h * scale)
                                .background(Color.secondary.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                        .foregroundStyle(Color.secondary.opacity(0.45))
                                )
                            }
                            .buttonStyle(.plain)
                            .offset(x: f.x * scale, y: f.y * scale)
                        }
                    }

                    // Snap guides
                    ForEach(guidesX, id: \.self) { gx in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 1, height: canvasH)
                            .offset(x: gx * scale, y: 0)
                    }
                    ForEach(guidesY, id: \.self) { gy in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: canvasW, height: 1)
                            .offset(x: 0, y: gy * scale)
                    }

                    // Selection outlines & handles
                    if !readOnly {
                        selectionOverlay(scale: scale)
                    }

                    // Marquee box
                    if let a = marqueeStart, let b = marqueeEnd {
                        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }

                    // Inline text editor
                    if !readOnly,
                       let editId = editingTextId,
                       let el = SlideArrangeLogic.flatten(activeSlide.elements).first(where: { $0.id == editId }),
                       el.textBox != nil {
                        let tf = SlideLayoutEngine.textFrame(for: el)
                        TextEditor(text: $inlineDraftText)
                            .font(.system(size: max(11, (el.textBox?.paragraphs.first?.runs.first?.size ?? 44) * scale)))
                            .scrollContentBackground(.hidden)
                            .padding(max(2, SlideConstants.inset * scale))
                            .background(Color.black.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5))
                            .focused($inlineFocused)
                            .frame(width: max(40, tf.w * scale), height: max(28, tf.h * scale))
                            .offset(x: tf.x * scale, y: tf.y * scale)
                            .onExitCommand { commitInlineEditIfNeeded() }
                    }
                }
                .frame(width: canvasW, height: canvasH)
                .contentShape(Rectangle())
                .gesture(canvasGesture(scale: scale))
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        guard !readOnly else { return }
                        let sx = value.location.x / scale
                        let sy = value.location.y / scale
                        if let hit = hitElement(atX: sx, y: sy) {
                            if hit.isImageSlot {
                                onUploadImageForSlot(hit)
                            } else if hit.textBox != nil {
                                beginInlineEdit(hit)
                            }
                        }
                    }
                )
                .offset(x: originX, y: originY)
            }
        }
        .onChange(of: slide.id) { _, _ in
            commitInlineEditIfNeeded()
            draftSlide = nil
        }
        .onChange(of: editingTextId) { oldId, newId in
            if oldId != nil && newId == nil {
                commitInlineEdit(for: oldId!)
            } else if let newId,
                      let el = SlideArrangeLogic.flatten(activeSlide.elements).first(where: { $0.id == newId }) {
                inlineDraftText = el.plainText
                inlineFocused = true
            }
        }
    }

    @ViewBuilder
    private func selectionOverlay(scale: Double) -> some View {
        let selected = activeSlide.elements.filter { selectedIds.contains($0.id) }
        if let union = SlideArrangeLogic.unionBox(selected.map(\.frame)) {
            let x = union.l * scale
            let y = union.t * scale
            let w = max(8, (union.r - union.l) * scale)
            let h = max(8, (union.b - union.t) * scale)

            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .allowsHitTesting(false)

            if selected.count == 1, let only = selected.first, editingTextId != only.id {
                ForEach(Handle.allCases, id: \.self) { handle in
                    let pt = handlePoint(handle, rect: CGRect(x: x, y: y, width: w, height: h))
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(pt)
                        .gesture(resizeGesture(element: only, handle: handle, scale: scale))
                }
            }
        }
    }

    private func handlePoint(_ h: Handle, rect: CGRect) -> CGPoint {
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

    private func hitElement(atX x: Double, y: Double) -> SlideElement? {
        for el in activeSlide.elements.reversed() {
            let b = SlideArrangeLogic.boxOf(el.frame)
            let slop = 10.0
            if x >= b.l - slop && x <= b.r + slop && y >= b.t - slop && y <= b.b + slop {
                return el
            }
        }
        return nil
    }

    private func canvasGesture(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !readOnly else { return }
                let sx = value.startLocation.x / scale
                let sy = value.startLocation.y / scale
                if dragStartFrames.isEmpty && marqueeStart == nil {
                    commitInlineEditIfNeeded()
                    if let hit = hitElement(atX: sx, y: sy) {
                        let shift = NSEvent.modifierFlags.contains(.shift)
                        if shift {
                            if selectedIds.contains(hit.id) { selectedIds.remove(hit.id) }
                            else { selectedIds.insert(hit.id) }
                        } else if !selectedIds.contains(hit.id) {
                            selectedIds = [hit.id]
                        }
                        dragStartFrames = Dictionary(
                            uniqueKeysWithValues: activeSlide.elements
                                .filter { selectedIds.contains($0.id) }
                                .map { ($0.id, $0.frame) }
                        )
                    } else {
                        selectedIds = []
                        marqueeStart = value.startLocation
                        marqueeEnd = value.location
                        return
                    }
                }

                if marqueeStart != nil {
                    marqueeEnd = value.location
                    return
                }

                guard !dragStartFrames.isEmpty else { return }
                let rawDx = value.translation.width / scale
                let rawDy = value.translation.height / scale
                guard abs(rawDx) > 1 || abs(rawDy) > 1 else { return }

                let movingBoxes = dragStartFrames.values.map {
                    SlideFrame(x: $0.x + rawDx, y: $0.y + rawDy, w: $0.w, h: $0.h)
                }
                let others = slide.elements.filter { !selectedIds.contains($0.id) }.map(\.frame)
                var snapDx = 0.0
                var snapDy = 0.0
                if let u = SlideArrangeLogic.unionBox(movingBoxes) {
                    let snapped = SlideArrangeLogic.snapMove(box: u, slideWidth: deck.size.w, slideHeight: deck.size.h, others: others)
                    snapDx = snapped.dx
                    snapDy = snapped.dy
                    guidesX = snapped.guidesX
                    guidesY = snapped.guidesY
                }
                var updated = slide
                updated.elements = slide.elements.map { el in
                    guard let orig = dragStartFrames[el.id] else { return el }
                    let nextFrame = SlideFrame(
                        x: (orig.x + rawDx + snapDx).rounded(),
                        y: (orig.y + rawDy + snapDy).rounded(),
                        w: orig.w,
                        h: orig.h
                    )
                    return SlideArrangeLogic.withFrame(el, frame: nextFrame)
                }
                draftSlide = updated
            }
            .onEnded { _ in
                if let a = marqueeStart, let b = marqueeEnd {
                    let rect = SlideBox(
                        l: min(a.x, b.x) / scale,
                        t: min(a.y, b.y) / scale,
                        r: max(a.x, b.x) / scale,
                        b: max(a.y, b.y) / scale
                    )
                    if rect.r - rect.l > 6 || rect.b - rect.t > 6 {
                        selectedIds = Set(activeSlide.elements.compactMap { el in
                            let eb = SlideArrangeLogic.boxOf(el.frame)
                            let hits = eb.r >= rect.l && eb.l <= rect.r && eb.b >= rect.t && eb.t <= rect.b
                            return hits ? el.id : nil
                        })
                    }
                }
                if let finalSlide = draftSlide, finalSlide != slide {
                    onCommitSlide(finalSlide)
                }
                draftSlide = nil
                dragStartFrames = [:]
                marqueeStart = nil
                marqueeEnd = nil
                guidesX = []
                guidesY = []
            }
    }

    private func resizeGesture(element: SlideElement, handle: Handle, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                let orig = element.frame
                var x = orig.x, y = orig.y, w = orig.w, h = orig.h
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
                if w < 24 { w = 24 }
                if h < 24 { h = 24 }
                var updated = slide
                let nextFrame = SlideFrame(x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded())
                updated.elements = slide.elements.map { $0.id == element.id ? SlideArrangeLogic.withFrame($0, frame: nextFrame) : $0 }
                draftSlide = updated
            }
            .onEnded { _ in
                if let finalSlide = draftSlide, finalSlide != slide {
                    onCommitSlide(finalSlide)
                }
                draftSlide = nil
            }
    }

    private func beginInlineEdit(_ el: SlideElement) {
        selectedIds = [el.id]
        inlineDraftText = el.plainText
        editingTextId = el.id
        inlineFocused = true
    }

    private func commitInlineEditIfNeeded() {
        guard let id = editingTextId else { return }
        editingTextId = nil
        commitInlineEdit(for: id)
    }

    private func commitInlineEdit(for id: String) {
        guard let existing = SlideArrangeLogic.flatten(slide.elements).first(where: { $0.id == id }),
              let tb = existing.textBox else { return }
        let lines = inlineDraftText.components(separatedBy: "\n")
        let nextParas: [SlideParagraph] = lines.enumerated().map { idx, line in
            let template = tb.paragraphs[min(idx, max(0, tb.paragraphs.count - 1))]
            let run0 = template.runs.first ?? SlideRun(text: "", size: 44)
            var newRun = run0
            newRun.text = line
            var p = template
            p.runs = [newRun]
            return p
        }
        var updated = slide
        updated.elements = SlideArrangeLogic.mapDeep(slide.elements, ids: [id]) { $0.withText(nextParas) }
        if updated != slide {
            onCommitSlide(updated)
        }
    }
}
