import Foundation

/// Actions available from the floating text-selection popover and context menu in chat replies.
public enum ChatSelectionAction: String, CaseIterable, Sendable, Equatable, Identifiable {
    case quote
    case thread
    case explain
    case clipToKnowledge

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quote: "Quote"
        case .thread: "Thread"
        case .explain: "Explain"
        case .clipToKnowledge: "Clip"
        }
    }

    public var menuTitle: String {
        switch self {
        case .quote: "Quote selection in composer"
        case .thread: "Ask in thread about selection"
        case .explain: "Explain selection"
        case .clipToKnowledge: "Clip selection to Knowledge…"
        }
    }

    public var systemImage: String {
        switch self {
        case .quote: "arrowshape.turn.up.left"
        case .thread: "bubble.left.and.bubble.right"
        case .explain: "sparkles"
        case .clipToKnowledge: "book"
        }
    }
}

public enum ChatSelectionLogic {
    public static let minChars = 2
    public static let maxExcerptChars = 1500

    public static func cleanSelection(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars else { return nil }
        if trimmed.count <= maxExcerptChars { return trimmed }
        return String(trimmed.prefix(maxExcerptChars))
    }

    public static func quotePrompt(selection: String, speakerName: String?, hostName: String?) -> String {
        let mention = (speakerName != nil && speakerName != hostName) ? speakerName : nil
        return ChatQuoteLogic.quoteForComposer(selection, mention: mention)
    }

    public static func threadPrefill(selection: String) -> String {
        ChatQuoteLogic.quoteForComposer(selection, mention: nil)
    }

    public static func explainPrompt(selection: String) -> String {
        let quoted = ChatQuoteLogic.quoteForComposer(selection, mention: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Explain this part in more detail:\n\n\(quoted)\n\n"
    }
}
