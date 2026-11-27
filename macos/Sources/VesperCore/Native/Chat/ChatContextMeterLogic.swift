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

public enum ChatContextBreakdownCategory: String, CaseIterable, Sendable, Equatable, Identifiable {
    case systemPersona
    case memory
    case spaceKnowledge
    case attachmentsTools
    case conversation

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .systemPersona: "System & Persona"
        case .memory: "Memory"
        case .spaceKnowledge: "Space & Knowledge"
        case .attachmentsTools: "Files & Tools"
        case .conversation: "Conversation"
        }
    }
}

public struct ChatContextBreakdownSlice: Sendable, Equatable, Identifiable {
    public var id: String { category.rawValue }
    public let category: ChatContextBreakdownCategory
    public let tokens: Int
    public let share: Double

    public init(category: ChatContextBreakdownCategory, tokens: Int, share: Double) {
        self.category = category
        self.tokens = tokens
        self.share = share
    }
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

    /// Estimates how `contextTokens` is split across System/Persona, Memory, Space/Knowledge,
    /// Attachments/Tools, and Conversation history so the user can see what is filling the window.
    public static func breakdown(
        contextTokens: Int?,
        messages: [API.ChatMessage],
        hasSpace: Bool,
        hasPersona: Bool,
        isTemporary: Bool
    ) -> [ChatContextBreakdownSlice] {
        let total = max(0, contextTokens ?? 0)
        guard total > 0 else { return [] }

        var conversationChars = 0
        var knowledgeRefCount = 0
        var attachmentBytes = 0
        for msg in messages {
            let stripped = ChatTranscriptLogic.stripContext(msg.bodyMd)
            conversationChars += stripped.typedBody.count
            knowledgeRefCount += (msg.contextRefs?.count ?? 0) + stripped.knowledgeContextLines.count + stripped.customAppContextLines.count
            for att in msg.attachments ?? [] {
                attachmentBytes += max(0, att.sizeBytes)
            }
        }

        // Baseline estimates (tokens ≈ chars / 4), normalized cleanly to sum to `total`.
        let rawSystem = hasPersona ? 2_400 : 1_600
        let rawMemory = isTemporary ? 0 : (hasPersona ? 1_800 : 1_200)
        let rawSpace = (hasSpace ? 1_200 : 0) + knowledgeRefCount * 450
        let rawConversation = max(0, conversationChars / 4)
        let rawAttachments = attachmentBytes > 0 ? max(400, min(24_000, attachmentBytes / 8)) : 0

        let knownSum = rawSystem + rawMemory + rawSpace + rawConversation + rawAttachments
        var buckets: [(ChatContextBreakdownCategory, Int)] = []
        if knownSum <= total {
            let toolOverhead = total - knownSum
            buckets = [
                (.systemPersona, rawSystem),
                (.memory, rawMemory),
                (.spaceKnowledge, rawSpace),
                (.attachmentsTools, rawAttachments + toolOverhead),
                (.conversation, rawConversation),
            ]
        } else {
            let scale = Double(total) / Double(max(1, knownSum))
            var assigned = 0
            let rawPairs: [(ChatContextBreakdownCategory, Int)] = [
                (.systemPersona, rawSystem),
                (.memory, rawMemory),
                (.spaceKnowledge, rawSpace),
                (.attachmentsTools, rawAttachments),
                (.conversation, rawConversation),
            ]
            for (idx, pair) in rawPairs.enumerated() {
                if pair.1 == 0 { continue }
                let val: Int
                if idx == rawPairs.count - 1 {
                    val = max(0, total - assigned)
                } else {
                    val = max(1, Int((Double(pair.1) * scale).rounded()))
                }
                assigned += val
                buckets.append((pair.0, val))
            }
        }

        let nonZero = buckets.filter { $0.1 > 0 }
        let denom = Double(max(1, nonZero.reduce(0) { $0 + $1.1 }))
        return nonZero.map { cat, tok in
            ChatContextBreakdownSlice(category: cat, tokens: tok, share: Double(tok) / denom)
        }
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
