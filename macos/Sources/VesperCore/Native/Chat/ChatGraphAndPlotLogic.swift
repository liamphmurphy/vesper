import CoreGraphics
import Foundation

// MARK: - Relationship Graph Block (LAZYAGENTS-326)

public struct ChatGraphNode: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var group: String?
    public var size: Double

    public init(id: String, label: String, group: String? = nil, size: Double = 1.0) {
        self.id = id
        self.label = label
        self.group = group
        self.size = size
    }
}

public struct ChatGraphEdge: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var from: String
    public var to: String
    public var label: String?
    public var directed: Bool

    public init(id: Int, from: String, to: String, label: String? = nil, directed: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.directed = directed
    }
}

public struct ChatGraphPosition: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ChatGraphSpec: Sendable, Equatable, Hashable {
    public static let maxNodes = 80
    public static let maxEdges = 250

    public var title: String?
    public var subtitle: String?
    public var nodes: [ChatGraphNode]
    public var edges: [ChatGraphEdge]
    public var groups: [String]

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        nodes: [ChatGraphNode],
        edges: [ChatGraphEdge],
        groups: [String]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.nodes = nodes
        self.edges = edges
        self.groups = groups
    }

    public static func isGraphFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "graph"
    }

    public static func parse(_ code: String) -> Result<ChatGraphSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This graph block isn't valid JSON."))
        }

        guard let rawNodes = obj["nodes"]?.arrayVal, !rawNodes.isEmpty, rawNodes.count <= maxNodes else {
            return .failure(ChatVisualizationError("A graph block needs 1 to \(maxNodes) nodes."))
        }

        var nodes: [ChatGraphNode] = []
        var nodeIDs: Set<String> = []
        var groups: [String] = []
        for (idx, raw) in rawNodes.enumerated() {
            guard let n = raw.objectVal,
                  let id = n["id"]?.trimmedString
            else {
                return .failure(ChatVisualizationError("Graph node \(idx + 1) needs an id."))
            }
            let label = n["label"]?.trimmedString ?? id
            let group = n["group"]?.trimmedString
            if let group, !groups.contains(group) { groups.append(group) }
            let size = max(0.6, min(2.4, n["size"]?.doubleVal ?? 1.0))
            if nodeIDs.insert(id).inserted {
                nodes.append(ChatGraphNode(id: id, label: label, group: group, size: size))
            }
        }

        var edges: [ChatGraphEdge] = []
        if let rawEdges = obj["edges"]?.arrayVal {
            if rawEdges.count > maxEdges {
                return .failure(ChatVisualizationError("A graph block supports at most \(maxEdges) edges."))
            }
            for (idx, raw) in rawEdges.enumerated() {
                guard let e = raw.objectVal,
                      let from = e["from"]?.trimmedString ?? e["source"]?.trimmedString,
                      let to = e["to"]?.trimmedString ?? e["target"]?.trimmedString
                else {
                    return .failure(ChatVisualizationError("Graph edge \(idx + 1) needs 'from' and 'to' node ids."))
                }
                guard nodeIDs.contains(from), nodeIDs.contains(to) else {
                    return .failure(ChatVisualizationError("Graph edge \(idx + 1) references an unknown node (\(from) → \(to))."))
                }
                let directed = e["directed"]?.boolVal ?? (obj["directed"]?.boolVal ?? false)
                edges.append(ChatGraphEdge(
                    id: idx,
                    from: from,
                    to: to,
                    label: e["label"]?.trimmedString,
                    directed: directed
                ))
            }
        }

        return .success(ChatGraphSpec(
            title: obj["title"]?.trimmedString,
            subtitle: obj["subtitle"]?.trimmedString,
            nodes: nodes,
            edges: edges,
            groups: groups
        ))
    }

    public func neighbors(of nodeID: String) -> Set<String> {
        var out: Set<String> = [nodeID]
        for edge in edges {
            if edge.from == nodeID { out.insert(edge.to) }
            if edge.to == nodeID { out.insert(edge.from) }
        }
        return out
    }

    /// Deterministic force-directed layout with label-clearance collision resolution so a 40-node
    /// graph renders cleanly without overlapping labels at default zoom.
    public func computeLayout(width: Double = 720, height: Double = 460, iterations: Int = 140) -> [String: ChatGraphPosition] {
        let n = nodes.count
        guard n > 0 else { return [:] }
        if n == 1 {
            return [nodes[0].id: ChatGraphPosition(x: width / 2, y: height / 2)]
        }

        // Golden-angle spiral initial placement (deterministic & well-spaced)
        var xs = Array(repeating: 0.0, count: n)
        var ys = Array(repeating: 0.0, count: n)
        let cx = width / 2
        let cy = height / 2
        let maxR = min(width, height) * 0.42
        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        for i in 0..<n {
            let r = maxR * sqrt(Double(i + 1) / Double(n))
            let theta = Double(i) * goldenAngle
            xs[i] = cx + r * cos(theta)
            ys[i] = cy + r * sin(theta)
        }

        var indexByID: [String: Int] = [:]
        for (i, node) in nodes.enumerated() { indexByID[node.id] = i }
        let edgePairs: [(Int, Int)] = edges.compactMap { e in
            guard let u = indexByID[e.from], let v = indexByID[e.to], u != v else { return nil }
            return (u, v)
        }

        // Scale virtual canvas area gently with node count so dense graphs stay legible.
        let area = max(width * height, Double(n) * 6_400)
        let k = sqrt(area / Double(n))
        let minLabelSepX = 68.0
        let minLabelSepY = 30.0

        var dispX = Array(repeating: 0.0, count: n)
        var dispY = Array(repeating: 0.0, count: n)
        var temp = min(width, height) * 0.14

        for _ in 0..<iterations {
            for i in 0..<n { dispX[i] = 0; dispY[i] = 0 }

            // Pairwise repulsion
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = xs[i] - xs[j]
                    let dy = ys[i] - ys[j]
                    let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                    let force = (k * k) / dist
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    dispX[i] += fx; dispY[i] += fy
                    dispX[j] -= fx; dispY[j] -= fy
                }
            }

            // Spring attraction along edges
            for (u, v) in edgePairs {
                let dx = xs[u] - xs[v]
                let dy = ys[u] - ys[v]
                let dist = max(sqrt(dx * dx + dy * dy), 0.01)
                let force = (dist * dist) / k
                let fx = (dx / dist) * force * 0.7
                let fy = (dy / dist) * force * 0.7
                dispX[u] -= fx; dispY[u] -= fy
                dispX[v] += fx; dispY[v] += fy
            }

            // Gentle gravity toward center
            for i in 0..<n {
                dispX[i] += (cx - xs[i]) * 0.08
                dispY[i] += (cy - ys[i]) * 0.08
            }

            for i in 0..<n {
                let len = max(sqrt(dispX[i] * dispX[i] + dispY[i] * dispY[i]), 0.01)
                let step = min(len, temp)
                xs[i] += (dispX[i] / len) * step
                ys[i] += (dispY[i] / len) * step
            }

            temp *= 0.965
        }

        // Dedicated label-box collision resolution pass so node labels never overlap.
        for _ in 0..<45 {
            var moved = false
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = xs[j] - xs[i]
                    let dy = ys[j] - ys[i]
                    let overlapX = minLabelSepX - abs(dx)
                    let overlapY = minLabelSepY - abs(dy)
                    if overlapX > 0 && overlapY > 0 {
                        moved = true
                        if overlapX < overlapY {
                            let push = (overlapX / 2.0) + 1.0
                            let sign = dx >= 0 ? 1.0 : -1.0
                            xs[i] -= sign * push
                            xs[j] += sign * push
                        } else {
                            let push = (overlapY / 2.0) + 1.0
                            let sign = dy >= 0 ? 1.0 : -1.0
                            ys[i] -= sign * push
                            ys[j] += sign * push
                        }
                    }
                }
            }
            if !moved { break }
        }

        // Normalize into padded viewport preserving aspect ratio and label spacing.
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? width
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? height
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let padX = 56.0
        let padY = 34.0
        let targetW = max(width - padX * 2, spanX)
        let targetH = max(height - padY * 2, spanY)
        let scale = min(1.0, min(targetW / spanX, targetH / spanY))
        let offsetX = (width - spanX * scale) / 2 - minX * scale
        let offsetY = (height - spanY * scale) / 2 - minY * scale

        var result: [String: ChatGraphPosition] = [:]
        for (i, node) in nodes.enumerated() {
            result[node.id] = ChatGraphPosition(x: xs[i] * scale + offsetX, y: ys[i] * scale + offsetY)
        }
        return result
    }
}

