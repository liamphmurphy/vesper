import AppKit
import SwiftUI
import VesperCore

/// Rendered embeds as images. The PDF becomes an `NSImage` backed by `NSPDFImageRep`, which draws
/// as vectors at whatever size and scale it's shown, so diagrams and math stay sharp when zoomed or
/// moved to a Retina display. The one AppKit-specific step of the render-once path; an iOS client
/// draws the same PDF data through `CGPDFDocument`.
@MainActor
enum EmbedImages {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(_ embed: RenderedEmbed, key: EmbedCacheKey) -> NSImage? {
        let name = key.description as NSString
        if let hit = cache.object(forKey: name) { return hit }
        guard let image = NSImage(data: embed.pdf) else { return nil }
        image.size = NSSize(width: embed.width, height: embed.height)
        cache.setObject(image, forKey: name)
        return image
    }
}

/// Draws math. Math is meant to be laid out natively (SwiftMath, which couldn't be vendored yet: see
/// docs/dev/native-mac-app.md "Native chat embeds"); whatever the native engine can't lay out goes
/// through the render-once web path (KaTeX in `EmbedRenderer`), which today is all of it.
@MainActor
protocol MathRenderer {
    /// The drawn math, or nil when this renderer can't lay it out.
    func render(_ request: MathRenderRequest, messageID: String) async -> RenderedEmbed?
}

/// KaTeX in the off-screen renderer, exported as a vector PDF: the same layout and fonts as the web.
struct WebMathRenderer: MathRenderer {
    func render(_ request: MathRenderRequest, messageID: String) async -> RenderedEmbed? {
        guard !request.tex.isEmpty else { return nil }
        return await EmbedRenderer.shared.render(request.cacheKey(messageID: messageID), .math(request))
    }
}

/// A native engine first, the web path for what it can't lay out.
struct FallbackMathRenderer: MathRenderer {
    var primary: (any MathRenderer)?
    var fallback: any MathRenderer

    func render(_ request: MathRenderRequest, messageID: String) async -> RenderedEmbed? {
        if let primary, let drawn = await primary.render(request, messageID: messageID) { return drawn }
        return await fallback.render(request, messageID: messageID)
    }
}

@MainActor
enum MathRendering {
    /// Plug a native renderer in as `primary` when SwiftMath is vendored.
    static let shared: any MathRenderer = FallbackMathRenderer(primary: nil, fallback: WebMathRenderer())
}

/// A rendered image sized as drawn, shrinking to fit the width (and `maxHeight`) without growing.
struct EmbedImageView: View {
    let image: NSImage
    let size: CGSize
    var maxHeight: CGFloat = .infinity
    var alt: String

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
            .frame(maxWidth: size.width, maxHeight: min(maxHeight, size.height))
            .accessibilityLabel(alt)
    }
}
