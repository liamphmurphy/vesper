import CoreGraphics
import CoreText
import Foundation

/// Label text: mermaid's markup reduced to plain lines, and measured with the font the SVG names.
enum MermaidText {
    /// The app's font. `MockupSVGFonts` resolves `system-ui` to the system font, and measurement
    /// goes through the same resolver, so a measured width is the drawn width.
    static let fontFamily = "system-ui, -apple-system, sans-serif"
    static let fontSize = 14.0
    static let smallSize = 12.0

    static func font(size: Double, bold: Bool = false, italic: Bool = false) -> CTFont {
        MockupSVGFonts.font(family: fontFamily, size: size, weight: bold ? 700 : 400, italic: italic)
    }

    /// The advance of `text` as one line, after SVG whitespace collapsing.
    static func width(_ text: String, size: Double = fontSize, bold: Bool = false, italic: Bool = false) -> Double {
        let t = collapse(text)
        guard !t.isEmpty else { return 0 }
        let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold, italic: italic)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: attrs))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    static func lineHeight(_ size: Double = fontSize) -> Double { (size * 1.3).rounded() }

    /// The widest of `lines`.
    static func width(lines: [String], size: Double = fontSize, bold: Bool = false) -> Double {
        lines.map { width($0, size: size, bold: bold) }.max() ?? 0
    }

    /// A label as display lines: mermaid's `#…;` entity codes and HTML entities decoded, `<br>`
    /// splitting lines, other tags and markdown emphasis markers dropped (the profile has no rich
    /// text here, and plain reads fine).
    static func lines(_ label: String) -> [String] {
        var s = unquote(label)
        if s.hasPrefix("`"), s.hasSuffix("`"), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</?[A-Za-z][A-Za-z0-9]*(\s[^<>]*)?/?>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        s = decodeEntities(s)
        return s.split(separator: "\n", omittingEmptySubsequences: false).map { collapse(String($0)) }
    }

    /// Greedy word wrap so one long label doesn't make a node a whole diagram wide. Words longer
    /// than `maxWidth` stay whole.
    static func wrap(_ lines: [String], maxWidth: Double, size: Double = fontSize, bold: Bool = false) -> [String] {
        var out: [String] = []
        for line in lines {
            guard width(line, size: size, bold: bold) > maxWidth else { out.append(line); continue }
            var current = ""
            for word in line.split(separator: " ") {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if current.isEmpty || width(candidate, size: size, bold: bold) <= maxWidth {
                    current = candidate
                } else {
                    out.append(current)
                    current = String(word)
                }
            }
            out.append(current)
        }
        return out
    }

    /// `"text"` → `text`.
    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { return String(t.dropFirst().dropLast()) }
        return t
    }

    /// Whitespace as SVG collapses it, so measured and drawn text agree.
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    private static let named: [String: String] = [
        "quot": "\"", "amp": "&", "lt": "<", "gt": ">", "apos": "'", "nbsp": " ", "num": "#", "semi": ";",
        "colon": ":", "lpar": "(", "rpar": ")", "lsqb": "[", "rsqb": "]", "lbrace": "{", "rbrace": "}",
    ]

    /// `#quot;`/`#35;` (mermaid's escapes) and `&quot;`/`&#35;` (HTML's).
    static func decodeEntities(_ s: String) -> String {
        guard s.contains(";") else { return s }
        let regex = /([#&])(#?)([A-Za-z0-9]{1,8});/
        return s.replacing(regex) { m in
            let body = String(m.output.3)
            let numeric = m.output.1 == "#" || !m.output.2.isEmpty
            if numeric, let code = Int(body), let scalar = Unicode.Scalar(code), code >= 32 {
                return String(Character(scalar))
            }
            if let v = named[body.lowercased()] { return v }
            return String(m.output.0)
        }
    }
}

/// The kinds of line ends the diagrams use, drawn as `<marker>`s pointing along +x with the tip at
/// the end of the line, oriented `auto-start-reverse` so one definition serves both ends.
enum MermaidMarker: String {
    case arrow, openArrow, circle, cross
    case triangle, diamondFilled, diamondHollow
    case erOne, erZeroOne, erOneMany, erZeroMany
}

/// Builds a profile v1 SVG: elements with presentation attributes only, markers in `<defs>`,
/// numbers rounded to hundredths so output is stable.
struct MermaidSVG {
    private var body = ""
    private var defs = ""
    private var markers: [String: String] = [:]
    private(set) var texts: [String] = []
    let theme: MermaidTheme

    init(theme: MermaidTheme) { self.theme = theme }

    static func num(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // XML 1.0 has no representation for most control characters.
            case _ where ch.value < 0x20 || (ch.value >= 0xFFFE && ch.value <= 0xFFFF) || (ch.value >= 0xD800 && ch.value <= 0xDFFF):
                continue
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static func attributes(_ attrs: [(String, String?)]) -> String {
        var s = ""
        for (k, v) in attrs {
            guard let v else { continue }
            s += " \(k)=\"\(escape(v))\""
        }
        return s
    }

    mutating func add(_ name: String, _ attrs: [(String, String?)]) {
        body += "<\(name)\(Self.attributes(attrs))/>"
    }

    mutating func open(_ name: String, _ attrs: [(String, String?)] = []) {
        body += "<\(name)\(Self.attributes(attrs))>"
    }

    mutating func close(_ name: String) { body += "</\(name)>" }

    mutating func rect(_ r: CGRect, rx: Double = 0, fill: String, stroke: String? = nil, strokeWidth: Double? = nil,
                       dash: String? = nil, fillOpacity: Double? = nil) {
        add("rect", [
            ("x", Self.num(r.minX)), ("y", Self.num(r.minY)), ("width", Self.num(r.width)), ("height", Self.num(r.height)),
            ("rx", rx > 0 ? Self.num(rx) : nil), ("fill", fill), ("fill-opacity", fillOpacity.map(Self.num)),
            ("stroke", stroke), ("stroke-width", strokeWidth.map(Self.num)), ("stroke-dasharray", dash),
        ])
    }

    mutating func line(_ a: CGPoint, _ b: CGPoint, stroke: String, width: Double = 1, dash: String? = nil) {
        add("line", [("x1", Self.num(a.x)), ("y1", Self.num(a.y)), ("x2", Self.num(b.x)), ("y2", Self.num(b.y)),
                     ("stroke", stroke), ("stroke-width", Self.num(width)), ("stroke-dasharray", dash)])
    }

    mutating func polygon(_ pts: [CGPoint], fill: String, stroke: String? = nil, strokeWidth: Double? = nil, dash: String? = nil) {
        add("polygon", [("points", pts.map { "\(Self.num($0.x)),\(Self.num($0.y))" }.joined(separator: " ")),
                        ("fill", fill), ("stroke", stroke), ("stroke-width", strokeWidth.map(Self.num)), ("stroke-dasharray", dash),
                        ("stroke-linejoin", stroke == nil ? nil : "round")])
    }

    mutating func path(_ d: String, fill: String = "none", stroke: String? = nil, strokeWidth: Double? = nil, dash: String? = nil,
                       start: String? = nil, end: String? = nil) {
        add("path", [("d", d), ("fill", fill), ("stroke", stroke), ("stroke-width", strokeWidth.map(Self.num)),
                     ("stroke-dasharray", dash), ("stroke-linejoin", stroke == nil ? nil : "round"),
                     ("marker-start", start), ("marker-end", end)])
    }

    /// One line of text, vertically centred on `y`.
    mutating func text(_ s: String, x: Double, y: Double, anchor: String = "middle", size: Double = MermaidText.fontSize,
                       bold: Bool = false, italic: Bool = false, underline: Bool = false, fill: String? = nil) {
        let t = MermaidText.collapse(s)
        guard !t.isEmpty else { return }
        texts.append(t)
        body += "<text\(Self.attributes([("x", Self.num(x)), ("y", Self.num(y)), ("text-anchor", anchor), ("dominant-baseline", "central"), ("fill", fill ?? theme.text), ("font-size", size == MermaidText.fontSize ? nil : Self.num(size)), ("font-weight", bold ? "bold" : nil), ("font-style", italic ? "italic" : nil), ("text-decoration", underline ? "underline" : nil)]))>\(Self.escape(t))</text>"
    }

    /// Lines stacked from `top`, each centred on `x` (or anchored as given).
    mutating func lines(_ lines: [String], x: Double, top: Double, anchor: String = "middle", size: Double = MermaidText.fontSize,
                        bold: Bool = false, fill: String? = nil) {
        let lh = MermaidText.lineHeight(size)
        for (i, l) in lines.enumerated() {
            text(l, x: x, y: top + lh * (Double(i) + 0.5), anchor: anchor, size: size, bold: bold, fill: fill)
        }
    }

    /// A rounded polyline: orthogonal bends get a small curve, which reads like mermaid's curved
    /// edges without leaving the routed corridor.
    static func roundedPath(_ pts: [CGPoint], radius: Double = 6) -> String {
        guard let first = pts.first else { return "" }
        var d = "M\(num(first.x)),\(num(first.y))"
        guard pts.count > 2 else {
            if pts.count == 2 { d += " L\(num(pts[1].x)),\(num(pts[1].y))" }
            return d
        }
        for i in 1..<(pts.count - 1) {
            let p = pts[i], a = pts[i - 1], b = pts[i + 1]
            let la = hypot(p.x - a.x, p.y - a.y), lb = hypot(b.x - p.x, b.y - p.y)
            let r = min(radius, la / 2, lb / 2)
            guard r > 0.5 else { d += " L\(num(p.x)),\(num(p.y))"; continue }
            let p1 = CGPoint(x: p.x - (p.x - a.x) / la * r, y: p.y - (p.y - a.y) / la * r)
            let p2 = CGPoint(x: p.x + (b.x - p.x) / lb * r, y: p.y + (b.y - p.y) / lb * r)
            d += " L\(num(p1.x)),\(num(p1.y)) Q\(num(p.x)),\(num(p.y)) \(num(p2.x)),\(num(p2.y))"
        }
        let last = pts[pts.count - 1]
        d += " L\(num(last.x)),\(num(last.y))"
        return d
    }

    /// `url(#id)` for a marker of `kind` in `color`, defined once per pair.
    mutating func marker(_ kind: MermaidMarker, color: String) -> String {
        let key = "\(kind.rawValue)|\(color)"
        if let id = markers[key] { return "url(#\(id))" }
        let id = "m\(markers.count + 1)"
        markers[key] = id
        let bg = Self.escape(theme.background), c = Self.escape(color)
        let (w, h, refX, refY, content): (Double, Double, Double, Double, String) = switch kind {
        case .arrow: (10, 10, 10, 5, "<path d=\"M0,0 L10,5 L0,10 Z\" fill=\"\(c)\"/>")
        case .openArrow: (11, 12, 10, 6, "<path d=\"M1,1 L10,6 L1,11\" fill=\"none\" stroke=\"\(c)\" stroke-width=\"1.5\" stroke-linejoin=\"round\"/>")
        case .circle: (10, 10, 9, 5, "<circle cx=\"5\" cy=\"5\" r=\"4\" fill=\"\(bg)\" stroke=\"\(c)\" stroke-width=\"1.5\"/>")
        case .cross: (10, 10, 9, 5, "<path d=\"M1,1 L9,9 M9,1 L1,9\" stroke=\"\(c)\" stroke-width=\"2\"/>")
        case .triangle: (18, 18, 17, 9, "<path d=\"M1,1 L17,9 L1,17 Z\" fill=\"\(bg)\" stroke=\"\(c)\" stroke-width=\"1.5\" stroke-linejoin=\"round\"/>")
        case .diamondFilled: (20, 14, 19, 7, "<path d=\"M1,7 L10,1 L19,7 L10,13 Z\" fill=\"\(c)\" stroke=\"\(c)\" stroke-width=\"1\"/>")
        case .diamondHollow: (20, 14, 19, 7, "<path d=\"M1,7 L10,1 L19,7 L10,13 Z\" fill=\"\(bg)\" stroke=\"\(c)\" stroke-width=\"1.5\" stroke-linejoin=\"round\"/>")
        case .erOne: (22, 18, 22, 9, "<path d=\"M13,2 L13,16 M18,2 L18,16\" stroke=\"\(c)\" stroke-width=\"1.5\"/>")
        case .erZeroOne: (22, 18, 22, 9, "<path d=\"M18,2 L18,16\" stroke=\"\(c)\" stroke-width=\"1.5\"/><circle cx=\"9\" cy=\"9\" r=\"4\" fill=\"\(bg)\" stroke=\"\(c)\" stroke-width=\"1.5\"/>")
        case .erOneMany: (22, 18, 22, 9, "<path d=\"M12,9 L22,2 M12,9 L22,16 M7,2 L7,16\" stroke=\"\(c)\" stroke-width=\"1.5\" fill=\"none\"/>")
        case .erZeroMany: (22, 18, 22, 9, "<path d=\"M12,9 L22,2 M12,9 L22,16\" stroke=\"\(c)\" stroke-width=\"1.5\" fill=\"none\"/><circle cx=\"6\" cy=\"9\" r=\"4\" fill=\"\(bg)\" stroke=\"\(c)\" stroke-width=\"1.5\"/>")
        }
        defs += "<marker id=\"\(id)\" markerWidth=\"\(Self.num(w))\" markerHeight=\"\(Self.num(h))\" refX=\"\(Self.num(refX))\" refY=\"\(Self.num(refY))\" markerUnits=\"userSpaceOnUse\" orient=\"auto-start-reverse\">\(content)</marker>"
        return "url(#\(id))"
    }

    /// The finished document, `size` in user units, on the palette's surface.
    func document(size: CGSize, title: String?) -> String {
        let w = Self.num(size.width.rounded(.up)), h = Self.num(size.height.rounded(.up))
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">"
        if let title { s += "<title>\(Self.escape(title))</title>" }
        if !defs.isEmpty { s += "<defs>\(defs)</defs>" }
        s += "<rect x=\"0\" y=\"0\" width=\"\(w)\" height=\"\(h)\" fill=\"\(Self.escape(theme.background))\"/>"
        s += "<g font-family=\"\(Self.escape(MermaidText.fontFamily))\" font-size=\"\(Self.num(MermaidText.fontSize))\">\(body)</g></svg>"
        return s
    }
}

/// Paint and stroke overrides from `classDef`/`style`/`linkStyle` (`fill:#f9f,stroke:#333,…`),
/// kept only when the value is one the profile accepts.
struct MermaidStyle: Equatable {
    var fill: String?
    var stroke: String?
    var strokeWidth: Double?
    var dash: String?
    var color: String?
    var bold = false

    init() {}

    init(css: String) {
        for decl in MermaidScan.splitTopLevel(css, separators: [",", ";"]) {
            let parts = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            switch key {
            case "fill", "background", "background-color": if Self.isColor(value) { fill = value }
            case "stroke", "border-color": if Self.isColor(value) { stroke = value }
            case "color": if Self.isColor(value) { color = value }
            case "stroke-width":
                if let n = Double(value.replacingOccurrences(of: "px", with: "")), n >= 0, n <= 20 { strokeWidth = n }
            case "stroke-dasharray":
                let nums = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0.replacingOccurrences(of: "px", with: "")) }
                if !nums.isEmpty { dash = nums.map(MermaidSVG.num).joined(separator: " ") }
            case "font-weight": bold = value == "bold" || (Int(value) ?? 400) >= 600
            default: continue
            }
        }
    }

    /// Later declarations win, as in CSS.
    func merged(over base: MermaidStyle) -> MermaidStyle {
        var s = base
        if let fill { s.fill = fill }
        if let stroke { s.stroke = stroke }
        if let strokeWidth { s.strokeWidth = strokeWidth }
        if let dash { s.dash = dash }
        if let color { s.color = color }
        if bold { s.bold = true }
        return s
    }

    private static func isColor(_ v: String) -> Bool {
        guard case .color? = MockupSVGValues.paint(v) else { return false }
        return true
    }
}
