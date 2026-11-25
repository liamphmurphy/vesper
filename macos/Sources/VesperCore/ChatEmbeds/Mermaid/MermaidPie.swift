import CoreGraphics
import Foundation

/// `pie`: quoted labels with values, an optional `title` (on the header line or its own) and
/// `showData`, which adds each value to the legend.
///
/// Slices follow mermaid v11 (d3's pie): largest first, ties in source order, starting at twelve
/// o'clock and running clockwise, with series colours handed out in that order and the legend
/// listing slices the same way. Zero slices are left out, as they'd draw nothing.
struct MermaidPie {
    struct Slice {
        var label: String
        var value: Double
    }

    var slices: [Slice] = []
    var showData = false
    var title: String?

    // MARK: Parsing

    static func parse(_ doc: MermaidSource) throws(NativeMermaidError) -> MermaidPie {
        var p = MermaidPie()
        p.title = doc.title
        var header = doc.headerRest
        if let rest = MermaidScan.keyword(header, "showData") {
            p.showData = true
            header = rest
        }
        if let rest = MermaidScan.keyword(header, "title") {
            p.title = rest.isEmpty ? p.title : rest
        } else if !header.isEmpty {
            throw .syntax(line: doc.headerLine, message: "expected showData or title after pie")
        }
        var seen: Set<String> = []
        var skippingBlock = false
        for line in doc.lines {
            let t = line.text
            if skippingBlock {
                if t.contains("}") { skippingBlock = false }
                continue
            }
            if t.hasPrefix("accTitle") || t.hasPrefix("accDescr") {
                // `accDescr {` opens a multi-line description that runs to the closing brace.
                if t.contains("{"), !t.contains("}") { skippingBlock = true }
                continue
            }
            if let rest = MermaidScan.keyword(t, "title") {
                if !rest.isEmpty { p.title = rest }
                continue
            }
            if MermaidScan.keyword(t, "showData") != nil { p.showData = true; continue }
            let slice = try parseSlice(t, line: line.number)
            // Mermaid keeps the first value given for a repeated label.
            guard !seen.contains(slice.label) else { continue }
            seen.insert(slice.label)
            if slice.value > 0 { p.slices.append(slice) }
        }
        guard p.slices.count <= NativeMermaid.maxRows else { throw .tooLarge }
        guard !p.slices.isEmpty else { throw .syntax(line: doc.headerLine, message: "the pie has no slices with a value above zero") }
        // A stable sort, so equal slices keep the order they were written in.
        p.slices = p.slices.enumerated().sorted { a, b in
            a.element.value != b.element.value ? a.element.value > b.element.value : a.offset < b.offset
        }.map(\.element)
        return p
    }

    /// `"Label" : 42.5` (single quotes work too).
    static func parseSlice(_ t: String, line: Int) throws(NativeMermaidError) -> Slice {
        let expected = NativeMermaidError.syntax(line: line, message: "expected a slice like \"Label\" : 42")
        guard let quote = t.first, quote == "\"" || quote == "'" else { throw expected }
        let afterOpen = t.index(after: t.startIndex)
        guard let close = t[afterOpen...].firstIndex(of: quote) else { throw expected }
        let label = String(t[afterOpen..<close])
        var rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix(":") else { throw expected }
        rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard rest.wholeMatch(of: /-?[0-9]+(\.[0-9]+)?/) != nil, let value = Double(rest) else { throw expected }
        guard value >= 0 else {
            throw .syntax(line: line, message: "\"\(label)\" has a negative value; pie slices must be zero or more")
        }
        return Slice(label: label, value: value)
    }

    // MARK: Layout and drawing

    static let radius = 150.0
    static let legendGap = 32.0
    static let legendSwatch = 14.0
    static let legendRowGap = 8.0
    static let legendMaxWidth = 260.0

