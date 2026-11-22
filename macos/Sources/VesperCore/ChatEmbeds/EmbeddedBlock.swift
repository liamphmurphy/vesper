import CryptoKit
import Foundation

/// A chat fence the native transcript draws as an embed rather than markdown text or a code box:
/// the web's `visualFence` (components/domain/visuals.tsx) and `isAppFence` (lib/chat-app.ts), plus
/// display math. Platform-neutral so an iOS client classifies the same way.
public enum EmbeddedBlockKind: String, Sendable, CaseIterable, Hashable {
    /// `$$ … $$` display math, or a ```math fence (remark-math).
    case math
    /// ```mermaid: drawn by mermaid off-screen, shown as an image.
    case mermaid
    /// ```svg-image: one SVG document shown as an image.
    case svgImage = "svg-image"
    /// ```svg-steps: an SVG with `data-step` marks, then one caption per step.
    case svgSteps = "svg-steps"
    /// ```app / ```html-app: a self-contained HTML document run in a sandboxed web view.
    case app

    /// The kind for a fence's info string, nil for a fence that stays a code block. Like the web, only
    /// the first word counts and case doesn't.
    public static func classify(info: String?) -> EmbeddedBlockKind? {
        let word = (info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
        switch word {
        case "math": return .math
        case "mermaid": return .mermaid
        case "svg-image": return .svgImage
        case "svg-steps": return .svgSteps
        case "app", "html-app": return .app
        default: return nil
        }
    }

    /// Whether the block is drawn once into a vector image (everything but apps, which stay live).
    public var isRenderedOnce: Bool { self != .app }

    /// Whether "Save to Library" applies: the diagrams (POST /library/diagrams takes any SVG document
    /// from an assistant reply). Math and apps aren't diagrams.
    public var savesToLibrary: Bool { self == .mermaid || self == .svgImage || self == .svgSteps }
}

/// What a rendered embed is cached under: the message it's in, the theme it was drawn with, and the
/// source (hashed), plus the variant (a step-through's frame, display or inline math, a size). Two
/// identical blocks in one message share an entry, which is what we want: they'd draw the same.
public struct EmbedCacheKey: Sendable, Hashable, CustomStringConvertible {
    public var kind: EmbeddedBlockKind
    public var messageID: String
    public var theme: String
    public var sourceHash: String
    public var variant: String

    public init(kind: EmbeddedBlockKind, messageID: String, theme: String, source: String, variant: String = "") {
        self.kind = kind
        self.messageID = messageID
        self.theme = theme
        self.sourceHash = Self.hash(source)
        self.variant = variant
    }

    public var description: String { "\(kind.rawValue)|\(messageID)|\(theme)|\(sourceHash)|\(variant)" }

    /// Hex SHA-256 of the UTF-8 source.
    public static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
