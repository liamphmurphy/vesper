import CoreGraphics
import CoreText
import Foundation
import ImageIO
import os

/// A `<text>` element laid out once: positioned runs with their fonts, in the element's space.
///
/// Layout follows what Safari does for the profile's subset: whitespace collapses across spans,
/// an absolute `x`/`y` starts a new chunk, `text-anchor` shifts a whole chunk, and
/// `dominant-baseline` moves the baseline by the font's metrics the way WebKit's SVG text engine
/// does.
struct MockupSVGTextLayout: @unchecked Sendable {
    struct Run {
        let line: CTLine
        let font: CTFont
        /// The start of the run on its baseline.
        let origin: CGPoint
        let width: Double
        let ascent: Double
        let descent: Double
        let style: MockupSVGStyle

        var rect: CGRect { CGRect(x: origin.x, y: origin.y - ascent, width: width, height: ascent + descent) }
    }

    let runs: [Run]
    let bounds: CGRect
    var lineRects: [CGRect] { runs.map(\.rect) }

    init(_ text: MockupSVGNode, style: MockupSVGStyle, viewBox: CGRect) {
        var segments: [Segment] = []
        Self.collect(text, style: style, viewBox: viewBox, preserve: text.attribute("xml:space") == "preserve", into: &segments, isRoot: true)
        Self.collapseWhitespace(&segments)

        // Chunks: an absolute position starts one; the anchor of its first span shifts it whole.
        var runs: [Run] = []
        var pen = CGPoint.zero
        var chunk: [Int] = []
        var chunkAnchor = style.textAnchor
        func closeChunk() {
            guard !chunk.isEmpty else { return }
            let start = runs[chunk[0]].origin.x
            let end = chunk.map { runs[$0].origin.x + runs[$0].width }.max() ?? start
            let shift: Double = switch chunkAnchor {
            case "middle": -(end - start) / 2
            case "end": -(end - start)
            default: 0
            }
            if shift != 0 {
                for i in chunk {
                    let r = runs[i]
                    runs[i] = Run(line: r.line, font: r.font, origin: CGPoint(x: r.origin.x + shift, y: r.origin.y), width: r.width,
                                  ascent: r.ascent, descent: r.descent, style: r.style)
                }
            }
            chunk.removeAll()
        }
        for (i, seg) in segments.enumerated() {
            if seg.x != nil || seg.y != nil || i == 0 {
                closeChunk()
                chunkAnchor = seg.style.textAnchor
            }
            if let x = seg.x { pen.x = x }
            if let y = seg.y { pen.y = y }
            pen.x += seg.dx
            pen.y += seg.dy
            guard !seg.text.isEmpty else { continue }
            let font = MockupSVGFonts.font(family: seg.style.fontFamily, size: seg.style.fontSize, weight: seg.style.fontWeight, italic: seg.style.italic)
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            if seg.style.letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = seg.style.letterSpacing }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: seg.text, attributes: attrs))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            let shift = Self.baselineShift(seg.style.baseline, font: font)
            runs.append(Run(line: line, font: font, origin: CGPoint(x: pen.x, y: pen.y + shift), width: width,
                            ascent: ascent, descent: descent, style: seg.style))
            chunk.append(runs.count - 1)
            pen.x += width
        }
        closeChunk()
        self.runs = runs
        bounds = runs.reduce(CGRect.null) { $0.union($1.rect) }
    }

    /// How far below the alphabetic baseline the given baseline sits (Y down), as WebKit computes it.
    static func baselineShift(_ baseline: String, font: CTFont) -> Double {
        switch baseline {
        case "middle": CTFontGetXHeight(font) / 2
        case "central": (webKitAscent(font) - CTFontGetDescent(font)) / 2
        case "hanging": webKitAscent(font) * 0.8
        default: 0
        }
    }

    /// WebKit on macOS adds 15% of the line height to the ascent of Times, Helvetica and Courier
    /// (a long-standing compatibility adjustment), and its baselines are measured from that.
    static func webKitAscent(_ font: CTFont) -> Double {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let family = CTFontCopyFamilyName(font) as String
        guard family == "Times" || family == "Helvetica" || family == "Courier" else { return ascent }
        return ascent + ((ascent + descent) * 0.15).rounded()
    }

    private struct Segment {
        var text: String
        var style: MockupSVGStyle
        var x: Double?
        var y: Double?
        var dx = 0.0
        var dy = 0.0
        var preserve: Bool
    }

    private static func collect(_ n: MockupSVGNode, style: MockupSVGStyle, viewBox: CGRect, preserve: Bool,
                                into out: inout [Segment], isRoot: Bool) {
        var s = style
        if !isRoot {
            s = style.inherited()
            MockupSVGCompiler.apply(n, to: &s, viewBox: viewBox)
        }
        guard s.display else { return }
        // Decorations draw under the whole span even though the property isn't inherited.
        if style.underline { s.underline = true }
        if style.lineThrough { s.lineThrough = true }
        let keep = n.attribute("xml:space").map { $0 == "preserve" } ?? preserve
        func len(_ name: String, _ base: Double) -> Double? {
            n.attribute(name).flatMap { MockupSVGValues.length($0, percent: true) }?.resolve(base)
        }
        var first = Segment(text: "", style: s, x: len("x", viewBox.width), y: len("y", viewBox.height),
                            dx: len("dx", 0) ?? 0, dy: len("dy", 0) ?? 0, preserve: keep)
        var pendingPosition = true
        for c in n.children {
            switch c.kind {
            case .text, .cdata:
                if pendingPosition {
                    first.text = c.text
                    out.append(first)
                    pendingPosition = false
                } else {
                    out.append(Segment(text: c.text, style: s, preserve: keep))
                }
            case .element where c.localName == "tspan":
                if pendingPosition {
                    out.append(first)
                    pendingPosition = false
                }
                collect(c, style: s, viewBox: viewBox, preserve: keep, into: &out, isRoot: false)
            default:
                continue
            }
        }
        if pendingPosition { out.append(first) }
    }

    /// SVG's default whitespace handling: newlines go, tabs become spaces, runs of spaces collapse
    /// (across spans), and the text is trimmed at both ends. `xml:space="preserve"` only turns
    /// newlines and tabs into spaces.
    private static func collapseWhitespace(_ segs: inout [Segment]) {
        var lastWasSpace = true // trims the start
        for i in segs.indices {
            var out = ""
            for ch in segs[i].text {
                if segs[i].preserve {
                    out.append(ch == "\n" || ch == "\t" || ch == "\r" ? " " : ch)
                    lastWasSpace = false
                    continue
                }
                if ch == "\n" || ch == "\r" { continue }
                let isSpace = ch == " " || ch == "\t"
                if isSpace {
                    if !lastWasSpace { out.append(" ") }
                    lastWasSpace = true
                } else {
                    out.append(ch)
                    lastWasSpace = false
                }
            }
            segs[i].text = out
        }
        // Trim the end.
        for i in segs.indices.reversed() where !segs[i].preserve {
            if segs[i].text.isEmpty { continue }
            if segs[i].text.hasSuffix(" ") { segs[i].text.removeLast() }
            break
        }
    }
}

