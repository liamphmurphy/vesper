import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// Everything in a native chat message that isn't markdown text or a card: display math, ```mermaid,
/// ```svg-image, ```svg-steps and ```app fences. The transcript hands each such block here.
///
/// - `kind`/`source`: what `EmbeddedBlockKind.classify(info:)` said and the fence's text (for math,
///   the TeX without its `$$`).
/// - `messageID`: the assistant reply the block is in. It keys the render cache, and diagrams offer
///   Save to Library only when it's set (POST /library/diagrams needs it).
/// - `info`: the fence's info string, for the Code view.
/// - `index`: the block's position in the message, so two identical apps in one reply are two blocks.
///
/// Needs `NativeScreenContext` and `vesperTheme` in the environment, like `MarkdownView`.
struct EmbeddedBlockView: View {
    let kind: EmbeddedBlockKind
    let source: String
    var messageID: String?
    var info: String?
    var index = 0

    /// The block for a fence, or nil when the fence stays a code block.
    init?(fence info: String?, code: String, messageID: String? = nil, index: Int = 0) {
        guard let kind = EmbeddedBlockKind.classify(info: info) else { return nil }
        self.init(kind: kind, source: code, messageID: messageID, info: info, index: index)
    }

    init(kind: EmbeddedBlockKind, source: String, messageID: String? = nil, info: String? = nil, index: Int = 0) {
        self.kind = kind
        self.source = source
        self.messageID = messageID
        self.info = info
        self.index = index
    }

    var body: some View {
        switch kind {
        case .math: MathBlockView(tex: source, messageID: messageID ?? "")
        case .mermaid, .svgImage, .svgSteps: DiagramEmbedView(kind: kind, source: source, messageID: messageID, info: info)
        case .app: AppEmbedView(source: source, messageID: messageID ?? "", index: index, info: info)
        case .mockup: MockupCardView(source: source)
        }
    }
}

// MARK: - Frame

/// The chrome every visual shares (visual-frame.tsx `VisualFrame`): a sunken rounded box with a header
/// naming it, its views and its actions.
struct EmbedFrame<Actions: View, Content: View>: View {
    let icon: String
    let label: String
    var views: [String] = []
    @Binding var view: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    @Environment(\.vesperTheme) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(label, systemImage: icon)
                    .labelStyle(EmbedHeaderLabelStyle())
                Spacer(minLength: 8)
                if !views.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(views, id: \.self) { v in
                            Button(v) { view = v }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 6)
                                .foregroundStyle(view == v ? p.text : p.tertiaryText)
                                .background(view == v ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .accessibilityAddTraits(view == v ? .isSelected : [])
                        }
                    }
                }
                actions()
            }
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(p.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(p.rowBorder).frame(height: 1) }
            content()
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }
}

private struct EmbedHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A fence shown as its source: the chat's code block (header, Copy, Shiki), flush inside the frame.
struct EmbedSourceView: View {
    let code: String
    let language: String

    var body: some View {
        MarkdownView(markdown: Self.fence(code, language: language), textStyle: .chat, chat: true)
            .padding(8)
    }

    /// A fence that can't be closed early by the code: one more backtick than its longest run.
    static func fence(_ code: String, language: String) -> String {
        var longest = 0, run = 0
        for c in code {
            run = c == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return "\(ticks)\(language)\n\(code)\n\(ticks)"
    }
}

// MARK: - Diagrams

/// mermaid, svg-image and svg-steps (svg-fence.tsx `DiagramVisual`, mermaid-fence.tsx). Every frame
/// is compiled by the native mockup renderer (`ChatSVGNative`; mermaid is first laid out into an SVG
/// by `NativeMermaid`) and drawn as vectors at whatever size it's shown, cached per message, theme,
/// source and frame.
struct DiagramEmbedView: View {
    let kind: EmbeddedBlockKind
    let source: String
    let messageID: String?
    let info: String?

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var view = "Image"
    @State private var step = 0
    @State private var save = SaveState.idle
    @State private var showLightbox = false

    enum SaveState: Equatable {
        case idle, saving, saved(String), failed(String)
    }

    /// The SVG and captions the fence holds (mermaid has neither until it's drawn).
    private var parsed: (svg: String, captions: [String]) {
        kind == .svgSteps ? ChatSVG.parseStepsFence(source) : (source, [])
    }

