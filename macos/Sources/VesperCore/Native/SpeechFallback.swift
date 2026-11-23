import Foundation

/// The message of a 429 from a reply's speech stream (the API's `{"code","message"}` error): which
/// limit the voice provider hit and when it lifts. Generic when the body says nothing readable.
public enum SpeechLimitMessage {
    public static let fallback = "The voice provider's request limit was reached."

    public static func from(_ body: Data) -> String {
        struct APIError: Decodable { let message: String? }
        let message = (try? JSONDecoder().decode(APIError.self, from: body))?.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return message }
        return fallback
    }
}

/// What the Mac's own voice reads when it stands in for a persona's.
public enum SystemVoiceText {
    /// The words of a reply without inline Markdown syntax, which the voice would read out.
    public static func plain(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(parsed.characters)
    }
}
