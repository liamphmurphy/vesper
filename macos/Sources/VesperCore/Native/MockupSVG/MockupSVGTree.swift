import Foundation

/// A small, order-preserving XML tree for mockup SVGs, shared by the profile validator, the
/// native renderer and the editor's operations.
///
/// Foundation's `XMLDocument` isn't available on iOS and `XMLParser` drops attribute order, so
/// edits would reshuffle the source the person reads in Source mode. This parser keeps attribute
/// order, comments and whitespace text, and serializes back to the same text when nothing changed
/// except for quoting and entity spelling. It accepts what the server's `ValidSVG` accepts: no
/// DOCTYPE, no entity declarations, only the predefined entities and character references.
public struct MockupSVGAttribute: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MockupSVGNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case element
        case text
        case comment
        case cdata
    }

    public var kind: Kind
    /// The qualified element name as written (`svg`, `rect`), empty for non-elements.
    public var name: String
    public var attributes: [MockupSVGAttribute]
    public var children: [MockupSVGNode]
    /// The decoded content of a text, comment or CDATA node.
    public var text: String

    public init(element name: String, attributes: [MockupSVGAttribute] = [], children: [MockupSVGNode] = []) {
        self.kind = .element
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = ""
    }

    public static func text(_ value: String) -> MockupSVGNode {
        var n = MockupSVGNode(element: "")
        n.kind = .text
        n.text = value
        return n
    }

    public static func comment(_ value: String) -> MockupSVGNode {
        var n = MockupSVGNode(element: "")
        n.kind = .comment
        n.text = value
        return n
    }

    public static func cdata(_ value: String) -> MockupSVGNode {
        var n = MockupSVGNode(element: "")
        n.kind = .cdata
        n.text = value
        return n
    }

    public var isElement: Bool { kind == .element }

    /// The element name without a namespace prefix.
    public var localName: String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    public func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// Sets, replaces in place (keeping its position) or, with `nil`, removes an attribute.
    public mutating func setAttribute(_ name: String, _ value: String?) {
        if let i = attributes.firstIndex(where: { $0.name == name }) {
            if let value { attributes[i].value = value } else { attributes.remove(at: i) }
        } else if let value {
            attributes.append(MockupSVGAttribute(name: name, value: value))
        }
    }

    /// The concatenated text of this node and its descendants.
    public var textContent: String {
        switch kind {
        case .text, .cdata: return text
        case .comment: return ""
        case .element: return children.map(\.textContent).joined()
        }
    }

    public var elementChildren: [MockupSVGNode] { children.filter(\.isElement) }
}

public struct MockupSVGParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let line: Int

    public var description: String { "line \(line): \(message)" }
}

public struct MockupSVGTree: Equatable, Sendable {
    /// Nodes before the root element (the `<?xml ?>` declaration is kept separately).
    public var leading: [MockupSVGNode]
    public var root: MockupSVGNode
    /// Nodes after the root element.
    public var trailing: [MockupSVGNode]
    /// The `<?xml …?>` declaration's content, when the source had one.
    public var declaration: String?

    public init(root: MockupSVGNode, leading: [MockupSVGNode] = [], trailing: [MockupSVGNode] = [], declaration: String? = nil) {
        self.root = root
        self.leading = leading
        self.trailing = trailing
        self.declaration = declaration
    }

    public static func parse(_ source: String) throws(MockupSVGParseError) -> MockupSVGTree {
        var parser = Parser(Array(source.unicodeScalars))
        return try parser.document()
    }

    public func serialized() -> String {
        var out = ""
        if let declaration { out += "<?xml \(declaration)?>\n" }
        for n in leading { Self.write(n, into: &out) }
        Self.write(root, into: &out)
        for n in trailing { Self.write(n, into: &out) }
        return out
    }

    // MARK: Paths
    //
    // A path names an element by its child indices from the root, joined with ".": "" is the root,
    // "3" its fourth child node, "3.1" that node's second child. Indices count every child node,
    // text and comments included, so a path stays valid while only attributes change.

    public static func childPath(_ parent: String, _ index: Int) -> String {
        parent.isEmpty ? String(index) : "\(parent).\(index)"
    }

