import CoreGraphics
import Foundation

/// The value grammars of Mockup SVG profile v1 (`docs/dev/mockup-svg-profile.md`), shared by the
/// validator and the document compiler so a value conforms exactly when the renderer can read it.
/// Every parser returns nil for a value outside the profile.
enum MockupSVGValues {
    enum Length: Equatable {
        case number(Double)
        case percent(Double)

        /// The value in user units; a percentage resolves against `base`.
        func resolve(_ base: Double) -> Double {
            switch self {
            case .number(let v): v
            case .percent(let p): p / 100 * base
            }
        }

        /// The value as a fraction of a bounding box: `0.5` and `50%` are the same.
        var fraction: Double {
            switch self {
            case .number(let v): v
            case .percent(let p): p / 100
            }
        }
    }

    struct RGBA: Equatable {
        var r: Double, g: Double, b: Double, a: Double

        static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    }

    enum Color: Equatable {
        case rgba(RGBA)
        case currentColor
    }

    enum Paint: Equatable {
        case none
        case color(Color)
        /// A gradient or pattern; `fallback` paints when the reference can't (`url(#x) #fff`).
        case url(String, fallback: Fallback?)

        enum Fallback: Equatable {
            case none
            case color(Color)
        }
    }

    struct AspectRatio: Equatable {
        /// Alignment fractions (0 min, 0.5 mid, 1 max); nil is `none`.
        var align: (x: Double, y: Double)?
        var slice: Bool

        static let `default` = AspectRatio(align: (0.5, 0.5), slice: false)

        static func == (l: AspectRatio, r: AspectRatio) -> Bool {
            l.slice == r.slice && l.align?.x == r.align?.x && l.align?.y == r.align?.y
        }

        /// Maps `viewBox` into `viewport` (SVG's viewBox-to-viewport transform).
        func transform(viewBox vb: CGRect, into viewport: CGRect) -> CGAffineTransform {
            guard vb.width > 0, vb.height > 0 else { return .identity }
            var sx = viewport.width / vb.width
            var sy = viewport.height / vb.height
            var tx = viewport.minX - vb.minX * sx
            var ty = viewport.minY - vb.minY * sy
            if let align {
                let s = slice ? max(sx, sy) : min(sx, sy)
                sx = s
                sy = s
                tx = viewport.minX - vb.minX * s + (viewport.width - vb.width * s) * align.x
                ty = viewport.minY - vb.minY * s + (viewport.height - vb.height * s) * align.y
            }
            return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
        }
    }

    // MARK: Numbers and lengths

    static func number(_ raw: String) -> Double? {
        var s = Scanner(raw)
        s.skipSpace()
        guard let v = s.number() else { return nil }
        s.skipSpace()
        return s.atEnd ? v : nil
    }

    /// A number with an optional `px`, or a percentage when `percent` allows it.
    static func length(_ raw: String, percent: Bool) -> Length? {
        var s = Scanner(raw)
        s.skipSpace()
        guard let v = s.number() else { return nil }
        var out = Length.number(v)
        if s.consume(caseInsensitive: "px") {
        } else if percent, s.consume("%") {
            out = .percent(v)
        }
        s.skipSpace()
        return s.atEnd ? out : nil
    }

    /// A comma/whitespace-separated list of numbers, as in `points` and `viewBox`.
    static func numberList(_ raw: String) -> [Double]? {
        var s = Scanner(raw)
        var out: [Double] = []
        s.skipSpace()
        while !s.atEnd {
            guard let v = s.number() else { return nil }
            out.append(v)
            s.skipCommaSpace()
        }
        // A trailing comma ("1,2,") isn't a list.
        if raw.trimmingCharacters(in: .whitespaces).hasSuffix(",") { return nil }
        return out
    }

    static func viewBox(_ raw: String) -> CGRect? {
        guard let v = numberList(raw), v.count == 4, v[2] >= 0, v[3] >= 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func points(_ raw: String) -> [CGPoint]? {
        guard let v = numberList(raw), v.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: v.count, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
    }

    /// `none` (an empty list) or non-negative lengths without units other than `px`.
    static func dashArray(_ raw: String) -> [Double]? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.lowercased() == "none" { return [] }
        var out: [Double] = []
        for part in t.split(whereSeparator: { $0 == "," || $0 == " " }) where !part.isEmpty {
            guard case .number(let v)? = length(String(part), percent: false), v >= 0 else { return nil }
            out.append(v)
        }
        guard !out.isEmpty, !t.hasSuffix(","), !t.hasPrefix(",") else { return nil }
        return out
    }

    // MARK: Keywords

    /// A CSS keyword (presentation attributes are CSS, so ASCII case doesn't matter).
    static func keyword(_ raw: String, _ allowed: Set<String>) -> String? {
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return allowed.contains(k) ? k : nil
    }

