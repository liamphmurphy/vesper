import AppKit
import Observation
import SwiftUI
import VesperCore

/// The native mockup canvas: draws the SVG with `MockupSVGRenderer` and edits it with
/// `MockupSVGEditing`, so nothing on screen waits for WebKit.
///
/// Frame rate comes from keeping per-frame work to compositing. The document is drawn once per
/// change into two bitmaps: everything except the selection, and the selection alone, cropped to
/// its bounds. Dragging moves the second bitmap; resizing scales it; the source only changes when
/// the gesture ends. Until the redrawn bitmaps for the new source arrive, the old ones stay where
/// the gesture left them, so the drop doesn't flash.
@MainActor
@Observable
final class MockupCanvasModel {
    private(set) var source = ""
    private(set) var document: MockupSVGDocument?
    private(set) var violations: [MockupSVGViolation] = []
    var selection: String? {
        didSet { if selection != oldValue { scheduleRender() } }
    }
    var hover: String?

    /// Drawn bitmaps, at `pixelsPerUnit` pixels per user unit.
    private(set) var base: CGImage?
    private(set) var layer: CGImage?
    /// Where `layer` sits, in root user space.
    private(set) var layerRect: CGRect = .zero
    private(set) var pixelsPerUnit: CGFloat = 2
    /// The source and selection the bitmaps were drawn from.
    private(set) var drawnSource = ""
    private(set) var drawnSelection: String?

    /// A gesture's preview that outlives the gesture until the redraw for its commit lands.
    var settlingOffset: CGSize = .zero
    var settlingRect: CGRect?

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var wantedPixelsPerUnit: CGFloat = 2

    /// True while the source doesn't conform: the canvas keeps showing the last version that did,
    /// so a half-typed value in the inspector or Source mode doesn't blank it.
    private(set) var isStale = false

    func update(source: String) {
        guard source != self.source else { return }
        self.source = source
        violations = MockupSVGProfile.violations(source)
        guard violations.isEmpty, let next = try? MockupSVGDocument(source: source) else {
            isStale = document != nil
            return
        }
        isStale = false
        document = next
        if let selection, next.geometry(at: selection) == nil { self.selection = nil }
        scheduleRender()
    }

    /// Whether `source` has a drawing to edit (now or from before it stopped conforming).
    var canEdit: Bool { document != nil && !isStale }

    func setPixelsPerUnit(_ value: CGFloat) {
        let clamped = max(0.25, min(value, 16))
        guard abs(clamped - wantedPixelsPerUnit) > 0.01 else { return }
        wantedPixelsPerUnit = clamped
        scheduleRender()
    }

    var viewBox: CGRect { document?.viewBox ?? CGRect(x: 0, y: 0, width: 1280, height: 800) }

    func geometry(_ path: String?) -> MockupSVGElementGeometry? {
        guard let path, let document else { return nil }
        return document.geometry(at: path)
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let document else {
            base = nil
            layer = nil
            drawnSource = source
            return
        }
        let selection = self.selection
        let source = self.source
        // Bitmaps are capped so a 200% zoom of a large mockup stays within texture limits.
        let maxSide = max(document.viewBox.width, document.viewBox.height)
        let ppu = min(wantedPixelsPerUnit, 8192 / max(maxSide, 1))
        renderTask = Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                MockupCanvasModel.draw(document, selection: selection, pixelsPerUnit: ppu)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.base = drawn.base
            self.layer = drawn.layer
            self.layerRect = drawn.layerRect
            self.pixelsPerUnit = ppu
            self.drawnSource = source
            self.drawnSelection = selection
            self.settlingOffset = .zero
            self.settlingRect = nil
        }
    }

    private struct Drawn: @unchecked Sendable {
        var base: CGImage?
        var layer: CGImage?
        var layerRect: CGRect
    }

    nonisolated private static func draw(_ document: MockupSVGDocument, selection: String?, pixelsPerUnit ppu: CGFloat) -> Drawn {
        let vb = document.viewBox
        let hidden: Set<String> = selection.map { [$0] } ?? []
        let base = bitmap(document, crop: vb, ppu: ppu, options: MockupSVGRenderOptions(hiddenPaths: hidden))
        guard let selection, let g = document.geometry(at: selection) else {
            return Drawn(base: base, layer: nil, layerRect: .zero)
        }
        // Stroke and markers reach past the geometry bounds; a margin keeps them in the layer.
        let margin = max(8, min(vb.width, vb.height) * 0.02)
        let crop = g.bounds.insetBy(dx: -margin, dy: -margin).intersection(vb.insetBy(dx: -margin, dy: -margin))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return Drawn(base: base, layer: nil, layerRect: .zero) }
        let layer = bitmap(document, crop: crop, ppu: ppu, options: MockupSVGRenderOptions(onlyPaths: [selection]))
        return Drawn(base: base, layer: layer, layerRect: crop)
    }

    /// Draws the part of the document inside `crop` (root user space) into a bitmap.
    nonisolated private static func bitmap(_ document: MockupSVGDocument, crop: CGRect, ppu: CGFloat, options: MockupSVGRenderOptions) -> CGImage? {
        let w = Int((crop.width * ppu).rounded(.up)), h = Int((crop.height * ppu).rounded(.up))
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Y-down, origin at the crop's top-left, one user unit = ppu pixels.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let vb = document.viewBox
        let target = CGRect(x: (vb.minX - crop.minX) * ppu, y: (vb.minY - crop.minY) * ppu,
                            width: vb.width * ppu, height: vb.height * ppu)
        MockupSVGRenderer.draw(document, in: ctx, rect: target, options: options)
        return ctx.makeImage()
    }
}

