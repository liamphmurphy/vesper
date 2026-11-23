import XCTest
@testable import VesperCore

final class ArtifactDetailLogicTests: XCTestCase {
    func testSvgSizeParsing() {
        XCTAssertEqual(
            ArtifactDetailLogic.svgSize(#"<svg width="640" height="480" viewBox="0 0 100 100"></svg>"#),
            .init(width: 640, height: 480)
        )
        XCTAssertEqual(
            ArtifactDetailLogic.svgSize(#"<svg width="100%" viewBox="0 0 800 600"></svg>"#),
            .init(width: 800, height: 600)
        )
        XCTAssertEqual(
            ArtifactDetailLogic.svgSize(#"<svg width="400px" viewBox="0 0 200 100"></svg>"#),
            .init(width: 400, height: 200)
        )
        XCTAssertEqual(
            ArtifactDetailLogic.svgSize("not an svg"),
            ArtifactDetailLogic.defaultSize
        )
    }

    func testCameraFitZoomAndFractionRoundTrip() {
        let drawing = ArtifactDetailLogic.MockupSize(width: 1000, height: 500)
        let viewport = ArtifactDetailLogic.MockupSize(width: 1064, height: 600)
        let fit = ArtifactDetailLogic.fitView(drawing: drawing, viewport: viewport)
        XCTAssertEqual(fit.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(fit.x, 32.0, accuracy: 0.001)
        XCTAssertEqual(fit.y, 50.0, accuracy: 0.001)

        // Zoom about viewport center keeps center point invariant.
        let centerFrac = ArtifactDetailLogic.toFraction(camera: fit, drawing: drawing, px: 532, py: 300)!
        let zoomed = ArtifactDetailLogic.zoomAt(fit, factor: 2.0, px: 532, py: 300)
        let back = ArtifactDetailLogic.fromFraction(camera: zoomed, drawing: drawing, fraction: centerFrac)
        XCTAssertEqual(back.x, 532, accuracy: 0.001)
        XCTAssertEqual(back.y, 300, accuracy: 0.001)

        // Out-of-bounds returns nil.
        XCTAssertNil(ArtifactDetailLogic.toFraction(camera: fit, drawing: drawing, px: 5, py: 5))
    }

    func testWikiRedirectAndContentClassifiers() {
        XCTAssertEqual(
            ArtifactDetailLogic.wikiRedirectPath(type: .note, path: "guides/setup guide", showVersions: false),
            "/wiki/guides/setup%20guide"
        )
        XCTAssertNil(ArtifactDetailLogic.wikiRedirectPath(type: .note, path: "guides/setup", showVersions: true))
        XCTAssertNil(ArtifactDetailLogic.wikiRedirectPath(type: .spec, path: "guides/setup", showVersions: false))

        XCTAssertTrue(ArtifactDetailLogic.isPDF(contentType: "application/pdf"))
        XCTAssertTrue(ArtifactDetailLogic.isPDF(contentType: "application/octet-stream", filename: "Report.PDF"))
        XCTAssertTrue(ArtifactDetailLogic.isImage(contentType: "image/png"))
        XCTAssertTrue(ArtifactDetailLogic.isInlineVideo(contentType: "video/mp4"))
        XCTAssertFalse(ArtifactDetailLogic.isInlineVideo(contentType: "video/webm"))
    }
}
