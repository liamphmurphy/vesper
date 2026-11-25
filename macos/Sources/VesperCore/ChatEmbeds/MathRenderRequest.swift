import Foundation

/// One piece of math to draw: its TeX, display or inline, and the colour and size of the text around
/// it (baked into the image, so they're part of the cache key).
public struct MathRenderRequest: Sendable, Hashable {
    public var tex: String
    public var display: Bool
    /// "#RRGGBB".
    public var color: String
    /// The surrounding text's point size; KaTeX sets math at 1.21 times it, as on the web.
    public var fontSize: Double

    public init(tex: String, display: Bool, color: String, fontSize: Double) {
        self.tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        self.display = display
        self.color = RGBA(hex: color) != nil ? color : "#000000"
        self.fontSize = max(6, min(fontSize, 96))
    }

    /// Cached per message like the other embeds; math in markdown outside a message uses "".
    public func cacheKey(messageID: String = "") -> EmbedCacheKey {
        EmbedCacheKey(kind: .math, messageID: messageID, theme: "\(color.lowercased())@\(fontSize)", source: tex, variant: display ? "display" : "inline")
    }
}