    func draw(_ theme: MermaidTheme) -> MermaidDrawing {
        let r = Self.radius
        let total = slices.reduce(0) { $0 + $1.value }
        let lh = MermaidText.lineHeight()

        let legend = slices.map { s in
            let text = showData ? "\(s.label) [\(Self.format(s.value))]" : s.label
            return MermaidText.wrap([MermaidText.collapse(text)], maxWidth: Self.legendMaxWidth)
        }
        let rowHeights = legend.map { max(Self.legendSwatch, lh * Double($0.count)) }
        let legendHeight = rowHeights.reduce(0, +) + Self.legendRowGap * Double(max(0, legend.count - 1))
        let legendWidth = Self.legendSwatch + 8 + (legend.map { MermaidText.width(lines: $0) }.max() ?? 0)
        let height = max(2 * r, legendHeight)
        let center = CGPoint(x: r, y: height / 2)

        var svg = MermaidSVG(theme: theme)
        let size = svg.beginDiagram(content: CGSize(width: 2 * r + Self.legendGap + legendWidth, height: height), title: title)

        // Slices, each outlined in the surface colour so neighbours read as separate.
        var angle = -Double.pi / 2
        var labels: [(String, CGPoint, String)] = []
        for (i, s) in slices.enumerated() {
            let span = s.value / total * 2 * .pi
            let fill = theme.series(i)
            if slices.count == 1 {
                svg.add("circle", [("cx", MermaidSVG.num(center.x)), ("cy", MermaidSVG.num(center.y)), ("r", MermaidSVG.num(r)),
                                   ("fill", fill)])
            } else {
                let a = point(center, r, angle), b = point(center, r, angle + span)
                let large = span > .pi ? 1 : 0
                svg.path("M\(MermaidSVG.num(center.x)),\(MermaidSVG.num(center.y)) L\(MermaidSVG.num(a.x)),\(MermaidSVG.num(a.y)) A\(MermaidSVG.num(r)),\(MermaidSVG.num(r)) 0 \(large) 1 \(MermaidSVG.num(b.x)),\(MermaidSVG.num(b.y)) Z",
                         fill: fill, stroke: theme.background, strokeWidth: 2)
            }
            // The percentage goes inside only where the slice is wide enough at that radius to hold it.
            let percent = "\(Int((s.value / total * 100).rounded()))%"
            let labelRadius = r * 0.68
            let room = span >= .pi ? .infinity : 2 * labelRadius * sin(span / 2)
            let textWidth = MermaidText.width(percent, bold: true)
            if room >= textWidth + 10, r - labelRadius >= lh / 2 + 4 {
                let at = slices.count == 1 ? center : point(center, labelRadius, angle + span / 2)
                labels.append((percent, at, theme.ink(on: fill)))
            }
            angle += span
        }
        for (text, p, color) in labels {
            svg.text(text, x: p.x, y: p.y, bold: true, fill: color)
        }

        // Legend, vertically centred beside the pie.
        let left = 2 * r + Self.legendGap
        var y = (height - legendHeight) / 2
        for (i, lines) in legend.enumerated() {
            let rowMid = y + rowHeights[i] / 2
            let swatchTop = lines.count > 1 ? y + (lh - Self.legendSwatch) / 2 : rowMid - Self.legendSwatch / 2
            svg.rect(CGRect(x: left, y: swatchTop, width: Self.legendSwatch, height: Self.legendSwatch), rx: 2, fill: theme.series(i))
            svg.lines(lines, x: left + Self.legendSwatch + 8, top: rowMid - lh * Double(lines.count) / 2, anchor: "start")
            y += rowHeights[i] + Self.legendRowGap
        }
        svg.endDiagram()
        return MermaidDrawing(svg: svg.document(size: size, title: title), texts: svg.texts)
    }

    private func point(_ c: CGPoint, _ r: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }

    /// A value as written, without a trailing `.0` for whole numbers.
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }
}

extension MermaidTheme {
    /// The theme's text or surface colour, whichever stands out more against `fill`, so labels on
    /// series colours stay legible in both palettes.
    func ink(on fill: String) -> String {
        guard let f = Self.luminance(fill), let t = Self.luminance(text), let b = Self.luminance(background) else { return text }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        return contrast(f, t) >= contrast(f, b) ? text : background
    }

    /// WCAG relative luminance of a `#rgb`/`#rrggbb` colour; nil for anything else.
    static func luminance(_ hex: String) -> Double? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        func channel(_ c: UInt32) -> Double {
            let s = Double(c) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(v >> 16 & 0xFF) + 0.7152 * channel(v >> 8 & 0xFF) + 0.0722 * channel(v & 0xFF)
    }
}
