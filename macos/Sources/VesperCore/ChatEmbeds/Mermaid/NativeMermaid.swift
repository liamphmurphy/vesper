import CoreGraphics
import Foundation

/// Why a mermaid fence can't be drawn natively. The chat shows the fence's code for every case.
public enum NativeMermaidError: Error, Equatable, Sendable {
    /// A diagram type the native renderer doesn't draw (journey, mindmap, gitGraph, …), named by the
    /// fence's first word. Also used when the bundled graph layout can't run, since the chat's
    /// fallback (show the code) is the same.
    case unsupportedDiagram(String)
    /// The source doesn't parse. `line` is 1-based in the fence as written, front matter included.
    case syntax(line: Int, message: String)
    /// Longer than `NativeMermaid.maxSource`, or more nodes, edges or rows than a chat
    /// diagram can sensibly lay out.
    case tooLarge
}

/// Mermaid diagrams drawn without WebKit: the fence is parsed here, laid out (elkjs in
/// JavaScriptCore for graph-shaped diagrams, simple deterministic layouts for the rest) and written
/// as an SVG in mockup SVG profile v1 (docs/dev/mockup-svg-profile.md), so `MockupSVGRenderer`
/// draws it and Save to Library keeps the same picture.
///
/// Text is measured with the same CoreText fonts the renderer resolves for the SVG's
/// `font-family`, so boxes fit their labels. The output is deterministic: the same source and
/// palette give byte-identical SVG.
public enum NativeMermaid {
    /// Graph-shaped diagrams with more nodes than this would be unreadable in a chat bubble and slow
    /// to lay out.
    static let maxNodes = 400
    static let maxEdges = 800
    /// Sequence messages, gantt tasks, pie slices.
    static let maxRows = 600
    /// A longer fence stays code: the web's limit, kept so the same fence behaves the same everywhere.
    public static let maxSource = 20_000

    /// The diagram as an SVG string sized to its content.
    public static func svg(_ source: String, palette: VizPalette) throws(NativeMermaidError) -> String {
        try render(source, palette: palette).svg
    }

    /// The SVG and what was drawn, for tests.
    static func render(_ source: String, palette: VizPalette) throws(NativeMermaidError) -> MermaidDrawing {
        guard source.count <= maxSource else { throw .tooLarge }
        let doc = try MermaidSource(source)
        let theme = MermaidTheme(palette)
        switch doc.keyword {
        case "flowchart", "graph", "flowchart-elk":
            return try MermaidFlowchart.parse(doc).draw(theme, title: doc.title)
        case "sequenceDiagram":
            return try MermaidSequence.parse(doc).draw(theme)
        case "pie":
            return try MermaidPie.parse(doc).draw(theme)
        case "gantt":
            return try MermaidGantt.parse(doc).draw(theme)
        case "stateDiagram", "stateDiagram-v2":
            return try MermaidState.parse(doc).draw(theme, title: doc.title)
        default:
            throw .unsupportedDiagram(doc.keyword)
        }
    }
}

/// A rendered diagram: the SVG plus the frames of its nodes and the text it drew, which tests use
/// to check that boxes don't overlap and every label made it in.
struct MermaidDrawing {
    var svg: String
    var nodeFrames: [CGRect] = []
    var texts: [String] = []
}

/// One statement line of a fence with its 1-based line number in the original source.
struct MermaidLine {
    let number: Int
    let text: String
}

/// A fence split into its diagram keyword, header remainder and statement lines, with front matter
/// (`---\ntitle: …\n---`), `%%{init}%%` directives and `%%` comments removed.
struct MermaidSource {
    let keyword: String
    /// The header line after the keyword (`TD` in `flowchart TD`, `showData` in `pie showData`).
    let headerRest: String
    let headerLine: Int
    let lines: [MermaidLine]
    let title: String?

    init(_ source: String) throws(NativeMermaidError) {
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        var title: String?
        // Front matter: only when it opens the fence.
        while i < raw.count, raw[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        if i < raw.count, raw[i].trimmingCharacters(in: .whitespaces) == "---" {
            let open = i
            i += 1
            var closed = false
            while i < raw.count {
                let t = raw[i].trimmingCharacters(in: .whitespaces)
                i += 1
                if t == "---" { closed = true; break }
                // Only the top-level title matters; config is mermaid's and ignored.
                if raw[i - 1].hasPrefix("title:") {
                    title = MermaidText.unquote(String(t.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces))
                }
            }
            if !closed { throw .syntax(line: open + 1, message: "front matter isn't closed with ---") }
        }
        var lines: [MermaidLine] = []
        var inDirective = false
        for n in i..<raw.count {
            let t = raw[n].trimmingCharacters(in: .whitespaces)
            if inDirective {
                if t.contains("}%%") { inDirective = false }
                continue
            }
            if t.hasPrefix("%%{") {
                if !t.contains("}%%") { inDirective = true }
                continue
            }
            if t.isEmpty || t.hasPrefix("%%") { continue }
            lines.append(MermaidLine(number: n + 1, text: t))
        }
        guard let first = lines.first else { throw .syntax(line: max(1, raw.count), message: "the diagram is empty") }
        let head = first.text
        let end = head.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == ";" }) ?? head.endIndex
        keyword = String(head[..<end])
        headerRest = String(head[end...]).trimmingCharacters(in: .whitespaces)
        headerLine = first.number
        self.lines = Array(lines.dropFirst())
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The palette mapped the way the web themed mermaid.js (its "base" theme's variables), so native
/// diagrams keep the colours chat diagrams have always had.
struct MermaidTheme {
    let background: String
    let nodeFill: String
    let nodeStroke: String
    let text: String
    let muted: String
    let line: String
    let grid: String
    let clusterFill: String
    let clusterStroke: String
    let edgeLabelBackground: String
    let noteFill: String
    let noteStroke: String
    let series: [String]
    let isDark: Bool

    init(_ p: VizPalette) {
        let fallback = p.isDark ? VizPalette.dark.series : VizPalette.light.series
        series = p.series.count >= 8 ? p.series : p.series + fallback.dropFirst(p.series.count)
        background = p.surface
        nodeFill = p.panel
        nodeStroke = series[0]
        text = p.ink
        muted = p.muted
        line = p.line
        grid = p.grid
        clusterFill = p.surface
        clusterStroke = p.line
        edgeLabelBackground = p.surface
        noteFill = p.panel
        noteStroke = p.line
        isDark = p.isDark
    }

    func series(_ i: Int) -> String { series[((i % series.count) + series.count) % series.count] }
}
