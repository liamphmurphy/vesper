import Foundation

public enum ChatContextMeterTone: Sendable, Equatable {
    case neutral
    case warning
    case danger
}

public struct ChatRolloverPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// `nil` inherits server default (160k); `0` disables auto-compaction; `> 0` sets an explicit token threshold.
    public let value: Int?

    public init(id: String, label: String, value: Int?) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct ChatContextMeterState: Sendable, Equatable {
    public let tokens: Int
    public let limit: Int
    public let ratio: Double
    public let tone: ChatContextMeterTone
    public let label: String
}

public enum ChatContextMeterLogic {
    public static let defaultAutoRolloverTokens = 160_000

    public static let presets: [ChatRolloverPreset] = [
        ChatRolloverPreset(id: "default", label: "Default (160k)", value: nil),
        ChatRolloverPreset(id: "80k", label: "80k", value: 80_000),
        ChatRolloverPreset(id: "120k", label: "120k", value: 120_000),
        ChatRolloverPreset(id: "160k", label: "160k", value: 160_000),
        ChatRolloverPreset(id: "200k", label: "200k", value: 200_000),
        ChatRolloverPreset(id: "off", label: "Off", value: 0),
    ]

    public static func formatTokens(_ count: Int) -> String {
        let n = max(0, count)
        if n < 1000 { return "\(n)" }
        if n < 100_000 {
            let tenths = (Double(n) / 100.0).rounded() / 10.0
            if tenths.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(tenths))k"
            }
            return String(format: "%.1fk", tenths)
        }
        return "\(Int((Double(n) / 1000.0).rounded()))k"
    }

    public static func state(contextTokens: Int?, effectiveLimit: Int?) -> ChatContextMeterState {
        let tokens = max(0, contextTokens ?? 0)
        let limit = max(0, effectiveLimit ?? 0)
        guard limit > 0 else {
            return ChatContextMeterState(
                tokens: tokens,
                limit: 0,
                ratio: 0,
                tone: .neutral,
                label: tokens > 0 ? "\(formatTokens(tokens)) tok" : "Auto-compact off"
            )
        }
        let ratio = min(1.0, Double(tokens) / Double(limit))
        let tone: ChatContextMeterTone = ratio >= 0.9 ? .danger : ratio >= 0.75 ? .warning : .neutral
        return ChatContextMeterState(
            tokens: tokens,
            limit: limit,
            ratio: ratio,
            tone: tone,
            label: "\(formatTokens(tokens)) / \(formatTokens(limit))"
        )
    }
}

public enum ChatReplyFoldingLogic {
    public static let charThreshold = 2400
    public static let lineThreshold = 42

    public static func lineCount(_ bodyMd: String) -> Int {
        guard !bodyMd.isEmpty else { return 0 }
        var count = 1
        for ch in bodyMd where ch == "\n" { count += 1 }
        return count
    }

    public static func isFoldableReply(_ bodyMd: String) -> Bool {
        if bodyMd.count >= charThreshold { return true }
        return lineCount(bodyMd) >= lineThreshold
    }

    public static func collapsedPreview(_ bodyMd: String, maxLines: Int = 5, maxChars: Int = 420) -> String {
        let lines = bodyMd
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        if head.count <= maxChars { return head }
        return String(head.prefix(maxChars - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