// MARK: - Math Function Plotter (LAZYAGENTS-327)

public indirect enum MathAST: Sendable, Equatable, Hashable {
    case number(Double)
    case variable(String)
    case unaryMinus(MathAST)
    case binary(op: MathBinaryOp, MathAST, MathAST)
    case call(name: String, args: [MathAST])

    public func evaluate(variables: [String: Double]) -> Double {
        switch self {
        case .number(let n):
            return n
        case .variable(let name):
            switch name.lowercased() {
            case "pi", "π": return Double.pi
            case "e": return M_E
            case "tau": return Double.pi * 2
            default: return variables[name] ?? variables[name.lowercased()] ?? .nan
            }
        case .unaryMinus(let inner):
            return -inner.evaluate(variables: variables)
        case .binary(let op, let lhs, let rhs):
            let l = lhs.evaluate(variables: variables)
            let r = rhs.evaluate(variables: variables)
            switch op {
            case .add: return l + r
            case .sub: return l - r
            case .mul: return l * r
            case .div: return r == 0 ? .nan : l / r
            case .pow: return Foundation.pow(l, r)
            }
        case .call(let name, let args):
            let vals = args.map { $0.evaluate(variables: variables) }
            guard let a = vals.first else { return .nan }
            switch name.lowercased() {
            case "sin": return Foundation.sin(a)
            case "cos": return Foundation.cos(a)
            case "tan": return Foundation.tan(a)
            case "asin": return Foundation.asin(a)
            case "acos": return Foundation.acos(a)
            case "atan": return Foundation.atan(a)
            case "sinh": return Foundation.sinh(a)
            case "cosh": return Foundation.cosh(a)
            case "tanh": return Foundation.tanh(a)
            case "sqrt": return a < 0 ? .nan : Foundation.sqrt(a)
            case "abs": return abs(a)
            case "ln": return a <= 0 ? .nan : Foundation.log(a)
            case "log", "log10": return a <= 0 ? .nan : Foundation.log10(a)
            case "log2": return a <= 0 ? .nan : Foundation.log2(a)
            case "exp": return Foundation.exp(a)
            case "floor": return Foundation.floor(a)
            case "ceil": return Foundation.ceil(a)
            case "round": return Foundation.round(a)
            case "sign": return a > 0 ? 1 : (a < 0 ? -1 : 0)
            case "min": return vals.count >= 2 ? Swift.min(vals[0], vals[1]) : .nan
            case "max": return vals.count >= 2 ? Swift.max(vals[0], vals[1]) : .nan
            default: return .nan
            }
        }
    }
}

