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

    /// A natively compiled SVG frame as an image that redraws the document at each size AppKit asks
    /// for, so it stays sharp at any zoom. Not a PDF: CoreGraphics' PDF output flattens gradient
    /// alpha (see `MockupRendering.image`).
    static func image(_ frame: ChatSVGFrame, key: EmbedCacheKey, background: String) -> NSImage {
        let name = "native|\(key.description)|\(background)" as NSString
        if let hit = cache.object(forKey: name) { return hit }
        let fill = RGBA(hex: background).map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
        let document = frame.document
        let image = NSImage(size: document.intrinsicSize, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            MockupSVGRenderer.draw(document, in: ctx, rect: rect, options: MockupSVGRenderOptions(background: fill))
            return true
        }
        cache.setObject(image, forKey: name)
        return image
    }
}

/// Draws math natively (`NativeMath`: SwiftMath layout, CoreGraphics drawing), cached like every
/// other embed. nil when the TeX doesn't parse; the view keeps showing the source then.
@MainActor
enum MathRendering {
    static func render(_ request: MathRenderRequest, messageID: String) -> RenderedEmbed? {
        let key = request.cacheKey(messageID: messageID)
        if let hit = EmbedRenderCache.shared.value(for: key) { return hit }
        guard let drawn = NativeMath.render(request) else { return nil }
        EmbedRenderCache.shared.insert(drawn, for: key, cost: drawn.pdf.count)
        return drawn
    }
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
