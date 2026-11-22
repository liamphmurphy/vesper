import Foundation

/// The colours every chat visual shares (lib/chat-svg.ts `VizPalette`): agent-written SVGs name them
/// as `var(--viz-*)`, swapped for real colours before drawing because an image can't see the page's
/// CSS; Mermaid is themed with them. Read from the page's `--viz-*` tokens like `useVizPalette`.
public struct VizPalette: Sendable, Equatable, Hashable {
    public var surface: String
    public var panel: String
    public var ink: String
    public var muted: String
    public var line: String
    public var grid: String
    /// `--viz-1` … `--viz-8`.
    public var series: [String]

    public init(surface: String, panel: String, ink: String, muted: String, line: String, grid: String, series: [String]) {
        self.surface = surface
        self.panel = panel
        self.ink = ink
        self.muted = muted
        self.line = line
        self.grid = grid
        self.series = series
    }

    /// lib/chat-svg.ts `VIZ_LIGHT`.
    public static let light = VizPalette(
        surface: "#FFFFFF", panel: "#F3F1F8", ink: "#17151F", muted: "#55526A", line: "#B9B6C6", grid: "#ECE9F3",
        series: ["#2A78D6", "#EB6834", "#1BAF7A", "#EDA100", "#E87BA4", "#008300", "#6250D6", "#E34948"]
    )

    /// lib/chat-svg.ts `VIZ_DARK`.
    public static let dark = VizPalette(
        surface: "#15141F", panel: "#1F1D2C", ink: "#EEEDF3", muted: "#A4A1B3", line: "#4A4658", grid: "#26242F",
        series: ["#3987E5", "#D95926", "#199E70", "#C98500", "#D55181", "#008300", "#9085E9", "#E66767"]
    )

    /// The page's palette from its tokens, falling back per colour to the mode's defaults.
    public init(theme: ThemeTokens) {
        let fallback = theme.mode == .dark ? VizPalette.dark : VizPalette.light
        let pick = { (name: String, value: String) in theme.colors["viz-\(name)"].flatMap { RGBA(hex: $0) != nil ? $0 : nil } ?? value }
        self.init(
            surface: pick("surface", fallback.surface), panel: pick("panel", fallback.panel), ink: pick("ink", fallback.ink),
            muted: pick("muted", fallback.muted), line: pick("line", fallback.line), grid: pick("grid", fallback.grid),
            series: fallback.series.enumerated().map { pick(String($0.offset + 1), $0.element) }
        )
    }

    /// A stable string naming these colours, for cache keys.
    public var fingerprint: String {
        ([surface, panel, ink, muted, line, grid] + series).map { $0.lowercased() }.joined(separator: ",")
    }

    /// Whether the surface is dark (mermaid-fence.tsx's `darkMode`: white reads better on it than black).
    public var isDark: Bool { Self.contrast(surface, "#ffffff") > Self.contrast(surface, "#000000") }

    /// lib/palettes.ts `contrast` (WCAG relative luminance ratio).
    public static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func luminance(_ hex: String) -> Double {
        guard let c = RGBA(hex: String(hex.prefix(7))) else { return 0 }
        let lin = { (n: Double) in n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
        return lin(c.red) * 0.2126 + lin(c.green) * 0.7152 + lin(c.blue) * 0.0722
    }
}

/// Ports of lib/chat-svg.ts: svg-image and svg-steps fences, themed and split into frames. Keep the
/// two in step.
public enum ChatSVG {
    public static let namespace = "http://www.w3.org/2000/svg"
    /// lib/chat-svg.ts `MAX_STEPS`.
    public static let maxSteps = 12

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // The patterns are literals below; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let missingNamespace = regex("<svg\\b(?![^>]*\\sxmlns\\s*=)")
    private static let titlePattern = regex("<title[^>]*>([^<]+)</title>")
    private static let vizToken = regex("var\\(\\s*--viz-([a-z0-9-]+)\\s*\\)")
    private static let themedPattern = regex("var\\(\\s*--viz-")
    private static let rootOpen = regex("<svg\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>")
    private static let stepAttr = regex("\\bdata-step\\s*=\\s*[\"']([^\"']*)[\"']")
    private static let stepValue = regex("^(\\d+)(?:-(\\d+))?$", [])
    private static let captionNumber = regex("^\\d+[.)]\\s*", [])
    private static let seriesSlot = regex("^([1-8])(-soft)?$", [])

    /// The document to draw: an image needs the namespace to parse at all, so a root element without
    /// one gets it (`svgDocument`).
    public static func document(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard let m = missingNamespace.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return trimmed }
        return ns.replacingCharacters(in: m.range, with: "<svg xmlns=\"\(namespace)\"")
    }

    /// The `data:` URL an image shows the source through (`svgDataUrl`). Images render SVG with scripts
    /// off and no external loads, so the agent's markup can't run or reach the network.
    public static func dataURL(_ source: String) -> String {
        "data:image/svg+xml;charset=utf-8," + encodeURIComponent(document(source))
    }

