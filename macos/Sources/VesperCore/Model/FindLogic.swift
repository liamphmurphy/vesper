import Foundation

/// Pure logic for the native WKWebView find bar, unit-tested in VesperCoreTests.
public enum FindLogic: Sendable {
    private static let maxSelectionLength = 200

    /// Extracts the first non-empty trimmed line from a web selection, capped to a practical query length.
    public static func normalizeSelection(_ raw: String?) -> String? {
        guard let raw else { return nil }
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(maxSelectionLength))
            }
        }
        return nil
    }

    public static func shouldSearch(query: String) -> Bool {
        !query.isEmpty
    }

    public static func statusText(query: String, hasResult: Bool, matchFound: Bool) -> String? {
        guard !query.isEmpty, hasResult, !matchFound else { return nil }
        return "No matches"
    }

    /// Which of a native screen's searchable texts to show next for `query`: the first match after
    /// `current` (before it when `backwards`), wrapping around. Nil when nothing matches.
    public static func nextMatch(
        in texts: [String], query: String, caseSensitive: Bool, after current: Int?, backwards: Bool
    ) -> Int? {
        guard shouldSearch(query: query) else { return nil }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        let matches = texts.indices.filter { texts[$0].range(of: query, options: options) != nil }
        guard !matches.isEmpty else { return nil }
        guard let current else { return backwards ? matches.last : matches.first }
        if backwards { return matches.last(where: { $0 < current }) ?? matches.last }
        return matches.first(where: { $0 > current }) ?? matches.first
    }
}
