import Foundation

/// Supported playback speed steps for on-demand message Read Aloud.
public enum ChatPlaybackRate: Double, CaseIterable, Sendable, Equatable, Hashable {
    case x1 = 1.0
    case x125 = 1.25
    case x15 = 1.5
    case x2 = 2.0

    public var label: String {
        switch self {
        case .x1: "1×"
        case .x125: "1.25×"
        case .x15: "1.5×"
        case .x2: "2×"
        }
    }

    public var floatValue: Float { Float(rawValue) }

    public func next() -> ChatPlaybackRate {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .x1 }
        return all[(idx + 1) % all.count]
    }
}

public enum ChatReadAloudLogic {
    /// Builds a clean single-line snippet for the floating Read Aloud mini playback bar.
    public static func snippet(from markdown: String, maxLength: Int = 72) -> String {
        let plain = SystemVoiceText.plain(markdown)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return "Message" }
        if plain.count <= maxLength { return plain }
        return String(plain.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