    /// JavaScript's `encodeURIComponent`: everything but `A–Z a–z 0–9 - _ . ! ~ * ' ( )` is escaped.
    public static func encodeURIComponent(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// What an SVG's `<title>` says, for its alt text.
    public static func title(_ source: String) -> String? {
        let ns = source as NSString
        guard let m = titlePattern.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Whether a source draws with the shared palette; one that doesn't keeps its white background.
    public static func isThemed(_ source: String) -> Bool {
        themedPattern.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) != nil
    }

    /// `var(--viz-NAME)` swapped for the palette's colour; unknown names stay as written.
    public static func theme(_ source: String, palette: VizPalette) -> String {
        let ns = source as NSString
        var out = ""
        var at = 0
        for m in vizToken.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            out += vizColor(palette, name) ?? ns.substring(with: m.range)
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    static func vizColor(_ p: VizPalette, _ name: String) -> String? {
        let ns = name as NSString
        if let m = seriesSlot.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) {
            let slot = Int(ns.substring(with: m.range(at: 1)))! - 1
            return p.series[slot] + (m.range(at: 2).location != NSNotFound ? "26" : "")
        }
        switch name {
        case "surface": return p.surface
        case "panel": return p.panel
        case "ink": return p.ink
        case "muted": return p.muted
        case "line": return p.line
        default: return nil
        }
    }

    /// The document with `<style>css</style>` as the root's first child (`withStyle`).
    static func withStyle(_ doc: String, css: String) -> String {
        let ns = doc as NSString
        guard let root = rootOpen.firstMatch(in: doc, range: NSRange(location: 0, length: ns.length)),
              !ns.substring(with: root.range).hasSuffix("/>") else { return doc }
        let at = root.range.location + root.range.length
        return ns.substring(to: at) + "<style>\(css)</style>" + ns.substring(from: at)
    }

    /// A self-contained copy for downloads and the Library, readable wherever it ends up (`exportSvg`).
    public static func export(_ source: String, palette: VizPalette = .light) -> String {
        guard isThemed(source) else { return document(source) }
        return withStyle(document(theme(source, palette: palette)), css: ":root{background:\(palette.surface)}")
    }

    // MARK: Step-throughs

    /// A step-through fence: the SVG, then one numbered caption per step (`parseStepsFence`).
    public static func parseStepsFence(_ code: String) -> (svg: String, captions: [String]) {
        guard let end = code.range(of: "</svg>", options: [.caseInsensitive, .backwards]) else { return (code, []) }
        let svg = String(code[..<end.upperBound])
        let captions = code[end.upperBound...].components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = trimmed as NSString
            let caption = captionNumber.stringByReplacingMatches(in: trimmed, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            return caption.isEmpty ? nil : caption
        }
        return (svg, captions)
    }

    struct StepValue: Equatable {
        var value: String
        var from: Int
        /// nil: to the end.
        var to: Int?
    }

    /// The distinct `data-step` values, in order of first use, that parse as "N" or "N-M".
    static func stepValues(_ source: String) -> [StepValue] {
        let ns = source as NSString
        var seen = Set<String>()
        var out: [StepValue] = []
        for m in stepAttr.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(value).inserted else { continue }
            let vs = value as NSString
            guard let v = stepValue.firstMatch(in: value, range: NSRange(location: 0, length: vs.length)),
                  let from = Int(vs.substring(with: v.range(at: 1))) else { continue }
            let to = v.range(at: 2).location != NSNotFound ? Int(vs.substring(with: v.range(at: 2))) : nil
            out.append(StepValue(value: value, from: from, to: to))
        }
        return out
    }

    /// How many frames a step-through has (`stepCount`): the captions or the highest step, at most 12.
    public static func stepCount(_ source: String, captions: [String]) -> Int {
        min(maxSteps, max(captions.count, stepValues(source).map(\.from).max() ?? 0, 0))
    }

    /// Frame `step` (from 1): elements outside it hidden with CSS, so a frame is still just an image.
    public static func stepFrame(_ source: String, step: Int) -> String {
        let hidden = stepValues(source).filter { step < $0.from || ($0.to.map { step > $0 } ?? false) }.map { "[data-step=\"\($0.value)\"]" }
        return hidden.isEmpty ? source : withStyle(source, css: "\(hidden.joined(separator: ",")){display:none}")
    }

    // MARK: Size

    /// The size an `<img>` gives an SVG, in CSS pixels: its `width`/`height` when they're plain numbers
    /// (or px), the missing one from the `viewBox`'s ratio, else the `viewBox` itself, else 300×150.
    /// Clamped to `limit` keeping the ratio, so one huge document can't make a huge render.
    public static func intrinsicSize(_ source: String, limit: Double = 4096) -> (width: Double, height: Double) {
        let ns = source as NSString
        var width: Double?, height: Double?, box: (Double, Double)?
        if let root = rootOpen.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: root.range)
            width = attribute("width", in: tag).flatMap(length)
            height = attribute("height", in: tag).flatMap(length)
            if let vb = attribute("viewBox", in: tag) {
                let parts = vb.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline || $0 == "\t" }).compactMap { Double($0) }
                if parts.count == 4, parts[2] > 0, parts[3] > 0 { box = (parts[2], parts[3]) }
            }
        }
        var size: (Double, Double)
        switch (width, height, box) {
        case let (w?, h?, _): size = (w, h)
        case let (w?, nil, b?): size = (w, w * b.1 / b.0)
        case let (nil, h?, b?): size = (h * b.0 / b.1, h)
        case let (nil, nil, b?): size = b
        case let (w?, nil, nil): size = (w, 150)
        case let (nil, h?, nil): size = (300, h)
        default: size = (300, 150)
        }
        let scale = min(1, limit / max(size.0, size.1, 1))
        return (max(1, (size.0 * scale).rounded()), max(1, (size.1 * scale).rounded()))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let ns = tag as NSString
        let pattern = regex("\\s\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", [])
        guard let m = pattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        return ns.substring(with: r)
    }

    private static func length(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix("px") { s = String(s.dropLast(2)) }
        guard let v = Double(s), v.isFinite, v > 0 else { return nil }
        return v
    }
}
