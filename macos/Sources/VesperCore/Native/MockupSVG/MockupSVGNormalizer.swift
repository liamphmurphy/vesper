import Foundation

/// Why a mockup's CSS can't be turned into presentation attributes. The message names the rule,
/// selector or property in the server's words, so the person (or agent) can fix the source.
public struct MockupSVGNormalizeError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(message: String) { self.message = message }

    public var description: String { message }
}

/// Rewrites simple CSS (`<style>` rules with type, class, id and `*` selectors, and `style`
/// attributes) into presentation attributes, then removes every `<style>` element and `class` and
/// `style` attribute, so CSS-styled SVGs can enter mockup SVG profile v1.
///
/// This is a port of the server's `NormalizeMockupSVG` (`server/internal/artifacts/mockup_normalize.go`):
/// the same selectors, specificity, source order, `!important`, ignored properties and refusals.
/// Change both together; the shared corpus in `testdata/mockup-svg/normalize` and
/// `normalize-reject` checks each against the same fixtures. The server splices the source text;
/// this works on `MockupSVGTree`, so a rewritten file is re-serialized (double quotes, `<x/>` for an
/// empty element). A file with no CSS, or one the tree can't parse, comes back as it was, so the
/// profile check that runs next reports it.
public enum MockupSVGNormalizer {
    public static func normalize(_ source: String) throws(MockupSVGNormalizeError) -> String {
        guard var tree = try? MockupSVGTree.parse(source) else { return source }
        var css = MockupSVGCSS(strict: true)
        guard try css.apply(to: &tree) else { return source }
        return tree.serialized()
    }
}

/// The CSS cascade shared by `MockupSVGNormalizer` and `MockupSVGSimplifier`.
///
/// Strict mode is the normalizer: the first CSS with no single conversion throws, naming the rule.
/// Lenient mode is the simplifier: that CSS is dropped instead and named in `dropped`, and
/// descendant and child combinators, which a static tree can match, are applied too.
struct MockupSVGCSS {
    typealias Failure = MockupSVGNormalizeError

    /// The CSS properties that become presentation attributes, in the order new attributes are
    /// appended (`mockupPresentationProps` on the server).
    static let presentationProps = [
        "fill", "fill-opacity", "fill-rule",
        "stroke", "stroke-width", "stroke-opacity", "stroke-dasharray", "stroke-dashoffset",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
        "opacity", "color", "display", "visibility",
        "clip-path", "clip-rule", "mask",
        "marker-start", "marker-mid", "marker-end",
        "stop-color", "stop-opacity",
        "font-family", "font-size", "font-weight", "font-style",
        "text-anchor", "dominant-baseline", "letter-spacing", "text-decoration",
    ]
    static let presentationPropSet = Set(presentationProps)

    let strict: Bool
    private(set) var dropped: [String] = []
    /// Source order of kept declarations, across every stylesheet and then the style attributes.
    private var order = 0

    init(strict: Bool) { self.strict = strict }

    /// Throws in strict mode; otherwise records what is dropped and lets the caller skip it.
    private mutating func reject(_ message: String, dropping label: String) throws(Failure) {
        if strict { throw Failure(message: message) }
        drop(label)
    }

    private mutating func drop(_ label: String) {
        if !dropped.contains(label) { dropped.append(label) }
    }

    // MARK: Document

    /// Applies the cascade to `tree`; false when it has no CSS to apply (and so wasn't touched).
    mutating func apply(to tree: inout MockupSVGTree) throws(Failure) -> Bool {
        var sheets: [String] = []
        var hasClassOrStyle = false
        Self.scan(tree.root, sheets: &sheets, hasClassOrStyle: &hasClassOrStyle)
        if sheets.isEmpty, !hasClassOrStyle { return false }
        var rules: [Rule] = []
        for s in sheets { rules += try parseStylesheet(s) }
        var chain: [ElementInfo] = []
        try rewrite(&tree.root, rules: rules, chain: &chain)
        return true
    }

