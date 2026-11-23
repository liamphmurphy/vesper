import Foundation

// MARK: - Live Entity References in Chat (LAZYAGENTS-317)

public enum ChatEntityRef: Sendable, Equatable, Hashable, Identifiable {
    case ticket(key: String)
    case run(id: String)
    case epic(ref: String)
    case page(ref: String)

    public var id: String {
        switch self {
        case .ticket(let key): "ticket:\(key)"
        case .run(let id): "run:\(id)"
        case .epic(let ref): "epic:\(ref.lowercased())"
        case .page(let ref): "page:\(ref.lowercased())"
        }
    }

    public var displayLabel: String {
        switch self {
        case .ticket(let key): key
        case .run(let id): "run \(String(id.prefix(8)))"
        case .epic(let ref): ref
        case .page(let ref): ref
        }
    }
}

public enum ChatEntityRefExtractor {
    public static let maxRefsPerMessage = 12

    private static let wikiBracketRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+?)\]\]"#)
    private static let bareTicketRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_/:])([A-Z][A-Z0-9]{1,9}-[0-9]{1,7})(?![A-Za-z0-9_-])"#)

    /// Extracts explicit entity refs (`[[ticket:KEY]]`, `[[run:UUID]]`, `[[epic:ID]]`, `[[page:Path]]`,
    /// `[[Wiki Page]]`) and auto-detected bare ticket keys (`LAZYAGENTS-123`) outside fenced code blocks
    /// and inline code spans. Preserves first-seen order and deduplicates.
    public static func extract(from markdown: String) -> [ChatEntityRef] {
        var result: [ChatEntityRef] = []
        var seen: Set<String> = []

        func append(_ ref: ChatEntityRef) {
            guard result.count < maxRefsPerMessage else { return }
            if seen.insert(ref.id).inserted {
                result.append(ref)
            }
        }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fenceChar: Character?
        var fenceLen = 0

        for line in lines {
            if let opener = fenceOpener(line) {
                if fenceChar == nil {
                    fenceChar = opener.char
                    fenceLen = opener.len
                    continue
                }
            }
            if let fc = fenceChar {
                if isFenceCloser(line, char: fc, minLen: fenceLen) {
                    fenceChar = nil
                    fenceLen = 0
                }
                continue
            }

            let sanitized = stripInlineCodeAndURLs(line)
            let ns = sanitized as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            // Collect matches in left-to-right reading order on this line.
            var lineHits: [(location: Int, ref: ChatEntityRef)] = []
            var wikiRanges: [NSRange] = []
            for match in wikiBracketRegex.matches(in: sanitized, range: fullRange) {
                wikiRanges.append(match.range)
                let rawInner = ns.substring(with: match.range(at: 1))
                // Strip optional alias `target|label` and heading anchor `#section`
                let targetPart = rawInner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? rawInner
                let trimmed = targetPart.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let parsed = parseBracketRef(trimmed) {
                    lineHits.append((match.range.location, parsed))
                }
            }

            for match in bareTicketRegex.matches(in: sanitized, range: fullRange) {
                if wikiRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    continue
                }
                let key = ns.substring(with: match.range(at: 1)).uppercased()
                if ChatDispatchCard.isValidTicketKey(key) {
                    lineHits.append((match.range.location, .ticket(key: key)))
                }
            }

            for hit in lineHits.sorted(by: { $0.location < $1.location }) {
                append(hit.ref)
            }
        }

        return result
    }

    public static func parseBracketRef(_ inner: String) -> ChatEntityRef? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            switch prefix {
            case "ticket":
                let upper = value.uppercased()
                return ChatDispatchCard.isValidTicketKey(upper) ? .ticket(key: upper) : nil
            case "run":
                return ChatFenceParsers.isUUID(value) ? .run(id: value.lowercased()) : nil
            case "epic":
                return .epic(ref: value)
            case "page", "wiki":
                let base = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
                return base.isEmpty ? nil : .page(ref: base)
            default:
                break
            }
        }
        let upper = trimmed.uppercased()
        if ChatDispatchCard.isValidTicketKey(upper) {
            return .ticket(key: upper)
        }
        let pageTarget = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        let cleanPage = pageTarget.trimmingCharacters(in: .whitespaces)
        return cleanPage.isEmpty ? nil : .page(ref: cleanPage)
    }

    /// Formats total token count compactly (e.g. `14.2k tok`).
    public static func compactTokens(_ total: Int) -> String {
        if total >= 1_000_000 {
            return String(format: "%.1fM tok", Double(total) / 1_000_000)
        }
        if total >= 1_000 {
            return String(format: "%.1fk tok", Double(total) / 1_000)
        }
        return "\(total) tok"
    }

    /// Formats a USD cost cleanly (`$0.04`, `<$0.01`).
    public static func compactCost(_ cost: Double) -> String? {
        guard cost > 0 else { return nil }
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }

    /// Extracts folder prefix from a wiki page path (`Architecture/ADR/Chat` -> `Architecture/ADR`).
    public static func folderPath(from pagePath: String?) -> String? {
        guard let pagePath, let slash = pagePath.lastIndex(of: "/") else { return nil }
        let folder = String(pagePath[..<slash]).trimmingCharacters(in: .whitespaces)
        return folder.isEmpty ? nil : folder
    }

    // MARK: Helpers

    private static func stripInlineCodeAndURLs(_ line: String) -> String {
        // Mask inline code spans (`...`) and markdown link destinations `](...)` + raw http(s) URLs with spaces
        // of matching length so regex indices remain clean and nothing inside code or URLs matches.
        let chars = Array(line)
        var out = chars
        var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                var ticks = 0
                while i + ticks < chars.count && chars[i + ticks] == "`" { ticks += 1 }
                var j = i + ticks
                var foundEnd: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        var closeTicks = 0
                        while j + closeTicks < chars.count && chars[j + closeTicks] == "`" { closeTicks += 1 }
                        if closeTicks == ticks {
                            foundEnd = j + closeTicks
                            break
                        }
                        j += closeTicks
                    } else {
                        j += 1
                    }
                }
                let end = foundEnd ?? chars.count
                for k in i..<end { out[k] = " " }
                i = end
                continue
            }
            if i + 1 < chars.count && chars[i] == "]" && chars[i + 1] == "(" {
                var depth = 1
                var j = i + 2
                while j < chars.count && depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    else if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                for k in (i + 1)..<j { out[k] = " " }
                i = j
                continue
            }
            if line[line.index(line.startIndex, offsetBy: i)...].hasPrefix("http://")
                || line[line.index(line.startIndex, offsetBy: i)...].hasPrefix("https://") {
                var j = i
                while j < chars.count && !chars[j].isWhitespace && chars[j] != ")" && chars[j] != "]" {
                    out[j] = " "
                    j += 1
                }
                i = j
                continue
            }
            i += 1
        }
        return String(out)
    }

    private static func fenceOpener(_ line: String) -> (char: Character, len: Int)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let len = trimmed.prefix(while: { $0 == first }).count
        return len >= 3 ? (first, len) : nil
    }

    private static func isFenceCloser(_ line: String, char: Character, minLen: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= minLen && trimmed.allSatisfy { $0 == char }
    }
}
