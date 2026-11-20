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
}
