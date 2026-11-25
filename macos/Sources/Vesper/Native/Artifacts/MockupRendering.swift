import AppKit
import CryptoKit
import VesperCore

/// How the app draws a mockup version, and what it sends when a person reviews one.
///
/// A version that conforms to mockup SVG profile v1 (docs/dev/mockup-svg-profile.md) is drawn by
/// the native renderer, the same code the editor uses, so what's approved is what was edited.
/// Older versions that don't conform are "legacy": `MockupSVGSimplifier` converts their CSS and
/// drops what the profile can't draw (filters, animation), the native renderer draws the result,
/// and the UI says what was left out. The snapshot a review sends is that picture.
enum MockupRendering {
    /// Snapshots are 2x: sharp on Retina, and small enough to send with a review.
    static let snapshotScale: CGFloat = 2

    struct Drawing {
        /// Draws at whatever size it's shown, so zooming stays sharp.
        let image: NSImage
        let size: ArtifactDetailLogic.MockupSize
        let renderer: String
        let document: MockupSVGDocument
        /// What simplifying a legacy version left out; empty when the version conforms.
        let dropped: [String]
        /// Whether the version is outside profile v1 and was simplified to draw.
        let isLegacy: Bool
    }

    /// Draws `source` natively, simplifying a legacy version first; nil when even that can't make
    /// it drawable.
    static func draw(source: String) -> Drawing? {
        let document: MockupSVGDocument, dropped: [String], legacy: Bool
        if let conforming = try? MockupSVGDocument(source: source) {
            (document, dropped, legacy) = (conforming, [], false)
        } else if let simplified = MockupSVGDocument.simplified(source) {
            (document, dropped, legacy) = (simplified.document, simplified.dropped, true)
        } else {
            return nil
        }
        return Drawing(image: image(document), size: .init(width: document.intrinsicSize.width, height: document.intrinsicSize.height),
                       renderer: MockupSVGRenderer.identifier, document: document, dropped: dropped, isLegacy: legacy)
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
        guard let png = MockupSVGRenderer.pngData(drawing.document, scale: snapshotScale, background: CGColor(gray: 1, alpha: 1)) else { return nil }
        return API.ReviewArtifactVersionBody.Snapshot(
            pngBase64: png.base64EncodedString(),
            renderer: drawing.renderer,
            sourceSha256: sourceSHA256(source)
        )
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
            if shown == nil { shown = draw(source: source) }
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