/// Font matching for mockup text: Safari's generic families and CSS's weight matching.
enum MockupSVGFonts {
    private struct Key: Hashable {
        let family: String
        let size: Double
        let weight: Int
        let italic: Bool
    }

    // CTFont is immutable and thread-safe, but not marked Sendable.
    private static let cache = OSAllocatedUnfairLock<[Key: CTFont]>(uncheckedState: [:])

    static func font(family: String, size: Double, weight: Int, italic: Bool) -> CTFont {
        let key = Key(family: family, size: size, weight: weight, italic: italic)
        if let hit = cache.withLockUnchecked({ $0[key] }) { return hit }
        let font = resolve(family: family, size: max(size, 0.01), weight: weight, italic: italic)
        cache.withLockUnchecked { $0[key] = font }
        return font
    }

    private static func resolve(family list: String, size: Double, weight: Int, italic: Bool) -> CTFont {
        for raw in list.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch name.lowercased() {
            case "system-ui", "-apple-system", "blinkmacsystemfont", "ui-sans-serif":
                return systemFont(size: size, weight: weight, italic: italic)
            case "sans-serif":
                if let f = named("Helvetica", size: size, weight: weight, italic: italic) { return f }
            case "serif":
                if let f = named("Times", size: size, weight: weight, italic: italic) { return f }
            case "monospace":
                if let f = named("Courier", size: size, weight: weight, italic: italic) { return f }
            case "ui-serif":
                if let f = named("New York", size: size, weight: weight, italic: italic) ?? named("Times", size: size, weight: weight, italic: italic) { return f }
            case "ui-monospace":
                if let f = named("SF Mono", size: size, weight: weight, italic: italic) ?? named("Menlo", size: size, weight: weight, italic: italic) { return f }
            default:
                if let f = named(name, size: size, weight: weight, italic: italic) { return f }
            }
        }
        return named("Times", size: size, weight: weight, italic: italic) ?? CTFontCreateWithName("Times" as CFString, size, nil)
    }

    private static func systemFont(size: Double, weight: Int, italic: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var desc = CTFontCopyFontDescriptor(base)
        let traits: [CFString: Any] = [kCTFontWeightTrait: ctWeight(weight)]
        desc = CTFontDescriptorCreateCopyWithAttributes(desc, [kCTFontTraitsAttribute: traits] as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(desc, size, nil)
        if italic, let slanted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) { font = slanted }
        return font
    }

    /// The face of `family` CSS font matching picks, or nil when the family isn't installed.
    private static func named(_ family: String, size: Double, weight: Int, italic: Bool) -> CTFont? {
        let attrs = [kCTFontFamilyNameAttribute: family] as CFDictionary
        let query = CTFontDescriptorCreateWithAttributes(attrs)
        guard let faces = CTFontDescriptorCreateMatchingFontDescriptors(query, NSSet(object: kCTFontFamilyNameAttribute)) as? [CTFontDescriptor],
              !faces.isEmpty else { return nil }
        struct Face { let desc: CTFontDescriptor; let weight: Int; let italic: Bool }
        let all: [Face] = faces.compactMap { d -> Face? in
            guard let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                  fam.caseInsensitiveCompare(family) == .orderedSame else { return nil }
            let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let w = (traits[kCTFontWeightTrait] as? Double) ?? 0
            let sym = CTFontSymbolicTraits(rawValue: (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0)
            return Face(desc: d, weight: cssWeight(w), italic: sym.contains(.traitItalic))
        }
        guard !all.isEmpty else { return nil }
        let styled = all.filter { $0.italic == italic }
        let pool = styled.isEmpty ? all : styled
        let weights = Set(pool.map(\.weight))
        let chosen = matchWeight(weight, available: weights)
        guard let face = pool.first(where: { $0.weight == chosen }) else { return nil }
        return CTFontCreateWithFontDescriptor(face.desc, size, nil)
    }

    /// CSS Fonts §5.2 weight matching.
    static func matchWeight(_ desired: Int, available: Set<Int>) -> Int {
        guard !available.contains(desired) else { return desired }
        let lighter = available.filter { $0 < desired }.sorted(by: >)
        let heavier = available.filter { $0 > desired }.sorted()
        if desired >= 400, desired <= 500 {
            if let w = heavier.first(where: { $0 <= 500 }) { return w }
            if let w = lighter.first { return w }
            return heavier.first ?? desired
        }
        if desired < 400 { return lighter.first ?? heavier.first ?? desired }
        return heavier.first ?? lighter.first ?? desired
    }

    static func cssWeight(_ t: Double) -> Int {
        switch t {
        case ..<(-0.7): 100
        case ..<(-0.5): 200
        case ..<(-0.2): 300
        case ..<0.15: 400
        case ..<0.27: 500
        case ..<0.35: 600
        case ..<0.5: 700
        case ..<0.6: 800
        default: 900
        }
    }

    static func ctWeight(_ w: Int) -> Double {
        switch w {
        case ...100: -0.8
        case ...200: -0.6
        case ...300: -0.4
        case ...400: 0
        case ...500: 0.23
        case ...600: 0.3
        case ...700: 0.4
        case ...800: 0.56
        default: 0.62
        }
    }
}

/// Decodes `<image>` data with ImageIO (available on macOS and iOS).
enum MockupSVGImages {
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
