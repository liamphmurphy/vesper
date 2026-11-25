import Foundation

/// svg-image, svg-steps and mermaid drawn by the native mockup renderer (`MockupSVGDocument`), the
/// same code that draws and edits mockups. A frame is themed, has its other steps hidden, and is
/// compiled once; the compiled document is cached per message, theme, source and frame.
public enum ChatSVGNative {
    /// Compiled frames: a document holds resolved paths and text layout, so a few hundred is plenty.
    public static let documents = EmbedLRUCache<EmbedCacheKey, ChatSVGFrame>(countLimit: 200)

    /// Frame `step` (from 1) of a step-through: elements outside it get `display="none"`, which the
    /// renderer honours like the CSS the web injects (`ChatSVG.stepFrame`). nil `step` is the whole
    /// image. A source that doesn't parse comes back as is, for the compile step to report.
    public static func stepFrame(_ source: String, step: Int) -> String {
        let hidden = Set(ChatSVG.stepValues(source).filter { step < $0.from || ($0.to.map { step > $0 } ?? false) }.map(\.value))
        guard !hidden.isEmpty, var tree = try? MockupSVGTree.parse(source) else { return source }
        func hide(_ node: inout MockupSVGNode) {
            guard node.isElement else { return }
            if let value = node.attribute("data-step")?.trimmingCharacters(in: .whitespacesAndNewlines), hidden.contains(value) {
                node.setAttribute("display", "none")
                // Nothing inside a hidden element draws, so there's no need to look further.
                return
            }
            for i in node.children.indices { hide(&node.children[i]) }
        }
        hide(&tree.root)
        return tree.serialized()
    }

    /// The source a frame compiles from: namespaced, themed when it uses the palette, then stepped.
    public static func frameSource(_ svg: String, palette: VizPalette, themed: Bool, step: Int?) -> String {
        let doc = ChatSVG.document(themed ? ChatSVG.theme(svg, palette: palette) : svg)
        return step.map { stepFrame(doc, step: $0) } ?? doc
    }

    /// The compiled frame for `source`, or nil when it can't be drawn natively. Agent SVGs that use
    /// CSS or features outside mockup profile v1 are simplified first; what that dropped is kept so
    /// the view can say the picture is simplified.
    public static func compile(_ source: String) -> ChatSVGFrame? {
        if let document = try? MockupSVGDocument(source: source) {
            return ChatSVGFrame(document: document, dropped: [])
        }
        guard let simplified = MockupSVGDocument.simplified(source) else { return nil }
        return ChatSVGFrame(document: simplified.document, dropped: simplified.dropped)
    }

    /// The cached frame for `key`, compiling `source` on a miss.
    public static func frame(_ key: EmbedCacheKey, source: @autoclosure () -> String) -> ChatSVGFrame? {
        if let hit = documents.value(for: key) { return hit }
        guard let frame = compile(source()) else { return nil }
        documents.insert(frame, for: key)
        return frame
    }
}

/// One drawable frame of a chat SVG.
public struct ChatSVGFrame: Sendable {
    public let document: MockupSVGDocument
    /// What simplification removed to make the source drawable (empty when it conformed as written).
    public let dropped: [String]

    public init(document: MockupSVGDocument, dropped: [String]) {
        self.document = document
        self.dropped = dropped
    }
}