    /// An SVG attribute enumeration (case-sensitive, as SVG attributes are).
    static func enumeration(_ raw: String, _ allowed: Set<String>) -> String? {
        let k = raw.trimmingCharacters(in: .whitespaces)
        return allowed.contains(k) ? k : nil
    }

    /// `normal`, `bold`, `bolder`, `lighter` or 100…900 in hundreds. Returns the keyword or the number.
    static func fontWeight(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if ["normal", "bold", "bolder", "lighter"].contains(k) { return k }
        guard let v = Int(k), (100...900).contains(v), v % 100 == 0 else { return nil }
        return k
    }

    static func aspectRatio(_ raw: String) -> AspectRatio? {
        let parts = raw.split(whereSeparator: { $0 == " " }).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        var slice = false
        if parts.count == 2 {
            switch parts[1] {
            case "meet": slice = false
            case "slice": slice = true
            default: return nil
            }
        }
        if parts[0] == "none" { return AspectRatio(align: nil, slice: slice) }
        let a = parts[0]
        guard a.count == 8, a.hasPrefix("x"), a.dropFirst(4).hasPrefix("Y") else { return nil }
        let fractions = ["Min": 0.0, "Mid": 0.5, "Max": 1.0]
        guard let x = fractions[String(a.dropFirst(1).prefix(3))], let y = fractions[String(a.dropFirst(5))] else { return nil }
        return AspectRatio(align: (x, y), slice: slice)
    }

    // MARK: Colours and paint

