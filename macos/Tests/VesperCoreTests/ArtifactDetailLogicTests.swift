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

    func testNavModelListsVersionsBacklinksAndDecodesCommands() {
        let actor = API.Actor(name: "Liam", type: .user)
        let content = API.ArtifactContent(contentType: "text/markdown", kind: .markdown, sections: 0, sizeBytes: 128)
        let v1 = API.ArtifactVersion(content: content, createdAt: "2026-11-20T00:00:00Z", createdBy: actor, id: "v1", label: "v1", note: "Initial", seq: 1)
        let v2 = API.ArtifactVersion(
            content: content,
            createdAt: "2026-11-21T00:00:00Z",
            createdBy: actor,
            id: "v2",
            label: "v2",
            note: "Revised",
            review: API.MockupReview(note: "Looks good", pins: [], state: .approved),
            seq: 2
        )
        let artifact = API.Artifact(
            author: actor,
            createdAt: "2026-11-20T00:00:00Z",
            currentVersion: v2,
            displayId: "SPEC-1",
            id: "art-1",
            outline: [],
            readBy: [],
            suggestions: 0,
            summary: "",
            tickets: [],
            title: "Sidebar spec",
            type: .spec,
            updatedAt: "2026-11-21T00:00:00Z",
            versions: [v1, v2]
        )
        let backlinks = API.Backlinks(
            linked: [
                API.Mention(
                    snippets: [],
                    source: API.LinkTarget(displayId: "PAY-7", href: "/tickets/PAY-7", kind: .ticket, title: "Wire sidebar"),
                    sourceId: "t1",
                    sourceKind: .ticket
                ),
            ],
            unlinked: []
        )
        let nav = ArtifactDetailLogic.navModel(artifact: artifact, selectedVersionId: "v1", backlinks: backlinks)
        XCTAssertEqual(nav.id, ArtifactDetailLogic.navId)
        XCTAssertEqual(nav.selectedId, "ver:v1")
        XCTAssertEqual(nav.sections.map(\.id), ["versions", "backlinks"])
        XCTAssertEqual(nav.sections[0].items.map(\.id), ["ver:v2", "ver:v1"])
        XCTAssertEqual(nav.sections[0].items.first?.trailing, "Current")
        XCTAssertEqual(nav.sections[0].items.first?.status, .done)
        XCTAssertEqual(nav.sections[1].items.first?.href, "/tickets/PAY-7")

        XCTAssertEqual(
            ArtifactDetailLogic.navAction(for: .navAction(navigatorId: ArtifactDetailLogic.navId, actionId: ArtifactDetailLogic.backToLibraryAction)),
            .backToLibrary
        )
        XCTAssertEqual(
            ArtifactDetailLogic.navAction(for: .navActivate(navigatorId: ArtifactDetailLogic.navId, itemId: "ver:v1")),
            .selectVersion("v1")
        )
        XCTAssertEqual(
            ArtifactDetailLogic.navAction(for: .navActivate(navigatorId: ArtifactDetailLogic.navId, itemId: "link:/tickets/PAY-7", newTab: true)),
            .openLink("/tickets/PAY-7", newTab: true)
        )
    }
}