    public static func indices(of path: String) -> [Int]? {
        if path.isEmpty { return [] }
        var out: [Int] = []
        for seg in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let i = Int(seg), i >= 0 else { return nil }
            out.append(i)
        }
        return out
    }

    public static func parentPath(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let dot = path.lastIndex(of: ".") else { return "" }
        return String(path[..<dot])
    }

    public func node(at path: String) -> MockupSVGNode? {
        guard let idx = Self.indices(of: path) else { return nil }
        var n = root
        for i in idx {
            guard n.children.indices.contains(i) else { return nil }
            n = n.children[i]
        }
        return n
    }

    /// Applies `body` to the node at `path`; returns false when there is none.
    @discardableResult
    public mutating func update(at path: String, _ body: (inout MockupSVGNode) -> Void) -> Bool {
        guard let idx = Self.indices(of: path) else { return false }
        return Self.update(&root, idx[...], body)
    }

    private static func update(_ node: inout MockupSVGNode, _ idx: ArraySlice<Int>, _ body: (inout MockupSVGNode) -> Void) -> Bool {
        guard let first = idx.first else {
            body(&node)
            return true
        }
        guard node.children.indices.contains(first) else { return false }
        return update(&node.children[first], idx.dropFirst(), body)
    }

    /// Every element's path in document order, the root ("") first.
    public func elementPaths() -> [String] {
        var out: [String] = []
        func walk(_ n: MockupSVGNode, _ path: String) {
            out.append(path)
            for (i, c) in n.children.enumerated() where c.isElement {
                walk(c, Self.childPath(path, i))
            }
        }
        walk(root, "")
        return out
    }

    // MARK: Serialization

    private static func write(_ n: MockupSVGNode, into out: inout String) {
        switch n.kind {
        case .text:
            out += escapeText(n.text)
        case .comment:
            out += "<!--\(n.text)-->"
        case .cdata:
            out += "<![CDATA[\(n.text)]]>"
        case .element:
            out += "<\(n.name)"
            for a in n.attributes {
                out += " \(a.name)=\"\(escapeAttribute(a.value))\""
            }
            if n.children.isEmpty {
                out += "/>"
            } else {
                out += ">"
                for c in n.children { write(c, into: &out) }
                out += "</\(n.name)>"
            }
        }
    }

    static func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func escapeAttribute(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            case "\t": out += "&#9;"
            case "\r": out += "&#13;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

// MARK: - Parser

private struct Parser {
    let s: [Unicode.Scalar]
    var i = 0
    var line = 1

    init(_ s: [Unicode.Scalar]) { self.s = s }

    var atEnd: Bool { i >= s.count }

    func fail(_ message: String) -> MockupSVGParseError {
        MockupSVGParseError(message: message, line: line)
    }

    func peek(_ k: Int = 0) -> Unicode.Scalar? {
        i + k < s.count ? s[i + k] : nil
    }

    func starts(with literal: String) -> Bool {
        var k = i
        for ch in literal.unicodeScalars {
            guard k < s.count, s[k] == ch else { return false }
            k += 1
        }
        return true
    }

    mutating func advance(_ n: Int = 1) {
        for _ in 0..<n where i < s.count {
            if s[i] == "\n" { line += 1 }
            i += 1
        }
    }

    mutating func expect(_ literal: String) throws(MockupSVGParseError) {
        guard starts(with: literal) else { throw fail("expected \"\(literal)\"") }
        advance(literal.unicodeScalars.count)
    }

    mutating func skipSpace() {
        while let c = peek(), Self.isSpace(c) { advance() }
    }

    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\n" || c == "\t" || c == "\r"
    }

    static func isNameStart(_ c: Unicode.Scalar) -> Bool {
        c == ":" || c == "_" || (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c.value >= 0xC0
    }

    static func isNameChar(_ c: Unicode.Scalar) -> Bool {
        isNameStart(c) || c == "-" || c == "." || (c >= "0" && c <= "9") || c.value == 0xB7
    }

    mutating func name() throws(MockupSVGParseError) -> String {
        guard let c = peek(), Self.isNameStart(c) else { throw fail("expected a name") }
        var out = String.UnicodeScalarView()
        while let c = peek(), Self.isNameChar(c) {
            out.append(c)
            advance()
        }
        return String(out)
    }

    mutating func document() throws(MockupSVGParseError) -> MockupSVGTree {
        if s.first?.value == 0xFEFF { i = 1 }
        var declaration: String?
        if starts(with: "<?xml") , let next = peek(5), Self.isSpace(next) || next == "?" {
            advance(5)
            let start = i
            while !atEnd, !starts(with: "?>") { advance() }
            guard !atEnd else { throw fail("unterminated XML declaration") }
            declaration = String(String.UnicodeScalarView(s[start..<i])).trimmingCharacters(in: .whitespaces)
            advance(2)
        }
        var leading: [MockupSVGNode] = []
        var root: MockupSVGNode?
        var trailing: [MockupSVGNode] = []
        while true {
            let wsStart = i
            skipSpace()
            let ws = String(String.UnicodeScalarView(s[wsStart..<i]))
            if !ws.isEmpty, root == nil, !leading.isEmpty || declaration != nil { leading.append(.text(ws)) }
            if !ws.isEmpty, root != nil { trailing.append(.text(ws)) }
            if atEnd { break }
            if starts(with: "<!--") {
                let c = try comment()
                if root == nil { leading.append(c) } else { trailing.append(c) }
            } else if starts(with: "<?") {
                throw fail("processing instructions aren't allowed")
            } else if starts(with: "<!") {
                throw fail("a DOCTYPE or declaration isn't allowed")
            } else if starts(with: "<") {
                guard root == nil else { throw fail("only one root element is allowed") }
                root = try element()
            } else {
                throw fail("text outside the root element")
            }
        }
        // Whitespace between the declaration and the root is dropped; serialized() writes a newline.
        if declaration != nil, leading.first?.kind == .text { leading.removeFirst() }
        guard let root else { throw fail("no root element") }
        if trailing.last?.kind == .text, trailing.last?.text.allSatisfy(\.isWhitespace) == true {
            // Keep one trailing newline at most, as editors write.
            trailing.removeLast()
            trailing.append(.text("\n"))
        }
        return MockupSVGTree(root: root, leading: leading, trailing: trailing, declaration: declaration)
    }

    mutating func comment() throws(MockupSVGParseError) -> MockupSVGNode {
        try expect("<!--")
        let start = i
        while !atEnd, !starts(with: "-->") { advance() }
        guard !atEnd else { throw fail("unterminated comment") }
        let body = String(String.UnicodeScalarView(s[start..<i]))
        advance(3)
        return .comment(body)
    }

    mutating func element() throws(MockupSVGParseError) -> MockupSVGNode {
        try expect("<")
        let tag = try name()
        var node = MockupSVGNode(element: tag)
        var seen = Set<String>()
        while true {
            let hadSpace = peek().map(Self.isSpace) ?? false
            skipSpace()
            if starts(with: "/>") {
                advance(2)
                return node
            }
            if starts(with: ">") {
                advance()
                break
            }
            guard hadSpace else { throw fail("expected whitespace before an attribute in <\(tag)>") }
            let attr = try name()
            guard seen.insert(attr).inserted else { throw fail("duplicate attribute \(attr) on <\(tag)>") }
            skipSpace()
            try expect("=")
            skipSpace()
            guard let q = peek(), q == "\"" || q == "'" else { throw fail("attribute values must be quoted") }
            advance()
            var value = ""
            while let c = peek(), c != q {
                if c == "<" { throw fail("\"<\" isn't allowed in an attribute value") }
                if c == "&" {
                    value.unicodeScalars.append(contentsOf: try entity().unicodeScalars)
                } else {
                    // Attribute-value normalization: literal whitespace becomes a space.
                    value.unicodeScalars.append(c == "\n" || c == "\t" || c == "\r" ? " " : c)
                    advance()
                }
            }
            guard !atEnd else { throw fail("unterminated attribute value") }
            advance()
            node.attributes.append(MockupSVGAttribute(name: attr, value: value))
        }
        // Content
        var text = ""
        func flush(_ node: inout MockupSVGNode) {
            if !text.isEmpty {
                node.children.append(.text(text))
                text = ""
            }
        }
        while true {
            guard !atEnd else { throw fail("<\(tag)> isn't closed") }
            if starts(with: "</") {
                flush(&node)
                advance(2)
                let close = try name()
                guard close == tag else { throw fail("</\(close)> doesn't close <\(tag)>") }
                skipSpace()
                try expect(">")
                return node
            } else if starts(with: "<!--") {
                flush(&node)
                node.children.append(try comment())
            } else if starts(with: "<![CDATA[") {
                flush(&node)
                advance(9)
                let start = i
                while !atEnd, !starts(with: "]]>") { advance() }
                guard !atEnd else { throw fail("unterminated CDATA section") }
                node.children.append(.cdata(String(String.UnicodeScalarView(s[start..<i]))))
                advance(3)
            } else if starts(with: "<?") {
                throw fail("processing instructions aren't allowed")
            } else if starts(with: "<!") {
                throw fail("declarations aren't allowed inside elements")
            } else if starts(with: "<") {
                flush(&node)
                node.children.append(try element())
            } else if peek() == "&" {
                text.unicodeScalars.append(contentsOf: try entity().unicodeScalars)
            } else {
                if peek() == "\r" {
                    // End-of-line normalization.
                    advance()
                    if peek() != "\n" { text.unicodeScalars.append("\n") }
                    continue
                }
                text.unicodeScalars.append(peek()!)
                advance()
            }
        }
    }

    mutating func entity() throws(MockupSVGParseError) -> String {
        try expect("&")
        let start = i
        while let c = peek(), c != ";" {
            guard i - start < 12 else { throw fail("malformed entity reference") }
            advance()
        }
        guard !atEnd else { throw fail("unterminated entity reference") }
        let body = String(String.UnicodeScalarView(s[start..<i]))
        advance()
        switch body {
        case "lt": return "<"
        case "gt": return ">"
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        default:
            var code: UInt32?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                code = UInt32(body.dropFirst(2), radix: 16)
            } else if body.hasPrefix("#") {
                code = UInt32(body.dropFirst(), radix: 10)
            }
            guard let code, let scalar = Unicode.Scalar(code), code != 0 else {
                throw fail("undefined entity &\(body);")
            }
            return String(Character(scalar))
        }
    }
}
