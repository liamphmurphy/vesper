import Foundation

/// Pure filename and index clamping helpers for native Quick Look previews.
public enum QuickLookLogic: Sendable {
    public static func clampIndex(_ index: Int?, count: Int) -> Int {
        guard count > 0, let index else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// Produces a safe local filename for a downloaded preview item, ensuring a valid extension
    /// when a MIME type or fallback extension is known.
    public static func safeFilename(
        filename: String?,
        fallbackTitle: String,
        urlPathComponent: String?,
        preferredExtension: String?
    ) -> String {
        let candidates = [filename, urlPathComponent, fallbackTitle]
        var base = ""
        for candidate in candidates {
            if let sanitized = sanitizeComponent(candidate), !sanitized.isEmpty {
                base = sanitized
                break
            }
        }
        if base.isEmpty { base = "Preview" }

        let currentExt = (base as NSString).pathExtension
        if currentExt.isEmpty, let ext = preferredExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), !ext.isEmpty {
            base += ".\(sanitizeExtension(ext))"
        }
        return String(base.prefix(180))
    }

    private static func sanitizeComponent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let leaf = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let stripped = leaf
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: CharacterSet.controlCharacters)
            .joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return stripped.isEmpty ? nil : stripped
    }

    private static func sanitizeExtension(_ raw: String) -> String {
        raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