    private static func scan(_ n: MockupSVGNode, sheets: inout [String], hasClassOrStyle: inout Bool) {
        if MockupSVGProfile.ignoredElements.contains(n.localName) { return }
        if n.localName == "style" {
            sheets.append(n.children.filter { $0.kind == .text || $0.kind == .cdata }.map(\.text).joined())
            return
        }
        if n.attributes.contains(where: { $0.name == "class" || $0.name == "style" }) { hasClassOrStyle = true }
        for c in n.children where c.isElement { scan(c, sheets: &sheets, hasClassOrStyle: &hasClassOrStyle) }
    }

    private mutating func rewrite(_ n: inout MockupSVGNode, rules: [Rule], chain: inout [ElementInfo]) throws(Failure) {
        chain.append(ElementInfo(local: n.localName, id: n.attribute("id") ?? "", classes: Self.fields(n.attribute("class") ?? "")))
        defer { chain.removeLast() }
        let values = try cascade(n, chain: chain, rules: rules)
        Self.setAttributes(&n, values)
        var styles: [Int] = []
        for i in n.children.indices where n.children[i].isElement {
            let local = n.children[i].localName
            if MockupSVGProfile.ignoredElements.contains(local) { continue }
            if local == "style" {
                styles.append(i)
                continue
            }
            try rewrite(&n.children[i], rules: rules, chain: &chain)
        }
        for i in styles.reversed() { Self.removeChild(at: i, of: &n) }
    }

    /// Drops class and style, sets the cascaded values in place and appends the rest in
    /// `presentationProps` order.
    private static func setAttributes(_ n: inout MockupSVGNode, _ values: [String: String]) {
        var out: [MockupSVGAttribute] = []
        var done = Set<String>()
        for a in n.attributes {
            if a.name == "class" || a.name == "style" { continue }
            if let v = values[a.name] {
                done.insert(a.name)
                out.append(MockupSVGAttribute(name: a.name, value: v))
            } else {
                out.append(a)
            }
        }
        for p in presentationProps where !done.contains(p) {
            if let v = values[p] { out.append(MockupSVGAttribute(name: p, value: v)) }
        }
        n.attributes = out
    }

