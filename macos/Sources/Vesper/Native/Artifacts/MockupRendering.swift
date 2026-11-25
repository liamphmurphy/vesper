import AppKit
import CryptoKit
import VesperCore

/// How the app draws a mockup version, and what it sends when a person reviews one.
///
/// A version that conforms to mockup SVG profile v1 (docs/dev/mockup-svg-profile.md) is drawn by
/// the native renderer, the same code the editor uses, so what's approved is what was edited.
/// Older versions that don't conform are "legacy": they still draw through the offscreen WebKit
/// `EmbedRenderer`, and the UI says so.
enum MockupRendering {
    /// The renderer id sent with snapshots of legacy versions.
    static let webkitRenderer = "webkit"
    /// Snapshots are 2x: sharp on Retina, and small enough to send with a review.
    static let snapshotScale: CGFloat = 2

    struct Drawing {
        /// Draws at whatever size it's shown, so zooming stays sharp.
        let image: NSImage
        let size: ArtifactDetailLogic.MockupSize
        let renderer: String
        /// The native document, when the version conforms.
        let document: MockupSVGDocument?

        var isLegacy: Bool { document == nil }
    }

    /// Draws `source`; `cacheID` names it in the WebKit cache for legacy versions.
    static func draw(source: String, cacheID: String) async -> Drawing? {
        if let document = try? MockupSVGDocument(source: source) {
            return Drawing(image: image(document), size: .init(width: document.intrinsicSize.width, height: document.intrinsicSize.height),
                           renderer: MockupSVGRenderer.identifier, document: document)
        }
        let parsed = ArtifactDetailLogic.svgSize(source)
        let key = EmbedCacheKey(kind: .svgImage, messageID: cacheID, theme: "light", source: source)
        guard let rendered = await EmbedRenderer.shared.render(key, .svg(source, background: "#ffffff")),
              let image = NSImage(data: rendered.pdf) else { return nil }
        let size = ArtifactDetailLogic.MockupSize(
            width: rendered.width > 0 ? rendered.width : parsed.width,
            height: rendered.height > 0 ? rendered.height : parsed.height
        )
        return Drawing(image: image, size: size, renderer: webkitRenderer, document: nil)
    }

    /// An image that redraws the document natively at each size AppKit asks for. Not a PDF:
    /// CoreGraphics' PDF output flattens gradient alpha, which would show a different picture
    /// from the approved snapshot.
    static func image(_ document: MockupSVGDocument) -> NSImage {
        NSImage(size: document.intrinsicSize, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            MockupSVGRenderer.draw(document, in: ctx, rect: rect, options: MockupSVGRenderOptions(background: CGColor(gray: 1, alpha: 1)))
            return true
        }
    }

    /// The hex SHA-256 the server matches a snapshot against.
    static func sourceSHA256(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The PNG of exactly what the person is looking at, for the review request.
    static func snapshot(of drawing: Drawing, source: String) -> API.ReviewArtifactVersionBody.Snapshot? {
        let png: Data?
        if let document = drawing.document {
            png = MockupSVGRenderer.pngData(document, scale: snapshotScale, background: CGColor(gray: 1, alpha: 1))
        } else {
            png = rasterizedPNG(drawing.image, size: drawing.size)
        }
        guard let png else { return nil }
        return API.ReviewArtifactVersionBody.Snapshot(
            pngBase64: png.base64EncodedString(),
            renderer: drawing.renderer,
            sourceSha256: sourceSHA256(source)
        )
    }

    private static func rasterizedPNG(_ image: NSImage, size: ArtifactDetailLogic.MockupSize) -> Data? {
        let w = Int((size.width * snapshotScale).rounded()), h = Int((size.height * snapshotScale).rounded())
        guard w > 0, h > 0, w <= 8192, h <= 8192,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size.width, height: size.height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        return rep.representation(using: .png, properties: [:])
    }

    /// Reviews `versionId` with a snapshot of `source` attached. Every review in the app goes
    /// through here, so a decision always records the picture it was made on. A snapshot that
    /// can't be drawn doesn't block the decision: the server keeps the SVG either way.
    static func review(
        client: APIClient,
        artifactId: String,
        versionId: String,
        source: String?,
        drawing: Drawing? = nil,
        decision: API.ReviewArtifactVersionBody.Decision,
        note: String?,
        pins: [API.MockupPin]? = nil
    ) async throws -> API.Artifact {
        var snapshot: API.ReviewArtifactVersionBody.Snapshot?
        if let source, !source.isEmpty {
            var shown = drawing
            if shown == nil { shown = await draw(source: source, cacheID: "review-\(artifactId)-\(versionId)") }
            if let shown { snapshot = self.snapshot(of: shown, source: source) }
        }
        return try await client.send(API.reviewArtifactVersion(
            id: artifactId,
            versionId: versionId,
            body: API.ReviewArtifactVersionBody(decision: decision, note: note, pins: pins, snapshot: snapshot)
        ))
    }

    /// Fetches a version's SVG source when the caller only has ids (the inbox).
    static func source(client: APIClient, artifactId: String, versionId: String) async -> String? {
        let path = ArtifactDetailLogic.contentPath(artifactId: artifactId, versionId: versionId)
        guard let data = try? await client.request("GET", path, headers: ["Accept": "*/*"], timeout: 60) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
