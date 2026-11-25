import CoreGraphics
import Foundation

/// Small lexing helpers shared by the diagram parsers.
enum MermaidScan {
    /// Splits on any of `separators` outside double quotes, brackets and parentheses, trimming
    /// each piece and dropping empty ones.
    static func splitTopLevel(_ s: String, separators: Set<Character>) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if !quoted {
                if "([{".contains(ch) { depth += 1 }
                if ")]}".contains(ch) { depth = max(0, depth - 1) }
                if depth == 0, separators.contains(ch) {
                    out.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Statement lines with `;` separators split out, keeping each piece's line number.
    static func statements(_ lines: [MermaidLine], headerRest: String = "", headerLine: Int = 1) -> [MermaidLine] {
        var out: [MermaidLine] = []
        let rest = headerRest.trimmingCharacters(in: CharacterSet(charactersIn: "; \t"))
        // `graph TD; A-->B` puts statements on the header line after its first word.
        if !rest.isEmpty {
            for piece in splitTopLevel(rest, separators: [";"]) { out.append(MermaidLine(number: headerLine, text: piece)) }
        }
        for l in lines {
            for piece in splitTopLevel(l.text, separators: [";"]) { out.append(MermaidLine(number: l.number, text: piece)) }
        }
        return out
    }

    /// `word rest` → (`word`, `rest`).
    static func firstWord(_ s: String) -> (String, String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (t, "") }
        return (String(t[..<sp]), String(t[sp...]).trimmingCharacters(in: .whitespaces))
    }

    /// `prefix` at the start of `s`, case-insensitively, followed by a space or the end.
    static func keyword(_ s: String, _ prefix: String) -> String? {
        guard s.count >= prefix.count, s.prefix(prefix.count).lowercased() == prefix.lowercased() else { return nil }
        let rest = s.dropFirst(prefix.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == ":" else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }
}

/// A forward-only cursor over a statement's characters.
struct MermaidCursor {
    let chars: [Character]
    var i = 0

    init(_ s: String) { chars = Array(s) }

    var atEnd: Bool { i >= chars.count }
    var peek: Character? { i < chars.count ? chars[i] : nil }
    var rest: String { i < chars.count ? String(chars[i...]) : "" }

    func peek(_ offset: Int) -> Character? { i + offset < chars.count && i + offset >= 0 ? chars[i + offset] : nil }

    func starts(with s: String) -> Bool {
        let a = Array(s)
        guard i + a.count <= chars.count else { return false }
        return Array(chars[i..<(i + a.count)]) == a
    }

    mutating func skipSpaces() {
        while let c = peek, c == " " || c == "\t" { i += 1 }
    }

    mutating func eat(_ s: String) -> Bool {
        guard starts(with: s) else { return false }
        i += s.count
        return true
    }
}

extension MermaidSVG {
    /// Opens the diagram: an optional centred title, then a group translated so content drawn at
    /// (0, 0)…`content` sits inside a margin. Returns the document size to pass to `document`.
    mutating func beginDiagram(content: CGSize, title: String?, margin: Double = 16) -> CGSize {
        let titleSize = 16.0
        let titleHeight = title == nil ? 0 : MermaidText.lineHeight(titleSize) + 10
        let titleWidth = title.map { MermaidText.width($0, size: titleSize, bold: true) } ?? 0
        let width = max(content.width, titleWidth) + margin * 2
        let height = content.height + titleHeight + margin * 2
        if let title {
            text(title, x: width / 2, y: margin + MermaidText.lineHeight(titleSize) / 2, size: titleSize, bold: true)
        }
        let dx = margin + (width - margin * 2 - content.width) / 2
        open("g", [("transform", "translate(\(Self.num(dx)) \(Self.num(margin + titleHeight)))")])
        return CGSize(width: width, height: height)
    }

    mutating func endDiagram() { close("g") }

    /// An edge's line, its arrowheads and its label on a background chip.
    mutating func edge(_ pts: [CGPoint], stroke: String, width: Double = 1.5, dash: String? = nil,
                       start: MermaidMarker? = nil, end: MermaidMarker? = nil) {
        guard pts.count >= 2 else { return }
        let s = start.map { marker($0, color: stroke) }, e = end.map { marker($0, color: stroke) }
        path(Self.roundedPath(pts), stroke: stroke, strokeWidth: width, dash: dash, start: s, end: e)
    }

    mutating func edgeLabel(_ lines: [String], in rect: CGRect, color: String? = nil, size: Double = MermaidText.fontSize) {
        guard !lines.isEmpty else { return }
        self.rect(rect, rx: 3, fill: theme.edgeLabelBackground)
        let h = MermaidText.lineHeight(size) * Double(lines.count)
        self.lines(lines, x: rect.midX, top: rect.midY - h / 2, size: size, fill: color)
    }
}