    static func color(_ raw: String) -> Color? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if lower == "currentcolor" { return .currentColor }
        if lower == "transparent" { return .rgba(RGBA(r: 0, g: 0, b: 0, a: 0)) }
        if let hex = namedColors[lower] { return .rgba(rgb24(hex)) }
        if lower.hasPrefix("#") { return hexColor(lower.dropFirst()).map(Color.rgba) }
        if let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            let fn = lower[..<open]
            let args = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
            switch fn {
            case "rgb", "rgba": return rgbFunction(args).map(Color.rgba)
            case "hsl", "hsla": return hslFunction(args).map(Color.rgba)
            default: return nil
            }
        }
        return nil
    }

    static func paint(_ raw: String) -> Paint? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.lowercased() == "none" { return Paint.none }
        if t.lowercased().hasPrefix("url(") {
            guard let close = t.firstIndex(of: ")"), let id = urlTarget(t[t.index(t.startIndex, offsetBy: 4)..<close]) else { return nil }
            let rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .url(id, fallback: nil) }
            if rest.lowercased() == "none" { return .url(id, fallback: Paint.Fallback.none) }
            guard let c = color(rest) else { return nil }
            return .url(id, fallback: .color(c))
        }
        return color(t).map(Paint.color)
    }

    /// `none` (returns "") or `url(#id)` (returns the id), as in `clip-path`, `mask` and `marker-*`.
    static func reference(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.lowercased() == "none" { return "" }
        guard t.lowercased().hasPrefix("url("), t.hasSuffix(")") else { return nil }
        return urlTarget(t[t.index(t.startIndex, offsetBy: 4)..<t.index(before: t.endIndex)])
    }

    /// The id in `#id` for `href`, or nil.
    static func fragment(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#"), t.count > 1 else { return nil }
        return String(t.dropFirst())
    }

    private static func urlTarget(_ inner: Substring) -> String? {
        var s = inner.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let q = s.first, q == "\"" || q == "'", s.last == q {
            s = String(s.dropFirst().dropLast())
        }
        guard s.hasPrefix("#"), s.count > 1, !s.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) else { return nil }
        return String(s.dropFirst())
    }

    private static func rgb24(_ v: UInt32) -> RGBA {
        RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }

    private static func hexColor(_ h: Substring) -> RGBA? {
        guard [3, 4, 6, 8].contains(h.count), h.allSatisfy(\.isHexDigit) else { return nil }
        let digits = h.map { Double(Int(String($0), radix: 16)!) }
        if h.count <= 4 {
            return RGBA(r: digits[0] * 17 / 255, g: digits[1] * 17 / 255, b: digits[2] * 17 / 255, a: h.count == 4 ? digits[3] * 17 / 255 : 1)
        }
        func byte(_ i: Int) -> Double { (digits[i] * 16 + digits[i + 1]) / 255 }
        return RGBA(r: byte(0), g: byte(2), b: byte(4), a: h.count == 8 ? byte(6) : 1)
    }

    /// Splits `rgb()`/`hsl()` arguments in either comma or space syntax; the alpha is last.
    private static func colorArguments(_ args: String) -> (parts: [String], alpha: String?)? {
        if args.contains(",") {
            guard !args.contains("/") else { return nil }
            let parts = args.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4, !parts.contains(where: { $0.isEmpty || $0.contains(" ") }) else { return nil }
            return (Array(parts.prefix(3)), parts.count == 4 ? parts[3] : nil)
        }
        let halves = args.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        let parts = halves[0].split(separator: " ").map(String.init)
        guard parts.count == 3 else { return nil }
        var alpha: String?
        if halves.count == 2 {
            let a = halves[1].split(separator: " ")
            guard a.count == 1 else { return nil }
            alpha = String(a[0])
        }
        return (parts, alpha)
    }

    private static func alphaValue(_ s: String?) -> Double? {
        guard let s else { return 1 }
        switch length(s, percent: true) {
        case .number(let v)?: return min(max(v, 0), 1)
        case .percent(let p)?: return min(max(p / 100, 0), 1)
        default: return nil
        }
    }

    private static func rgbFunction(_ args: String) -> RGBA? {
        guard let (parts, alphaRaw) = colorArguments(args), let a = alphaValue(alphaRaw) else { return nil }
        var c: [Double] = []
        for p in parts {
            var s = Scanner(p)
            guard let v = s.number() else { return nil }
            if s.consume("%") {
                c.append(v / 100)
            } else {
                c.append(v / 255)
            }
            guard s.atEnd else { return nil }
        }
        let clamp = { (v: Double) in min(max(v, 0), 1) }
        return RGBA(r: clamp(c[0]), g: clamp(c[1]), b: clamp(c[2]), a: a)
    }

    private static func hslFunction(_ args: String) -> RGBA? {
        guard let (parts, alphaRaw) = colorArguments(args), let a = alphaValue(alphaRaw) else { return nil }
        let commas = args.contains(",")
        var hs = Scanner(parts[0])
        guard var h = hs.number() else { return nil }
        let units: [(String, Double)] = [("deg", 1), ("grad", 0.9), ("rad", 180 / .pi), ("turn", 360)]
        if let unit = units.first(where: { hs.consume(caseInsensitive: $0.0) }) { h *= unit.1 }
        guard hs.atEnd else { return nil }
        func fraction(_ p: String) -> Double? {
            var s = Scanner(p)
            guard let v = s.number() else { return nil }
            let isPercent = s.consume("%")
            guard s.atEnd, isPercent || !commas else { return nil }
            return min(max(v / 100, 0), 1)
        }
        guard let sat = fraction(parts[1]), let light = fraction(parts[2]) else { return nil }
        h = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func hue(_ t0: Double, _ m1: Double, _ m2: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t * 6 < 1 { return m1 + (m2 - m1) * t * 6 }
            if t * 2 < 1 { return m2 }
            if t * 3 < 2 { return m1 + (m2 - m1) * (2.0 / 3 - t) * 6 }
            return m1
        }
        let m2 = light <= 0.5 ? light * (sat + 1) : light + sat - light * sat
        let m1 = light * 2 - m2
        return RGBA(r: hue(h + 1.0 / 3, m1, m2), g: hue(h, m1, m2), b: hue(h - 1.0 / 3, m1, m2), a: a)
    }

    // MARK: Transforms

    /// A `transform`/`gradientTransform`/`patternTransform` list; empty means identity.
    static func transform(_ raw: String) -> CGAffineTransform? {
        var s = Scanner(raw)
        var result = CGAffineTransform.identity
        s.skipSpace()
        var first = true
        while !s.atEnd {
            if !first { s.skipCommaSpace() }
            first = false
            guard let name = s.identifier() else { return nil }
            s.skipSpace()
            guard s.consume("(") else { return nil }
            var args: [Double] = []
            s.skipSpace()
            while !s.consume(")") {
                guard let v = s.number() else { return nil }
                args.append(v)
                s.skipCommaSpace()
            }
            let t: CGAffineTransform
            switch (name, args.count) {
            case ("matrix", 6):
                t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case ("translate", 1), ("translate", 2):
                t = CGAffineTransform(translationX: args[0], y: args.count == 2 ? args[1] : 0)
            case ("scale", 1), ("scale", 2):
                t = CGAffineTransform(scaleX: args[0], y: args.count == 2 ? args[1] : args[0])
            case ("rotate", 1):
                t = CGAffineTransform(rotationAngle: args[0] * .pi / 180)
            case ("rotate", 3):
                t = CGAffineTransform(translationX: args[1], y: args[2])
                    .rotated(by: args[0] * .pi / 180)
                    .translatedBy(x: -args[1], y: -args[2])
            case ("skewX", 1):
                t = CGAffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1):
                t = CGAffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                return nil
            }
            // "A B" applies B first, then A.
            result = t.concatenating(result)
            s.skipSpace()
        }
        return result
    }

    // MARK: Data URIs

    /// The decoded bytes of a `data:image/(png|jpeg|gif|webp);base64,` URI.
    static func imageData(_ raw: String) -> Data? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/gif;base64,", "data:image/webp;base64,"]
        guard let prefix = prefixes.first(where: { t.lowercased().hasPrefix($0) }) else { return nil }
        let body = t.dropFirst(prefix.count)
        guard body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" || $0 == " ") }) else { return nil }
        let compact = body.filter { $0 != " " }
        return Data(base64Encoded: String(compact) + String(repeating: "=", count: (4 - compact.count % 4) % 4))
    }

    // MARK: Scanner

    /// A byte scanner for SVG's number-list grammars.
    struct Scanner {
        let b: [UInt8]
        var i = 0

        init(_ s: String) { b = Array(s.utf8) }
        init(_ s: Substring) { b = Array(s.utf8) }

        var atEnd: Bool { i >= b.count }

        func peek() -> UInt8? { i < b.count ? b[i] : nil }

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }

        mutating func skipSpace() {
            while let c = peek(), Self.isSpace(c) { i += 1 }
        }

        /// Whitespace with at most one comma in it.
        mutating func skipCommaSpace() {
            skipSpace()
            if peek() == UInt8(ascii: ",") {
                i += 1
                skipSpace()
            }
        }

        mutating func consume(_ literal: String) -> Bool {
            let l = Array(literal.utf8)
            guard i + l.count <= b.count, Array(b[i..<i + l.count]) == l else { return false }
            i += l.count
            return true
        }

        mutating func consume(caseInsensitive literal: String) -> Bool {
            let l = Array(literal.lowercased().utf8)
            guard i + l.count <= b.count else { return false }
            for k in 0..<l.count {
                var c = b[i + k]
                if c >= 0x41, c <= 0x5A { c += 0x20 }
                if c != l[k] { return false }
            }
            i += l.count
            return true
        }

        mutating func identifier() -> String? {
            let start = i
            while let c = peek(), (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { i += 1 }
            return i > start ? String(decoding: b[start..<i], as: UTF8.self) : nil
        }

        /// An SVG/CSS number: `[+-]? (digits [. digits?] | . digits) ([eE] [+-]? digits)?`.
        mutating func number() -> Double? {
            let start = i
            if let c = peek(), c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { i += 1 }
            var digits = 0
            while let c = peek(), c >= 0x30, c <= 0x39 { i += 1; digits += 1 }
            if peek() == UInt8(ascii: ".") {
                let dot = i
                i += 1
                var frac = 0
                while let c = peek(), c >= 0x30, c <= 0x39 { i += 1; frac += 1 }
                // "1." isn't a CSS number; leave the dot (it may start the next number in path data).
                if frac == 0 {
                    i = dot
                }
                digits += frac
            }
            guard digits > 0 else {
                i = start
                return nil
            }
            if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                var k = i + 1
                if k < b.count, b[k] == UInt8(ascii: "+") || b[k] == UInt8(ascii: "-") { k += 1 }
                if k < b.count, b[k] >= 0x30, b[k] <= 0x39 {
                    i = k
                    while let c = peek(), c >= 0x30, c <= 0x39 { i += 1 }
                }
            }
            guard let v = Double(String(decoding: b[start..<i], as: UTF8.self)), v.isFinite else {
                i = start
                return nil
            }
            return v
        }

        /// An arc flag: a single `0` or `1`, which may run into the next number.
        mutating func flag() -> Bool? {
            guard let c = peek(), c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else { return nil }
            i += 1
            return c == UInt8(ascii: "1")
        }
    }

    // MARK: Named colours

    /// The 148 CSS named colours.
    static let namedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF,
        "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF,
        "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9,
        "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F,
        "darkorange": 0xFF8C00, "darkorchid": 0x9932CC, "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F,
        "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3,
        "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1E90FF,
        "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22, "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC,
        "ghostwhite": 0xF8F8FF, "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000,
        "greenyellow": 0xADFF2F, "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
        "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA, "lavenderblush": 0xFFF0F5,
        "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6, "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF,
        "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3, "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1,
        "lightsalmon": 0xFFA07A, "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32, "linen": 0xFAF0E6,
        "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA, "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3,
        "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371, "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1, "moccasin": 0xFFE4B5,
        "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000, "olivedrab": 0x6B8E23,
        "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6, "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98,
        "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093, "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F,
        "pink": 0xFFC0CB, "plum": 0xDDA0DD, "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399,
        "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513, "salmon": 0xFA8072,
        "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0,
        "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF,
        "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
    ]
}