    var body: some View {
        let palette = VizPalette(theme: theme)
        let (svg, captions) = parsed
        let themed = kind == .mermaid || ChatSVG.isThemed(svg)
        let count = kind == .mermaid ? 1 : ChatSVG.stepCount(svg, captions: captions)
        let stepped = count > 1
        let at = min(step, max(count - 1, 0))
        let key = renderKey(at, palette: palette, themed: themed, stepped: stepped)
        let native = nativeFrame(key, svg: svg, palette: palette, themed: themed, step: stepped ? at + 1 : nil)
        let didFail = native == nil
        let showCode = view == "Code" || (didFail && kind == .mermaid)
        let label = kind == .mermaid ? "Diagram" : stepped ? "Step-through" : "SVG image"
        let name = ChatSVG.title(svg) ?? label

        EmbedFrame(
            icon: kind == .mermaid ? "point.3.connected.trianglepath.dotted" : "photo.on.rectangle",
            label: label,
            views: didFail ? [] : ["Image", "Code"],
            view: $view
        ) {
            if !didFail, view == "Image" {
                if let portable = portableSVG(native, palette: palette, svg: svg, count: count) {
                    actions(portable)
                }
                if native != nil {
                    Button {
                        showLightbox = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Expand to lightbox")
                    .accessibilityLabel("Expand \(label) to lightbox")
                }
            }
        } content: {
            if showCode {
                if didFail && kind != .mermaid {
                    failureLine(name)
                }
                EmbedSourceView(code: source, language: kind == .mermaid ? "mermaid" : "html")
            } else if didFail {
                failureLine(name)
                EmbedSourceView(code: source, language: "html")
            } else {
                stage(native, key: key, themed: themed, palette: palette, alt: stepped ? "\(name). Step \(at + 1) of \(count)" : name)
                if stepped { stepNav(at: at, count: count, captions: captions) }
            }
        }
        .task(id: key) {
            if stepped, at + 1 < count {
                // The next frame too, so stepping forward doesn't wait.
                _ = nativeFrame(renderKey(at + 1, palette: palette, themed: themed, stepped: stepped), svg: svg, palette: palette, themed: themed, step: at + 2)
            }
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: name, subtitle: stepped ? "Step \(at + 1) of \(count)" : label) {
                VStack(spacing: 12) {
                    stage(native, key: key, themed: themed, palette: palette, alt: stepped ? "\(name). Step \(at + 1) of \(count)" : name)
                    if stepped { stepNav(at: at, count: count, captions: captions) }
                }
            }
        }
    }

    private func renderKey(_ frame: Int, palette: VizPalette, themed: Bool, stepped: Bool) -> EmbedCacheKey {
        // An SVG that doesn't use the palette draws the same in every theme: one entry serves all.
        EmbedCacheKey(kind: kind, messageID: messageID ?? "", theme: themed ? palette.fingerprint : "plain", source: source, variant: stepped ? String(frame + 1) : "")
    }

    /// A frame compiled natively (cached), or nil when it can't be drawn: an SVG even simplifying
    /// can't make drawable, or mermaid `NativeMermaid` can't lay out (a type it doesn't draw, a
    /// syntax error, too large), which shows the code instead.
    private func nativeFrame(_ key: EmbedCacheKey, svg: String, palette: VizPalette, themed: Bool, step: Int?) -> ChatSVGFrame? {
        if kind == .mermaid {
            if let hit = ChatSVGNative.documents.value(for: key) { return hit }
            guard let laidOut = try? NativeMermaid.svg(source, palette: palette) else { return nil }
            return ChatSVGNative.frame(key, source: laidOut)
        }
        return ChatSVGNative.frame(key, source: ChatSVGNative.frameSource(svg, palette: palette, themed: themed, step: step))
    }

    @ViewBuilder
    private func stage(_ native: ChatSVGFrame?, key: EmbedCacheKey, themed: Bool, palette: VizPalette, alt: String) -> some View {
        let background = themed ? (Color(hex: palette.surface) ?? .white) : .white
        Group {
            if let native {
                let image = EmbedImages.image(native, key: key, background: themed ? palette.surface : "#FFFFFF")
                EmbedImageView(image: image, size: native.document.intrinsicSize, maxHeight: kind == .mermaid ? 480 : 720, alt: alt)
                    .frame(maxWidth: .infinity, alignment: kind == .mermaid ? .leading : .center)
                    .help(native.dropped.isEmpty ? "" : "Simplified to draw natively: left out \(native.dropped.joined(separator: ", "))")
            }
        }
        .padding(8)
        .background(background)
    }

    private func stepNav(at: Int, count: Int, captions: [String]) -> some View {
        let p = theme.palette
        return HStack(spacing: 8) {
            Button("←") { step = at - 1 }
                .buttonStyle(.vesper())
                .disabled(at == 0)
                .accessibilityLabel("Previous step")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(at + 1)/\(count)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                Text(at < captions.count ? captions[at] : "")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.swiftUIColor("text-2", fallback: p.text))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("→") { step = at + 1 }
                .buttonStyle(.vesper())
                .disabled(at >= count - 1)
                .accessibilityLabel("Next step")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(p.rowBorder).frame(height: 1) }
    }