public enum MathBinaryOp: String, Sendable, Equatable, Hashable {
    case add = "+"
    case sub = "-"
    case mul = "*"
    case div = "/"
    case pow = "^"
}

/// Safe pure-Swift recursive-descent mathematical expression parser. Never executes JavaScript.
public enum MathExpressionParser {
    private static let knownFunctions: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan",
        "sinh", "cosh", "tanh", "sqrt", "abs", "ln", "log", "log10", "log2",
        "exp", "floor", "ceil", "round", "sign", "min", "max",
    ]
    private static let binaryFunctions: Set<String> = ["min", "max"]

    private enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)
        case lparen
        case rparen
        case comma
    }

    public static func parse(_ source: String) -> Result<MathAST, ChatVisualizationError> {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ChatVisualizationError("Expression is empty."))
        }
        guard trimmed.count <= 256 else {
            return .failure(ChatVisualizationError("Expression is too long."))
        }
        // Reject obvious non-math/JS syntax characters early
        for ch in trimmed {
            if ch == ";" || ch == "{" || ch == "}" || ch == "[" || ch == "]" || ch == "=" || ch == "\"" || ch == "'" || ch == "`" {
                return .failure(ChatVisualizationError("Unsupported character '\(ch)' in math expression."))
            }
        }

        let tokens: [Token]
        switch tokenize(trimmed) {
        case .success(let t): tokens = t
        case .failure(let e): return .failure(e)
        }
        guard !tokens.isEmpty else {
            return .failure(ChatVisualizationError("Expression is empty."))
        }

        var parser = Parser(tokens: tokens)
        switch parser.parseExpression() {
        case .failure(let e):
            return .failure(e)
        case .success(let ast):
            if parser.index < tokens.count {
                return .failure(ChatVisualizationError("Unexpected token near end of expression."))
            }
            return .success(ast)
        }
    }

    private static func tokenize(_ s: String) -> Result<[Token], ChatVisualizationError> {
        let chars = Array(s)
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isNumber || (ch == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var num = ""
                var hasDot = false
                while i < chars.count && (chars[i].isNumber || (!hasDot && chars[i] == ".")) {
                    if chars[i] == "." { hasDot = true }
                    num.append(chars[i])
                    i += 1
                }
                if i < chars.count && (chars[i] == "e" || chars[i] == "E") {
                    let save = i
                    var expPart = String(chars[i])
                    i += 1
                    if i < chars.count && (chars[i] == "+" || chars[i] == "-") {
                        expPart.append(chars[i]); i += 1
                    }
                    var digits = 0
                    while i < chars.count && chars[i].isNumber {
                        expPart.append(chars[i]); i += 1; digits += 1
                    }
                    if digits > 0 { num += expPart } else { i = save }
                }
                guard let val = Double(num), val.isFinite else {
                    return .failure(ChatVisualizationError("Invalid number '\(num)'."))
                }
                out.append(.number(val))
                continue
            }
            if ch.isLetter || ch == "_" || ch == "π" {
                var ident = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "π") {
                    ident.append(chars[i])
                    i += 1
                }
                out.append(.ident(ident))
                continue
            }
            switch ch {
            case "+", "-", "*", "/", "^":
                out.append(.op(ch)); i += 1
            case "(":
                out.append(.lparen); i += 1
            case ")":
                out.append(.rparen); i += 1
            case ",":
                out.append(.comma); i += 1
            default:
                return .failure(ChatVisualizationError("Unexpected character '\(ch)'."))
            }
        }
        return .success(out)
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var depth = 0

        mutating func parseExpression() -> Result<MathAST, ChatVisualizationError> {
            parseAdditive()
        }

        mutating func parseAdditive() -> Result<MathAST, ChatVisualizationError> {
            guard case .success(var left) = parseMultiplicative() else {
                return parseMultiplicativeError()
            }
            while index < tokens.count {
                if case .op(let ch) = tokens[index], ch == "+" || ch == "-" {
                    index += 1
                    switch parseMultiplicative() {
                    case .success(let right):
                        left = .binary(op: ch == "+" ? .add : .sub, left, right)
                    case .failure(let e):
                        return .failure(e)
                    }
                } else {
                    break
                }
            }
            return .success(left)
        }

        private mutating func parseMultiplicativeError() -> Result<MathAST, ChatVisualizationError> {
            .failure(ChatVisualizationError("Invalid expression syntax."))
        }

        mutating func parseMultiplicative() -> Result<MathAST, ChatVisualizationError> {
            switch parseUnary() {
            case .failure(let e): return .failure(e)
            case .success(var left):
                while index < tokens.count {
                    if case .op(let ch) = tokens[index], ch == "*" || ch == "/" {
                        index += 1
                        switch parseUnary() {
                        case .success(let right):
                            left = .binary(op: ch == "*" ? .mul : .div, left, right)
                        case .failure(let e):
                            return .failure(e)
                        }
                    } else if canStartImplicitFactor(tokens[index]) {
                        switch parseUnary() {
                        case .success(let right):
                            left = .binary(op: .mul, left, right)
                        case .failure(let e):
                            return .failure(e)
                        }
                    } else {
                        break
                    }
                }
                return .success(left)
            }
        }

        private func canStartImplicitFactor(_ token: Token) -> Bool {
            switch token {
            case .ident, .lparen: return true
            default: return false
            }
        }

        mutating func parseUnary() -> Result<MathAST, ChatVisualizationError> {
            guard index < tokens.count else {
                return .failure(ChatVisualizationError("Unexpected end of expression."))
            }
            if case .op("-") = tokens[index] {
                index += 1
                return parseUnary().map { .unaryMinus($0) }
            }
            if case .op("+") = tokens[index] {
                index += 1
                return parseUnary()
            }
            return parsePower()
        }

        mutating func parsePower() -> Result<MathAST, ChatVisualizationError> {
            switch parsePrimary() {
            case .failure(let e): return .failure(e)
            case .success(let base):
                if index < tokens.count, case .op("^") = tokens[index] {
                    index += 1
                    // Right-associative: 2^3^2 == 2^(3^2)
                    return parseUnary().map { .binary(op: .pow, base, $0) }
                }
                return .success(base)
            }
        }

        mutating func parsePrimary() -> Result<MathAST, ChatVisualizationError> {
            guard index < tokens.count else {
                return .failure(ChatVisualizationError("Expected a value or variable."))
            }
            depth += 1
            defer { depth -= 1 }
            if depth > 48 {
                return .failure(ChatVisualizationError("Expression nesting too deep."))
            }
            let tok = tokens[index]
            switch tok {
            case .number(let val):
                index += 1
                return .success(.number(val))
            case .ident(let name):
                index += 1
                if index < tokens.count, tokens[index] == .lparen {
                    let lower = name.lowercased()
                    guard knownFunctions.contains(lower) else {
                        return .failure(ChatVisualizationError("Unknown function '\(name)'."))
                    }
                    index += 1
                    var args: [MathAST] = []
                    if index < tokens.count, tokens[index] == .rparen {
                        return .failure(ChatVisualizationError("Function '\(name)' requires an argument."))
                    }
                    while true {
                        switch parseExpression() {
                        case .failure(let e): return .failure(e)
                        case .success(let arg): args.append(arg)
                        }
                        if index < tokens.count, tokens[index] == .comma {
                            index += 1
                            continue
                        }
                        break
                    }
                    guard index < tokens.count, tokens[index] == .rparen else {
                        return .failure(ChatVisualizationError("Missing closing ')' after '\(name)('."))
                    }
                    index += 1
                    let expectedArgs = binaryFunctions.contains(lower) ? 2 : 1
                    guard args.count == expectedArgs else {
                        return .failure(ChatVisualizationError("Function '\(name)' expects \(expectedArgs) argument(s)."))
                    }
                    return .success(.call(name: lower, args: args))
                }
                return .success(.variable(name))
            case .lparen:
                index += 1
                switch parseExpression() {
                case .failure(let e): return .failure(e)
                case .success(let expr):
                    guard index < tokens.count, tokens[index] == .rparen else {
                        return .failure(ChatVisualizationError("Missing closing ')'."))
                    }
                    index += 1
                    return .success(expr)
                }
            default:
                return .failure(ChatVisualizationError("Unexpected operator in expression."))
            }
        }
    }
}