struct MockupCanvasView: View {
    @Bindable var model: MockupCanvasModel
    let zoom: ArtifactDetailLogic.MockupZoomMode
    /// Commits a new source; `key` coalesces repeated edits of one field in the undo history.
    let onCommit: (MockupSVGEditResult, String?) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.vesperTheme) private var theme

    private enum Gesture: Equatable {
        case none
        case move(path: String)
        case resize(path: String, handle: MockupResizeHandle, start: CGRect)
        case marquee
    }

    @State private var gesture: Gesture = .none
    @State private var dragTranslation: CGSize = .zero
    @State private var customZoom: CGFloat?
    @State private var magnification: CGFloat = 1
    @State private var editingText: String?
    @State private var editingValue = ""
    @FocusState private var canvasFocused: Bool
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let z = zoomFactor(available: geo.size)
            let map = MockupCanvasMapping(viewBox: model.viewBox, zoom: z)
            ScrollView([.horizontal, .vertical]) {
                canvas(map: map)
                    .frame(width: map.size.width, height: map.size.height)
                    .scaleEffect(magnification, anchor: .center)
                    .padding(24)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background))
            // ⌘-scroll and pinch zoom; plain scrolling stays with the scroll view.
            .onCanvasScrollWheel { action in
                guard case .zoom(let factor, _, _) = action else { return false }
                customZoom = max(0.1, min(z * factor, 8))
                return true
            }
            .onAppear { model.setPixelsPerUnit(z * displayScale) }
            .onChange(of: z) { _, next in model.setPixelsPerUnit(next * displayScale) }
            .onChange(of: displayScale) { _, next in model.setPixelsPerUnit(z * next) }
            .gesture(
                MagnifyGesture()
                    .onChanged { magnification = max(0.2, min($0.magnification, 8)) }
                    .onEnded { value in
                        // Scale the bitmap during the pinch; redraw sharp once it ends.
                        customZoom = max(0.1, min(z * value.magnification, 8))
                        magnification = 1
                    }
            )
        }
        .onChange(of: zoom) { _, _ in customZoom = nil }
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard editingText == nil, let sel = model.selection, let r = MockupSVGEditing.delete(model.source, path: sel) else { return .ignored }
            onCommit(r, nil)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard editingText == nil, let sel = model.selection, let g = model.geometry(sel) else { return .ignored }
            let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
            var v = CGSize.zero
            switch press.key {
            case .leftArrow: v.width = -step
            case .rightArrow: v.width = step
            case .upArrow: v.height = -step
            default: v.height = step
            }
            guard let r = translate(sel, rootDelta: v, geometry: g) else { return .ignored }
            onCommit(r, "nudge:\(sel)")
            return .handled
        }
        .onKeyPress(.escape) {
            if editingText != nil { editingText = nil } else { model.selection = nil }
            return .handled
        }
    }

    private func zoomFactor(available: CGSize) -> CGFloat {
        if let customZoom { return customZoom }
        switch zoom {
        case .fit:
            let vb = model.viewBox
            let availW = max(240, available.width - 48), availH = max(200, available.height - 48)
            return min(availW / max(vb.width, 1), availH / max(vb.height, 1), 1)
        case .actual: return 1
        case .double: return 2
        }
    }

    @ViewBuilder
    private func canvas(map: MockupCanvasMapping) -> some View {
        let liveOffset = movingOffset(map: map)
        ZStack(alignment: .topLeading) {
            Color.white
            if let base = model.base {
                Image(decorative: base, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: map.size.width, height: map.size.height)
            }
            if let layer = model.layer, model.drawnSelection != nil {
                let rect = layerFrame(map: map)
                Image(decorative: layer, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX + liveOffset.width, y: rect.minY + liveOffset.height)
            }
            overlays(map: map, offset: liveOffset)
            if let path = editingText, let g = model.geometry(path) {
                let r = map.rect(g.bounds)
                TextField("", text: $editingValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: max(11, r.height * 0.7)))
                    .frame(width: max(140, r.width + 24))
                    .offset(x: r.minX - 4, y: r.minY - 4)
                    .focused($textFieldFocused)
                    .onSubmit { finishTextEdit(commit: true) }
                    .onChange(of: textFieldFocused) { _, focused in if !focused { finishTextEdit(commit: true) } }
            }
        }
        .frame(width: map.size.width, height: map.size.height, alignment: .topLeading)
        .clipped()
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Rectangle())
        .gesture(dragGesture(map: map))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { beginTextEdit(at: map.user($0.location)) })
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.hover = gesture == .none ? model.document?.hitTest(map.user(p)) : nil
            case .ended: model.hover = nil
            }
        }
    }

    /// The selection layer's frame: where it was drawn, or the live resize preview.
    private func layerFrame(map: MockupCanvasMapping) -> CGRect {
        if case .resize(let path, let handle, let start) = gesture, path == model.drawnSelection {
            return previewRect(map: map, start: start, handle: handle)
        }
        if let settling = model.settlingRect { return settling }
        return map.rect(model.layerRect)
    }

    private func previewRect(map: MockupCanvasMapping, start: CGRect, handle: MockupResizeHandle) -> CGRect {
        // The layer includes a margin around the geometry; scale it with the geometry.
        let startView = map.rect(start)
        let next = handle.resized(startView, by: dragTranslation)
        let layer = map.rect(model.layerRect)
        let sx = next.width / max(startView.width, 0.01), sy = next.height / max(startView.height, 0.01)
        return CGRect(x: next.minX + (layer.minX - startView.minX) * sx,
                      y: next.minY + (layer.minY - startView.minY) * sy,
                      width: layer.width * sx, height: layer.height * sy)
    }

    private func movingOffset(map: MockupCanvasMapping) -> CGSize {
        if case .move(let path) = gesture, path == model.drawnSelection { return dragTranslation }
        return model.settlingOffset
    }

    @ViewBuilder
    private func overlays(map: MockupCanvasMapping, offset: CGSize) -> some View {
        let accent = Color.accentColor
        if let hover = model.hover, hover != model.selection, let g = model.geometry(hover) {
            let r = map.rect(g.bounds)
            Rectangle()
                .stroke(accent.opacity(0.55), lineWidth: 1)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
        if let sel = model.selection, let g = model.geometry(sel) {
            let r = selectionFrame(map: map, geometry: g, offset: offset)
            Rectangle()
                .stroke(accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                .frame(width: max(r.width, 2), height: max(r.height, 2))
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
            if isAxisAligned(g.transform) {
                ForEach(MockupResizeHandle.allCases, id: \.self) { handle in
                    let p = handle.anchor(in: r)
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(accent, lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .offset(x: p.x - 3.5, y: p.y - 3.5)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func selectionFrame(map: MockupCanvasMapping, geometry g: MockupSVGElementGeometry, offset: CGSize) -> CGRect {
        let r = map.rect(g.bounds)
        if case .resize(_, let handle, let start) = gesture {
            return handle.resized(map.rect(start), by: dragTranslation)
        }
        return r.offsetBy(dx: offset.width, dy: offset.height)
    }

    private func isAxisAligned(_ t: CGAffineTransform) -> Bool {
        abs(t.b) < 1e-9 && abs(t.c) < 1e-9
    }

    // MARK: Gestures

    private func dragGesture(map: MockupCanvasMapping) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if gesture == .none {
                    canvasFocused = true
                    if editingText != nil { finishTextEdit(commit: true) }
                    gesture = beginGesture(at: value.startLocation, map: map)
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                let ended = gesture
                gesture = .none
                defer { dragTranslation = .zero }
                let moved = hypot(value.translation.width, value.translation.height) >= 2
                guard moved else { return }
                switch ended {
                case .move(let path):
                    guard let g = model.geometry(path) else { return }
                    let root = CGSize(width: value.translation.width / map.zoom, height: value.translation.height / map.zoom)
                    if let r = translate(path, rootDelta: root, geometry: g) {
                        model.settlingOffset = value.translation
                        onCommit(r, nil)
                    }
                case .resize(let path, let handle, let start):
                    guard let g = model.geometry(path) else { return }
                    let rootDelta = CGSize(width: value.translation.width / map.zoom, height: value.translation.height / map.zoom)
                    let next = handle.resized(start, by: rootDelta)
                    let inverse = g.transform.inverted()
                    let local = next.applying(inverse)
                    if let r = MockupSVGEditing.resize(model.source, path: path, from: g.localBounds, to: local) {
                        model.settlingRect = previewRect(map: map, start: start, handle: handle)
                        onCommit(r, nil)
                    }
                case .marquee, .none:
                    break
                }
            }
    }

    private func beginGesture(at location: CGPoint, map: MockupCanvasMapping) -> Gesture {
        if let sel = model.selection, let g = model.geometry(sel), isAxisAligned(g.transform) {
            let r = map.rect(g.bounds)
            for handle in MockupResizeHandle.allCases where hypot(handle.anchor(in: r).x - location.x, handle.anchor(in: r).y - location.y) <= 6 {
                return .resize(path: sel, handle: handle, start: g.bounds)
            }
        }
        let hit = model.document?.hitTest(map.user(location))
        model.selection = hit
        guard let hit else { return .marquee }
        return .move(path: hit)
    }

    /// Moves `path` by `rootDelta` (root user units). `translate` acts in the parent's user space,
    /// so the delta goes through the inverse of the parent's linear transform.
    private func translate(_ path: String, rootDelta v: CGSize, geometry g: MockupSVGElementGeometry) -> MockupSVGEditResult? {
        var linear = g.parentTransform
        linear.tx = 0
        linear.ty = 0
        let d = CGPoint(x: v.width, y: v.height).applying(linear.inverted())
        return MockupSVGEditing.translate(model.source, path: path, dx: Double(d.x), dy: Double(d.y))
    }

    // MARK: Inline text

    private func beginTextEdit(at point: CGPoint) {
        guard let hit = model.document?.hitTest(point) else { return }
        // A hit on a <tspan> edits its <text>, as the inspector does.
        var path = hit
        while let node = model.document?.tree.node(at: path), node.localName == "tspan", let parent = MockupSVGTree.parentPath(of: path) {
            path = parent
        }
        guard let node = model.document?.tree.node(at: path), node.localName == "text" else { return }
        model.selection = path
        editingValue = node.textContent
        editingText = path
        textFieldFocused = true
    }

    private func finishTextEdit(commit: Bool) {
        guard let path = editingText else { return }
        editingText = nil
        if commit, let r = MockupSVGEditing.setText(model.source, path: path, text: editingValue) {
            onCommit(r, "text:\(path)")
        }
    }
}

/// Edits the selected element's main attributes. Every keystroke redraws natively, so there's
/// no Apply button; edits to one field coalesce into one undo step.
struct MockupInspectorView: View {
    @Bindable var model: MockupCanvasModel
    let onCommit: (MockupSVGEditResult, String?) -> Void
    @Environment(\.vesperTheme) private var theme

    private static let geometryAttributes: [String: [String]] = [
        "rect": ["x", "y", "width", "height", "rx"],
        "ellipse": ["cx", "cy", "rx", "ry"],
        "circle": ["cx", "cy", "r"],
        "line": ["x1", "y1", "x2", "y2"],
        "text": ["x", "y", "font-size", "font-family", "font-weight", "text-anchor"],
        "image": ["x", "y", "width", "height"],
        "use": ["x", "y", "width", "height"],
    ]
    private static let paintAttributes = ["fill", "stroke", "stroke-width", "opacity"]

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let sel = model.selection, let node = model.document?.tree.node(at: sel), !sel.isEmpty {
                    Text("<\(node.localName)>")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(p.tertiaryText)
                    if node.localName == "text" {
                        field(label: "text", value: textOf(node)) { v in
                            MockupSVGEditing.setText(model.source, path: sel, text: v).map { onCommit($0, "text:\(sel)") }
                        }
                    }
                    ForEach((Self.geometryAttributes[node.localName] ?? []) + Self.paintAttributes, id: \.self) { name in
                        field(label: name, value: node.attribute(name) ?? "") { v in
                            MockupSVGEditing.setAttribute(model.source, path: sel, name: name, value: v.isEmpty ? nil : v)
                                .map { onCommit($0, "attr:\(sel):\(name)") }
                        }
                    }
                    if let problem = model.violations.first(where: { $0.path == sel }) {
                        Text(problem.message)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                    }
                } else {
                    Text("Select an element on the canvas to edit its properties.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(10)
        }
        .frame(width: 220)
        .background(p.surface)
    }

    private func textOf(_ node: MockupSVGNode) -> String {
        (node.elementChildren.first { $0.localName == "tspan" } ?? node).textContent
    }

    private func field(label: String, value: String, onChange: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.tertiaryText)
                .frame(width: 70, alignment: .leading)
            MockupInspectorField(value: value, onChange: onChange)
        }
    }
}

/// A text field that shows the document's value but keeps what the person typed while they type,
/// even when the value they typed doesn't conform yet (the source still records it).
private struct MockupInspectorField: View {
    let value: String
    let onChange: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, next in if !focused { text = next } }
            .onChange(of: text) { _, next in if focused, next != value { onChange(next) } }
    }
}