    /// Removes a child element, and its whole line when nothing else shares it, so no blank line
    /// is left behind (the server's `styleRemoval`).
    static func removeChild(at i: Int, of parent: inout MockupSVGNode) {
        var c = parent.children
        let before = i > 0 && c[i - 1].kind == .text ? c[i - 1].text : nil
        let after = i + 1 < c.count && c[i + 1].kind == .text ? c[i + 1].text : nil
        if let before, let nl = before.lastIndex(of: "\n"), before[before.index(after: nl)...].allSatisfy({ $0 == " " || $0 == "\t" }),
           let after, let end = after.firstIndex(of: "\n"), after[..<end].allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
            c[i - 1].text = String(before[...nl])
            c[i + 1].text = String(after[after.index(after: end)...])
            if c[i + 1].text.isEmpty { c.remove(at: i + 1) }
        }
        c.remove(at: i)
        parent.children = c
    }

    // MARK: Cascade

    struct ElementInfo {
        var local: String
        var id: String
        var classes: [String]
    }

    struct Decl {
        var prop: String
        var value: String
        var important: Bool
        var order: Int
    }

    struct Compound: Equatable {
        /// "" or "*" match any element.
        var type = ""
        var ids: [String] = []
        var classes: [String] = []

        var isEmpty: Bool { type.isEmpty && ids.isEmpty && classes.isEmpty }

        func matches(_ e: ElementInfo) -> Bool {
            if !type.isEmpty, type != "*", type != e.local { return false }
            return ids.allSatisfy { $0 == e.id } && classes.allSatisfy(e.classes.contains)
        }
    }

    enum Combinator { case descendant, child }

    /// Compounds joined by combinators; strict mode only makes one-compound selectors.
    struct Selector: Equatable {
        var compounds: [Compound]
        /// `combinators[i]` joins `compounds[i]` and `compounds[i + 1]`.
        var combinators: [Combinator]

        /// (ids, classes, types), summed over the compounds.
        var specificity: [Int] {
            compounds.reduce(into: [0, 0, 0]) { s, c in
                s[0] += c.ids.count
                s[1] += c.classes.count
                if !c.type.isEmpty, c.type != "*" { s[2] += 1 }
            }
        }

        /// `chain` is the element's ancestors from the root, then the element.
        func matches(_ chain: [ElementInfo]) -> Bool { match(compounds.count - 1, chain, chain.count - 1) }

        private func match(_ j: Int, _ chain: [ElementInfo], _ k: Int) -> Bool {
            guard compounds[j].matches(chain[k]) else { return false }
            if j == 0 { return true }
            switch combinators[j - 1] {
            case .child:
                return k > 0 && match(j - 1, chain, k - 1)
            case .descendant:
                return (0..<k).reversed().contains { match(j - 1, chain, $0) }
            }
        }
    }

    struct Rule {
        var selectors: [Selector]
        var decls: [Decl]
    }

    /// Orders competing declarations. level: 0 stylesheet, 1 style attribute, 2 stylesheet
    /// !important, 3 style attribute !important. Within a level, specificity then source order.
    private struct Weight {
        var level: Int
        var spec: [Int]
        var order: Int

        func less(_ b: Weight) -> Bool {
            if level != b.level { return level < b.level }
            if spec != b.spec { return spec.lexicographicallyPrecedes(b.spec) }
            return order < b.order
        }
    }

    /// The winning value of every property some CSS sets on the element. Presentation attributes
    /// rank below all CSS, so any CSS value wins.
    private mutating func cascade(_ n: MockupSVGNode, chain: [ElementInfo], rules: [Rule]) throws(Failure) -> [String: String] {
        var best: [String: (w: Weight, value: String)] = [:]
        func offer(_ d: Decl, _ w: Weight) {
            if let cur = best[d.prop], !cur.w.less(w) { return }
            best[d.prop] = (w, d.value)
        }
        for r in rules {
            // A selector list's specificity for an element is its most specific matching selector.
            var spec: [Int]?
            for s in r.selectors where s.matches(chain) {
                let sp = s.specificity
                if spec.map({ $0.lexicographicallyPrecedes(sp) }) ?? true { spec = sp }
            }
            guard let spec else { continue }
            for d in r.decls { offer(d, Weight(level: d.important ? 2 : 0, spec: spec, order: d.order)) }
        }
        if let style = n.attribute("style") {
            for d in try parseDeclarations(Array(style.utf8), context: "the style attribute on <\(n.localName)>") {
                offer(d, Weight(level: d.important ? 3 : 1, spec: [0, 0, 0], order: d.order))
            }
        }
        return best.mapValues(\.value)
    }

    // MARK: Parsing

    private static let ws: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A, 0x0C]

    mutating func parseStylesheet(_ text: String) throws(Failure) -> [Rule] {
        // Escapes are refused rather than decoded: the profile's checks for external URLs read
        // the attributes this CSS becomes, not the CSS. Lenient mode drops each rule that has one.
        if strict, text.contains("\\") {
            throw Failure(message: "a <style> element uses a CSS escape (\\), which can't be converted; write the characters themselves")
        }
        let css = try stripComments(Array(text.utf8))
        var rules: [Rule] = []
        var i = 0
        while true {
            i = Self.skip(Self.ws, css, i)
            // HTML comment markers are allowed around a stylesheet and mean nothing.
            if Self.starts(css, i, "<!--") { i += 4 }
            if Self.starts(css, i, "-->") { i += 3 }
            i = Self.skip(Self.ws, css, i)
            if i >= css.count { return rules }
            if css[i] == UInt8(ascii: "@") {
                let stop: Set<UInt8> = Self.ws.union([UInt8(ascii: "{"), UInt8(ascii: ";"), UInt8(ascii: "(")])
                let end = css[i...].firstIndex(where: stop.contains) ?? css.count
                let name = Self.string(css[i..<end])
                try reject("the <style> at-rule \(Self.quote(name)) can't be converted; mockups can't use at-rules, so put the properties on the elements instead",
                           dropping: "CSS at-rule '\(name)'")
                i = Self.skipAtRule(css, i)
                continue
            }
            guard let open = css[i...].firstIndex(of: UInt8(ascii: "{")) else {
                let rest = Self.collapse(Self.string(css[i...]))
                try reject("the <style> text \(Self.quote(rest)) isn't a rule (selectors { declarations })", dropping: "CSS text '\(rest)'")
                return rules
            }
            let selText = Self.collapse(Self.string(css[i..<open]))
            if let bad = css[i..<open].firstIndex(where: { $0 == UInt8(ascii: "}") || $0 == UInt8(ascii: ";") }) {
                try reject("the <style> text \(Self.quote(selText)) isn't a rule (selectors { declarations })", dropping: "CSS text '\(selText)'")
                i = bad + 1
                continue
            }
            let close: Int
            do {
                close = try Self.findBlockEnd(css, open + 1, selText)
            } catch {
                try reject(error.message, dropping: "CSS rule '\(selText)'")
                i = Self.skipBlock(css, open)
                continue
            }
            if !strict, css[i...close].contains(UInt8(ascii: "\\")) {
                drop("CSS rule '\(selText)'")
                i = close + 1
                continue
            }
            let selectors = try parseSelectorList(selText)
            if !selectors.isEmpty {
                let decls = try parseDeclarations(Array(css[(open + 1)..<close]), context: "the <style> rule \(Self.quoteCSS(selText))")
                rules.append(Rule(selectors: selectors, decls: decls))
            }
            i = close + 1
        }
    }

    private mutating func stripComments(_ css: [UInt8]) throws(Failure) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(css.count)
        var i = 0
        while i < css.count {
            if Self.starts(css, i, "/*") {
                guard let end = Self.find(css, "*/", from: i + 2) else {
                    try reject("a <style> element has an unterminated /* comment", dropping: "unterminated CSS comment")
                    return out
                }
                out.append(0x20)
                i = end + 2
            } else {
                out.append(css[i])
                i += 1
            }
        }
        return out
    }

    /// The index of the } closing the block opened before `i`, skipping quoted strings and
    /// refusing nested blocks.
    private static func findBlockEnd(_ css: [UInt8], _ start: Int, _ selText: String) throws(Failure) -> Int {
        var quote: UInt8 = 0
        var i = start
        while i < css.count {
            let c = css[i]
            if quote != 0 {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "{") {
                throw Failure(message: "the <style> rule \(Self.quote(selText)) nests rules, which can't be converted; write each rule at the top level with a simple selector")
            } else if c == UInt8(ascii: "}") {
                return i
            }
            i += 1
        }
        throw Failure(message: "the <style> rule \(Self.quote(selText)) is missing its closing }")
    }

    /// The index just past the block opened at `open`, nested blocks included.
    private static func skipBlock(_ css: [UInt8], _ open: Int) -> Int {
        var depth = 0
        var quote: UInt8 = 0
        var i = open
        while i < css.count {
            let c = css[i]
            if quote != 0 {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return css.count
    }

    /// The index just past an at-rule: its `;` statement end or its block.
    private static func skipAtRule(_ css: [UInt8], _ start: Int) -> Int {
        var quote: UInt8 = 0
        var depth = 0
        var i = start
        while i < css.count {
            let c = css[i]
            if quote != 0 {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "(") {
                depth += 1
            } else if c == UInt8(ascii: ")") {
                depth = max(depth - 1, 0)
            } else if depth == 0, c == UInt8(ascii: ";") {
                return i + 1
            } else if depth == 0, c == UInt8(ascii: "{") {
                return skipBlock(css, i)
            }
            i += 1
        }
        return css.count
    }

    mutating func parseSelectorList(_ list: String) throws(Failure) -> [Selector] {
        var out: [Selector] = []
        for part in Self.splitOutside(Array(list.utf8), UInt8(ascii: ",")) {
            let sel = Self.collapse(Self.string(part))
            if sel.isEmpty {
                try reject("the <style> rule \(Self.quote(list)) has an empty selector", dropping: "CSS rule '\(list)'")
                continue
            }
            do {
                out.append(try parseSelector(sel))
            } catch {
                try reject(error.message, dropping: "CSS rule '\(sel)'")
            }
        }
        return out
    }

    private static func isIdentByte(_ c: UInt8) -> Bool {
        c == UInt8(ascii: "-") || c == UInt8(ascii: "_") || c >= 0x80
            || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
    }

    /// Parses one collapsed selector. Strict mode refuses combinators with the server's messages.
    func parseSelector(_ sel: String) throws(Failure) -> Selector {
        let fix = "which can't be converted; put the properties on the elements instead"
        let s = Array(sel.utf8)
        var i = 0
        func ident() -> String {
            let j = s[i...].firstIndex { !Self.isIdentByte($0) } ?? s.count
            defer { i = j }
            return Self.string(s[i..<j])
        }
        func compoundStart() -> Compound {
            var c = Compound()
            if i < s.count, s[i] == UInt8(ascii: "*") {
                c.type = "*"
                i += 1
            } else if i < s.count, Self.isIdentByte(s[i]) {
                c.type = ident()
            }
            return c
        }
        let malformed = Failure(message: "the <style> rule \(Self.quote(sel)) has a malformed selector")
        var compounds: [Compound] = []
        var combinators: [Combinator] = []
        var c = compoundStart()
        while i < s.count {
            let ch = s[i]
            switch ch {
            case UInt8(ascii: "."), UInt8(ascii: "#"):
                i += 1
                let name = ident()
                if name.isEmpty { throw malformed }
                if ch == UInt8(ascii: ".") { c.classes.append(name) } else { c.ids.append(name) }
            case UInt8(ascii: " "), UInt8(ascii: ">"):
                var j = i
                while j < s.count, s[j] == UInt8(ascii: " ") { j += 1 }
                let combinator: Combinator
                if ch == UInt8(ascii: " ") {
                    if j < s.count, [UInt8(ascii: ">"), UInt8(ascii: "+"), UInt8(ascii: "~")].contains(s[j]) {
                        i = j
                        continue
                    }
                    if strict { throw Failure(message: "the <style> rule \(Self.quote(sel)) uses a descendant selector, \(fix)") }
                    combinator = .descendant
                    i = j
                } else {
                    if strict { throw Failure(message: "the <style> rule \(Self.quote(sel)) uses a child combinator (>), \(fix)") }
                    combinator = .child
                    i += 1
                    while i < s.count, s[i] == UInt8(ascii: " ") { i += 1 }
                }
                guard !c.isEmpty, i < s.count else { throw malformed }
                compounds.append(c)
                combinators.append(combinator)
                c = compoundStart()
            case UInt8(ascii: "+"), UInt8(ascii: "~"):
                throw Failure(message: "the <style> rule \(Self.quote(sel)) uses a sibling combinator (\(Character(Unicode.Scalar(ch)))), \(fix)")
            case UInt8(ascii: ":"):
                var j = i + 1
                var kind = "pseudo-class"
                if j < s.count, s[j] == UInt8(ascii: ":") {
                    j += 1
                    kind = "pseudo-element"
                }
                while j < s.count, Self.isIdentByte(s[j]) { j += 1 }
                throw Failure(message: "the <style> rule \(Self.quote(sel)) uses the \(kind) \(Self.quote(Self.string(s[i..<j]))), \(fix)")
            case UInt8(ascii: "["):
                throw Failure(message: "the <style> rule \(Self.quote(sel)) uses an attribute selector, \(fix)")
            case UInt8(ascii: "&"):
                throw Failure(message: "the <style> rule \(Self.quote(sel)) uses nesting (&), \(fix)")
            case UInt8(ascii: "|"):
                throw Failure(message: "the <style> rule \(Self.quote(sel)) uses a namespace selector, \(fix)")
            default:
                throw Failure(message: "the <style> rule \(Self.quote(sel)) has a selector that can't be converted; use a type, .class, #id or * selector")
            }
        }
        if c.isEmpty { throw malformed }
        compounds.append(c)
        return Selector(compounds: compounds, combinators: combinators)
    }

    /// Parses "prop: value; …". `context` names where the declarations came from, for messages.
    /// Each kept declaration takes the next source order.
    mutating func parseDeclarations(_ block: [UInt8], context: String) throws(Failure) -> [Decl] {
        if strict, block.contains(UInt8(ascii: "\\")) {
            throw Failure(message: "\(context) uses a CSS escape (\\), which can't be converted; write the characters themselves")
        }
        var out: [Decl] = []
        for part in Self.splitOutside(block, UInt8(ascii: ";")) {
            let raw = Self.trim(Self.string(part))
            if raw.isEmpty { continue }
            if raw.contains("\\") {
                // Only lenient mode gets here: strict mode refused the whole block above.
                drop("CSS declaration '\(raw)'")
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else {
                try reject("\(context) has a declaration \(Self.quote(raw)) without a colon", dropping: "CSS declaration '\(raw)'")
                continue
            }
            let prop = Self.trim(String(raw[..<colon])).lowercased()
            let (value, important) = Self.splitImportant(Self.trim(String(raw[raw.index(after: colon)...])))
            if Self.ignoredProp(prop) { continue }
            if prop != "marker", !Self.presentationPropSet.contains(prop) {
                try reject("\(context) sets the property \(Self.quote(prop)), which isn't a mockup SVG presentation attribute and can't be converted; use properties like fill, stroke, opacity or font-size",
                           dropping: "CSS property '\(prop)'")
                continue
            }
            if value.isEmpty {
                try reject("\(context) gives the property \(Self.quote(prop)) no value", dropping: "CSS property '\(prop)'")
                continue
            }
            let lower = value.lowercased()
            if let fn = ["var(", "calc("].first(where: lower.contains) {
                try reject("\(context) sets \(Self.quote(prop)) to \(Self.quote(value)), which uses \(fn)) and can't be converted; write the value itself",
                           dropping: "CSS value '\(prop): \(value)'")
                continue
            }
            order += 1
            for p in prop == "marker" ? ["marker-start", "marker-mid", "marker-end"] : [prop] {
                out.append(Decl(prop: p, value: value, important: important, order: order))
            }
        }
        return out
    }

    /// Splits off a trailing `!important` (the server's `(?i)!\s*important\s*$`).
    private static func splitImportant(_ value: String) -> (String, Bool) {
        let u = Array(value.utf8)
        var end = u.count
        while end > 0, ws.contains(u[end - 1]) { end -= 1 }
        guard end >= 9, string(u[(end - 9)..<end]).lowercased() == "important" else { return (value, false) }
        var k = end - 9
        while k > 0, ws.contains(u[k - 1]) { k -= 1 }
        guard k > 0, u[k - 1] == UInt8(ascii: "!") else { return (value, false) }
        return (trim(string(u[..<(k - 1)])), true)
    }

    /// Interaction-only properties a still picture can drop without changing how it looks.
    private static func ignoredProp(_ prop: String) -> Bool {
        if ["cursor", "pointer-events", "user-select"].contains(prop) { return true }
        return prop.hasPrefix("transition") || prop.hasPrefix("-webkit-") || prop.hasPrefix("-moz-")
    }

    // MARK: Text helpers

    /// Splits on `sep` outside quotes and parentheses (url(data:…;base64,…), rgb(1, 2, 3)).
    private static func splitOutside(_ s: [UInt8], _ sep: UInt8) -> [ArraySlice<UInt8>] {
        var parts: [ArraySlice<UInt8>] = []
        var depth = 0, start = 0
        var quote: UInt8 = 0
        var i = 0
        while i < s.count {
            let c = s[i]
            if quote != 0 {
                if c == UInt8(ascii: "\\") { i += 1 } else if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "(") {
                depth += 1
            } else if c == UInt8(ascii: ")") {
                if depth > 0 { depth -= 1 }
            } else if c == sep, depth == 0 {
                parts.append(s[start..<i])
                start = i + 1
            }
            i += 1
        }
        parts.append(s[min(start, s.count)...])
        return parts
    }

    private static func string(_ b: ArraySlice<UInt8>) -> String { String(decoding: b, as: UTF8.self) }

    private static func skip(_ set: Set<UInt8>, _ s: [UInt8], _ i: Int) -> Int {
        var i = i
        while i < s.count, set.contains(s[i]) { i += 1 }
        return i
    }

    private static func starts(_ s: [UInt8], _ i: Int, _ literal: String) -> Bool {
        let l = Array(literal.utf8)
        return i + l.count <= s.count && s[i..<(i + l.count)].elementsEqual(l)
    }

    private static func find(_ s: [UInt8], _ literal: String, from: Int) -> Int? {
        var i = from
        while i < s.count {
            if starts(s, i, literal) { return i }
            i += 1
        }
        return nil
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func fields(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    static func collapse(_ s: String) -> String { fields(s).joined(separator: " ") }

    /// Go's %q for the plain text CSS can hold here.
    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The server's quoteCSS, which escapes only quotes.
    private static func quoteCSS(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