public struct ChatPlotFunction: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var expr: String
    public var label: String
    public var ast: MathAST?
    public var error: String?

    public init(id: Int, expr: String, label: String, ast: MathAST?, error: String?) {
        self.id = id
        self.expr = expr
        self.label = label
        self.ast = ast
        self.error = error
    }
}

public struct ChatPlotParameter: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var value: Double
    public var min: Double
    public var max: Double
    public var step: Double

    public init(name: String, value: Double, min: Double, max: Double, step: Double) {
        self.name = name
        self.value = value
        self.min = min
        self.max = max
        self.step = step
    }
}

public struct ChatPlotSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double?
    public var yMax: Double?
    public var functions: [ChatPlotFunction]
    public var parameters: [ChatPlotParameter]

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        xMin: Double,
        xMax: Double,
        yMin: Double? = nil,
        yMax: Double? = nil,
        functions: [ChatPlotFunction],
        parameters: [ChatPlotParameter] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
        self.functions = functions
        self.parameters = parameters
    }

    public static func isPlotFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "plot"
    }

    public static func parse(_ code: String) -> Result<ChatPlotSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This plot block isn't valid JSON."))
        }

        guard let rawFuncs = obj["functions"]?.arrayVal, !rawFuncs.isEmpty, rawFuncs.count <= 8 else {
            return .failure(ChatVisualizationError("A plot block needs 1 to 8 functions."))
        }

        var xMin = -6.0
        var xMax = 6.0
        if let dom = obj["xDomain"]?.arrayVal ?? obj["domain"]?.arrayVal,
           dom.count == 2,
           let lo = dom[0].doubleVal,
           let hi = dom[1].doubleVal,
           hi > lo {
            xMin = lo; xMax = hi
        }

        var yMin: Double?
        var yMax: Double?
        if let dom = obj["yDomain"]?.arrayVal,
           dom.count == 2,
           let lo = dom[0].doubleVal,
           let hi = dom[1].doubleVal,
           hi > lo {
            yMin = lo; yMax = hi
        }

        var functions: [ChatPlotFunction] = []
        for (idx, raw) in rawFuncs.enumerated() {
            let expr: String
            let label: String
            if let str = raw.trimmedString {
                expr = str
                label = str
            } else if let fObj = raw.objectVal, let e = fObj["expr"]?.trimmedString ?? fObj["expression"]?.trimmedString {
                expr = e
                label = fObj["label"]?.trimmedString ?? e
            } else {
                return .failure(ChatVisualizationError("Function \(idx + 1) needs an 'expr' string."))
            }
            switch MathExpressionParser.parse(expr) {
            case .success(let ast):
                functions.append(ChatPlotFunction(id: idx, expr: expr, label: label, ast: ast, error: nil))
            case .failure(let err):
                // Preserve per-function error so other valid functions still render!
                functions.append(ChatPlotFunction(id: idx, expr: expr, label: label, ast: nil, error: err.message))
            }
        }

        // If every single function is invalid, fail the block so invalid-spec fallback triggers cleanly.
        if functions.allSatisfy({ $0.ast == nil }) {
            let firstErr = functions.first?.error ?? "No valid mathematical functions."
            return .failure(ChatVisualizationError(firstErr))
        }

        var parameters: [ChatPlotParameter] = []
        if let rawParams = obj["parameters"]?.arrayVal {
            for raw in rawParams {
                guard let pObj = raw.objectVal,
                      let name = pObj["name"]?.trimmedString
                else { continue }
                let lo = pObj["min"]?.doubleVal ?? -5.0
                let hi = pObj["max"]?.doubleVal ?? 5.0
                guard hi > lo else { continue }
                let initial = min(hi, max(lo, pObj["value"]?.doubleVal ?? (lo + hi) / 2))
                let step = max(0.001, pObj["step"]?.doubleVal ?? ((hi - lo) / 100))
                parameters.append(ChatPlotParameter(name: name, value: initial, min: lo, max: hi, step: step))
            }
        }

        return .success(ChatPlotSpec(
            title: obj["title"]?.trimmedString,
            subtitle: obj["subtitle"]?.trimmedString,
            xMin: xMin,
            xMax: xMax,
            yMin: yMin,
            yMax: yMax,
            functions: functions,
            parameters: parameters
        ))
    }
}