    private func failureLine(_ name: String) -> some View {
        Text(kind == .mermaid ? "This diagram couldn\u{2019}t be drawn. Its source is below." : "This SVG couldn\u{2019}t be displayed. Its source is below.")
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .accessibilityLabel("\(name) couldn\u{2019}t be displayed")
    }

    /// The self-contained SVG Save to Library and Download hand on (`exportSvg` of the last frame, or
    /// the laid-out mermaid diagram).
    private func portableSVG(_ native: ChatSVGFrame?, palette: VizPalette, svg: String, count: Int) -> String? {
        if kind == .mermaid { return native?.document.tree.serialized() }
        return ChatSVG.export(count > 1 ? ChatSVG.stepFrame(svg, step: count) : svg, palette: palette)
    }

    @ViewBuilder
    private func actions(_ portable: String) -> some View {
        let p = theme.palette
        if let messageID, !messageID.isEmpty {
            if case .failed(let message) = save {
                Text(message).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red)).lineLimit(1)
            }
            let saved = save == .saved(portable)
            Button {
                saveToLibrary(messageID: messageID, svg: portable)
            } label: {
                Label(saved ? "Saved" : save == .saving ? "Saving\u{2026}" : "Save to Library", systemImage: saved ? "checkmark" : "bookmark")
                    .labelStyle(EmbedHeaderLabelStyle())
            }
            .buttonStyle(.plain)
            .disabled(save == .saving || saved)
            .foregroundStyle(p.tertiaryText)
        }
        Button {
            download(portable)
        } label: {
            Image(systemName: "arrow.down.to.line").imageScale(.small)
        }
        .buttonStyle(.plain)
        .help("Download")
        .accessibilityLabel("Download SVG")
    }

    /// svg-fence.tsx `SaveToLibrary`: the same request (`POST /library/diagrams`); saving again returns
    /// the existing item.
    private func saveToLibrary(messageID: String, svg: String) {
        save = .saving
        Task {
            do {
                _ = try await context.store.mutate(
                    API.saveLibraryDiagram(body: API.LibraryDiagramSave(messageId: messageID, svg: svg)),
                    invalidating: QueryInvalidation(resources: ["library"])
                )
                save = .saved(svg)
            } catch {
                save = .failed((error as? APIError)?.userMessage ?? "Couldn\u{2019}t save.")
            }
        }
    }

    /// The web's download link: the portable SVG, saved where the person picks.
    private func download(_ svg: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.svg"
        panel.allowedContentTypes = [.svg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(svg.utf8).write(to: url, options: .atomic)
        } catch {
            context.showToast(ToastItemModel(id: "embeds.download", title: "Couldn\u{2019}t save the SVG", description: error.localizedDescription, tone: .error))
        }
    }
}

// MARK: - Math

/// Display math (`$$ … $$` on its own lines, or a ```math fence): centred, in the text's colour and
/// size, drawn natively through `MathRendering` (cached). TeX that doesn't parse shows as its source.
struct MathBlockView: View {
    let tex: String
    let messageID: String
    var textStyle: ThemeTokens.TextStyle = .chat
    var textColor = "text"

    @Environment(\.vesperTheme) private var theme
    @State private var rendered: RenderedEmbed?
    @State private var drawnFor: MathRenderRequest?

    var body: some View {
        let request = Self.request(tex: tex, display: true, theme: theme, textStyle: textStyle, textColor: textColor)
        let key = request.cacheKey(messageID: messageID)
        Group {
            if drawnFor == request, let rendered, let image = EmbedImages.image(rendered, key: key) {
                // Wider than the column, it shrinks to fit rather than overflowing.
                EmbedImageView(image: image, size: CGSize(width: rendered.width, height: rendered.height), alt: tex)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text(tex)
                    .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                    .foregroundStyle(theme.swiftUIColor(textColor, fallback: theme.palette.text))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .task(id: key) {
            rendered = MathRendering.render(request, messageID: messageID)
            drawnFor = request
        }
    }

    /// What a piece of math in this theme and text style draws with.
    static func request(tex: String, display: Bool, theme: ThemeTokens, textStyle: ThemeTokens.TextStyle, textColor: String) -> MathRenderRequest {
        let fallback = theme.mode == .dark ? VizPalette.dark.ink : VizPalette.light.ink
        let color = theme.colors[textColor].flatMap { RGBA(hex: $0) != nil ? $0 : nil } ?? fallback
        return MathRenderRequest(tex: tex, display: display, color: color, fontSize: theme.pointSize(textStyle))
    }
}

extension Color {
    /// "#RRGGBB(AA)" as a colour, nil for anything else.
    init?(hex: String) {
        guard let c = RGBA(hex: hex) else { return nil }
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
