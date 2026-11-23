import XCTest
@testable import VesperCore

private func item(
    _ id: String = "i1", kind: API.LibraryItemKind = .image, filename: String = "a.png", size: Int = 10,
    reference: API.LibraryReferenceRole? = nil, personaId: String? = nil, personaName: String? = nil,
    linkStatus: API.LibraryLinkStatus? = nil, videoId: String? = nil, detail: String? = nil,
    source: API.LibraryItem.Source? = .generated
) -> API.LibraryItem {
    API.LibraryItem(
        contentType: "image/png", createdAt: "2026-11-07T12:00:00Z", detail: detail, filename: filename, id: id, kind: kind,
        linkStatus: linkStatus, reference: reference, referencePersonaId: personaId, referencePersonaName: personaName,
        sizeBytes: size, source: source, title: "T", videoId: videoId)
}

/// Ported from web/lib/library-ui.test.mjs, plus the helpers the web Library screen used.
final class LibraryLogicTests: XCTestCase {
    func testCheckUploadTakesImagesAudioAndFilesUpTo25MBAndTurnsExecutablesAway() {
        let max = LibraryLogic.uploadMaxBytes
        XCTAssertNil(LibraryLogic.checkUpload(name: "me.jpg", type: "image/jpeg", size: 1000))
        XCTAssertNil(LibraryLogic.checkUpload(name: "me.webp", type: "image/webp", size: max))
        // Anything else is kept as a file; only executables and disk images are refused.
        for name in ["notes.pdf", "x.svg", "render.py", "bundle.zip", "q3.csv", "model.xlsx", "README"] {
            XCTAssertNil(LibraryLogic.checkUpload(name: name, type: "", size: 10), name)
        }
        for name in ["setup.exe", "Installer.MSI", "disk.iso", "tool.dmg", "app.jar"] {
            XCTAssertTrue(LibraryLogic.checkUpload(name: name, type: "", size: 10)?.contains("executables and disk images") == true, name)
        }
        // A picture that isn't one of the image types is a mistake worth catching early.
        XCTAssertTrue(LibraryLogic.checkUpload(name: "me.png", type: "image/bmp", size: 10)?.contains("isn\u{2019}t a PNG, JPEG, GIF or WebP image") == true)
        for name in ["memo.mp3", "memo.WAV", "memo.ogg", "memo.m4a"] {
            XCTAssertNil(LibraryLogic.checkUpload(name: name, type: "", size: 1000), name)
        }
        XCTAssertNil(LibraryLogic.checkUpload(name: "memo.flac", type: "audio/flac", size: 10), "other audio is kept as a file")
        XCTAssertTrue(LibraryLogic.checkUpload(name: "memo.wav", type: "audio/wav", size: max + 1)?.contains("25 MB") == true)
        XCTAssertTrue(LibraryLogic.checkUpload(name: "memo.mp3", type: "audio/mpeg", size: 0)?.contains("empty") == true)
        XCTAssertTrue(LibraryLogic.checkUpload(name: "e.png", type: "image/png", size: 0)?.contains("empty") == true)
        XCTAssertTrue(LibraryLogic.checkUpload(name: "big.png", type: "image/png", size: max + 1)?.contains("25 MB") == true)
    }

    func testReferenceBadgeNamesWhomAReferenceShows() {
        XCTAssertNil(LibraryLogic.referenceBadge(item()))
        XCTAssertEqual(LibraryLogic.referenceBadge(item(reference: .`self`)), "You")
        XCTAssertEqual(LibraryLogic.referenceBadge(item(reference: .persona, personaId: "p1", personaName: "Gwen")), "Gwen")
        // A persona reference whose persona is gone isn't one.
        XCTAssertNil(LibraryLogic.referenceBadge(item(reference: .persona)))
        XCTAssertEqual(LibraryLogic.referenceCaption(item(reference: .`self`)), "Your reference")
        XCTAssertEqual(LibraryLogic.referenceCaption(item(reference: .persona, personaId: "p1", personaName: "Gwen")), "Gwen's reference")
        XCTAssertNil(LibraryLogic.referenceCaption(item()))
    }

    func testReferenceChoicesOfferThePersonThenEachPersonaMinusTheCurrentRole() {
        let personas = [(id: "p1", name: "Gwen"), (id: "p2", name: "Ada")]
        XCTAssertEqual(LibraryLogic.referenceChoices(item(), personas: personas).map(\.label),
                       ["Use as my reference", "Use as Gwen's reference", "Use as Ada's reference"])
        XCTAssertEqual(LibraryLogic.referenceChoices(item(reference: .`self`), personas: personas).map(\.key), ["persona:p1", "persona:p2"])
        let choices = LibraryLogic.referenceChoices(item(reference: .persona, personaId: "p1"), personas: personas)
        XCTAssertEqual(choices.map(\.key), ["self", "persona:p2"])
        XCTAssertEqual(choices[1], LibraryLogic.ReferenceChoice(key: "persona:p2", label: "Use as Ada's reference", role: .persona, personaId: "p2"))
    }

    func testTabsAndNavigatorMatchTheWeb() {
        XCTAssertEqual(LibraryLogic.keepsakeTabs.map(\.label), ["Images", "Videos", "Audio", "Files", "Exports", "Diagrams", "Documents", "Links", "Fridge"])
        XCTAssertEqual(LibraryLogic.tab("videos").kind, .video)
        XCTAssertEqual(LibraryLogic.tab("nope").key, "images")
        XCTAssertNil(LibraryLogic.tab("fridge").kind)
        let nav = LibraryLogic.keepsakesNavigator(tab: "audio")
        XCTAssertEqual(nav.id, "library")
        XCTAssertEqual(nav.picker?.value, "yours")
        XCTAssertEqual(nav.picker?.options.map(\.label), ["Yours", "From spaces"])
        XCTAssertEqual(nav.selectedId, "audio")

        let counts = API.ArtifactCounts(adr: 1, all: 9, design: 0, mockup: 2, note: 3, prd: 3, report: 0, spec: 0)
        let action = NavAction(id: "project", label: "Space", icon: "folder")
        let docs = LibraryLogic.projectDocsNavigator(type: "prd", counts: counts, search: "ledger", projectAction: action)
        XCTAssertEqual(docs.picker?.value, "projects")
        XCTAssertEqual(docs.search?.value, "ledger")
        XCTAssertEqual(docs.search?.id, "library-search")
        XCTAssertEqual(docs.actions, [action])
        XCTAssertEqual(docs.sections[0].items.prefix(2).map { [$0.id, $0.trailing ?? ""] }, [["all", "9"], ["prd", "3"]])
        XCTAssertNil(LibraryLogic.projectDocsNavigator(type: "all", counts: nil, search: "", projectAction: action).sections[0].items[0].trailing)
    }

    func testHrefs() {
        XCTAssertEqual(LibraryLogic.sourceHref(.yours), "/library")
        XCTAssertEqual(LibraryLogic.sourceHref(.projects), "/library?source=projects")
        XCTAssertEqual(LibraryLogic.projectDocsHref(type: "all", q: "", project: nil, id: nil), "/library?source=projects")
        XCTAssertEqual(LibraryLogic.projectDocsHref(type: "prd", q: "a b", project: "PAY", id: "x1"),
                       "/library?source=projects&type=prd&q=a%20b&project=PAY&id=x1")
        XCTAssertEqual(LibraryLogic.contentPath("i1"), "/api/v1/library/i1/content")
        XCTAssertEqual(LibraryLogic.contentPath("i1", download: true), "/api/v1/library/i1/content?download=true")
    }

    func testTileCaptions() {
        XCTAssertEqual(LibraryLogic.typeBadge("render.py"), "PY")
        XCTAssertEqual(LibraryLogic.typeBadge("model.xlsx"), "XLSX")
        XCTAssertEqual(LibraryLogic.typeBadge("archive.tar.gzip"), "GZIP")
        XCTAssertEqual(LibraryLogic.typeBadge("README"), "FILE")
        XCTAssertEqual(LibraryLogic.fileMeta(item(size: 4096, detail: "112 lines")), "112 lines · 4 KB")
        XCTAssertEqual(LibraryLogic.fileMeta(item(size: 100)), "100 B")
        XCTAssertEqual(LibraryLogic.noun(.audio), "audio file")
        XCTAssertEqual(LibraryLogic.noun(.image), "image")
        XCTAssertEqual(LibraryLogic.noun(.link), "link")
        XCTAssertNil(LibraryLogic.removeExplanation(item(source: .upload)))
        XCTAssertEqual(LibraryLogic.removeExplanation(item()), "It stays in its chat while that chat exists.")
        XCTAssertTrue(LibraryLogic.emptyText(.export).hasPrefix("No exports yet."))
        XCTAssertTrue(LibraryLogic.isPDF("application/pdf; charset=binary"))
        XCTAssertFalse(LibraryLogic.isPDF("image/png"))
        XCTAssertEqual(LibraryLogic.exportApp(.init(rawValue: "slides")).href, "/apps/slides")
        XCTAssertEqual(LibraryLogic.exportSourceNote(.init(rawValue: "changed")), "edited since")
    }

    func testBulkDeleteHelpers() {
        XCTAssertEqual(LibraryLogic.bulkDeleteBatches([]), [])
        XCTAssertEqual(LibraryLogic.bulkDeleteBatches(["", "a", "b", "a", "", "c"], maxBatchSize: 2), [["a", "b"], ["c"]])
        XCTAssertEqual(LibraryLogic.bulkDeleteBatches(["a", "b", "c"], maxBatchSize: 5), [["a", "b", "c"]])

        XCTAssertNil(LibraryLogic.removeConfirmation([]))
        let singleUpload = LibraryLogic.removeConfirmation([item("u1", kind: .image, source: .upload)])
        XCTAssertEqual(singleUpload?.title, "Remove this image from your Library?")
        XCTAssertNil(singleUpload?.body)

        let singleLink = LibraryLogic.removeConfirmation([item("l1", kind: .link, source: .generated)])
        XCTAssertEqual(singleLink?.title, "Remove this link from your Library?")
        XCTAssertEqual(singleLink?.body, "It stays in its chat while that chat exists.")

        let multiUpload = LibraryLogic.removeConfirmation([item("u1", source: .upload), item("u2", source: .upload)])
        XCTAssertEqual(multiUpload?.title, "Remove 2 items from your Library?")
        XCTAssertNil(multiUpload?.body)

        let multiMixed = LibraryLogic.removeConfirmation([item("u1", source: .upload), item("g1", source: .generated)])
        XCTAssertEqual(multiMixed?.title, "Remove 2 items from your Library?")
        XCTAssertEqual(multiMixed?.body, "Items from chats stay in their chats while those chats exist.")

        XCTAssertNil(LibraryLogic.deleteMomentsConfirmation(count: 0))
        let oneMoment = LibraryLogic.deleteMomentsConfirmation(count: 1)
        XCTAssertEqual(oneMoment?.title, "Delete this moment?")
        XCTAssertEqual(oneMoment?.body, "Its persona will no longer remember it.")
        let manyMoments = LibraryLogic.deleteMomentsConfirmation(count: 4)
        XCTAssertEqual(manyMoments?.title, "Delete 4 moments?")
        XCTAssertEqual(manyMoments?.body, "Their personas will no longer remember them.")
    }

    func testFormatting() {
        XCTAssertEqual(LibraryLogic.formatBytes(512), "512 B")
        XCTAssertEqual(LibraryLogic.formatBytes(17 * 1024), "17 KB")
        XCTAssertEqual(LibraryLogic.formatBytes(1_258_291), "1.2 MB")
        XCTAssertEqual(LibraryLogic.clock(42_900), "0:42")
        XCTAssertEqual(LibraryLogic.clock(725_000), "12:05")
        XCTAssertEqual(LibraryLogic.clock(3_723_000), "1:02:03")
        XCTAssertEqual(LibraryLogic.audioFormat(contentType: "audio/mpeg", filename: "memo.mp3"), "MP3")
        XCTAssertEqual(LibraryLogic.audioFormat(contentType: "audio/ogg", filename: "memo"), "OGG")
        XCTAssertEqual(LibraryLogic.nextSpeed(1), 1.25)
        XCTAssertEqual(LibraryLogic.nextSpeed(2), 0.75)
    }

    func testWaveBarsResamplePeaksAndDrawAFlatLineWithout() {
        XCTAssertEqual(LibraryLogic.waveBars(nil, count: 3), [0.08, 0.08, 0.08])
        let peaks = (0..<64).map { $0 * 4 }
        let bars = LibraryLogic.waveBars(peaks, count: 32)
        XCTAssertEqual(bars.count, 32)
        // Each bar is the loudest of its two buckets.
        XCTAssertEqual(bars[10], Double(21 * 4) / 255, accuracy: 0.0001)
        XCTAssertEqual(bars[0], 0.08, "quiet buckets keep a visible minimum")
    }

    func testLinksSplitIntoQueuesAndFilterByVideo() {
        let items = [item("a"), item("b", videoId: "yt1"), item("c", linkStatus: .done), item("d", linkStatus: .done, videoId: "yt2")]
        XCTAssertEqual(LibraryLogic.links(items, queue: .toRead, filter: .all).map(\.id), ["a", "b"])
        XCTAssertEqual(LibraryLogic.links(items, queue: .toRead, filter: .video).map(\.id), ["b"])
        XCTAssertEqual(LibraryLogic.links(items, queue: .done, filter: .page).map(\.id), ["c"])
        XCTAssertEqual(LibraryLogic.linkCount(items, queue: .done), 2)
        XCTAssertEqual(LibraryLogic.host("https://www.youtube.com/watch?v=1"), "youtube.com")
        XCTAssertEqual(LibraryLogic.host("not a url"), "not a url")
        XCTAssertEqual(LibraryLogic.summaryText("It scales [1] well [2].\n\n---\n\n**Sources:**\n1. [Docs](https://a.dev)\n2. https://b.dev"),
                       "It scales well.")
        XCTAssertEqual(LibraryLogic.summaryText("Links: see below for more [x](https://a.dev)"), "Links: see below for more [x](https://a.dev)")
        XCTAssertEqual(LibraryLogic.summaryText("Sources\nwere unclear."), "Sources\nwere unclear.", "prose after the word stays")
    }

    func testArtifactHelpers() {
        XCTAssertEqual(LibraryLogic.artifactTitle(title: "Partitioning", displayId: "ADR-012"), "ADR-012 · Partitioning")
        XCTAssertEqual(LibraryLogic.artifactTitle(title: "Spec", displayId: nil), "Spec")
        XCTAssertEqual(LibraryLogic.fileKind(contentType: "image/svg+xml", filename: nil), "SVG")
        XCTAssertEqual(LibraryLogic.fileKind(contentType: "application/pdf", filename: "spec.pdf"), "PDF")
        XCTAssertEqual(LibraryLogic.fileKind(contentType: "image/png", filename: "noext"), "PNG")

        let agent = API.Actor(name: "Ada", type: .agent)
        let report = API.ArtifactSummary(author: agent, content: .init(contentType: "text/markdown", kind: .init(rawValue: "markdown"), sections: 5, sizeBytes: 10),
                                         id: "a", summary: "", ticketCount: 0, title: "R", type: .report, updatedAt: "2026-11-07T12:00:00Z", versionLabel: "v2")
        XCTAssertEqual(LibraryLogic.artifactMeta(report), "Generated · 5 sections")
        var file = report
        file.type = .design
        file.content = .init(contentType: "image/png", filename: "x.png", kind: .init(rawValue: "file"), sections: 0, sizeBytes: 17 * 1024)
        XCTAssertEqual(LibraryLogic.artifactMeta(file), "v2 · PNG · 17 KB")

        func section(_ id: String, _ level: Int) -> API.OutlineSection { .init(anchor: id, citations: 0, heading: id, id: id, level: level) }
        XCTAssertEqual(LibraryLogic.visibleOutline([section("t", 1), section("a", 2), section("b", 2), section("c", 3)]).map(\.id), ["a", "b"])
        XCTAssertEqual(LibraryLogic.visibleOutline([section("x", 1), section("y", 1), section("a", 2)]).map(\.id), ["x", "y"])

        XCTAssertEqual(LibraryLogic.guessType(name: "Ledger PRD.md", mime: ""), .prd)
        XCTAssertEqual(LibraryLogic.guessType(name: "adr-12 decision.md", mime: ""), .adr)
        XCTAssertEqual(LibraryLogic.guessType(name: "weekly report.md", mime: ""), .report)
        XCTAssertEqual(LibraryLogic.guessType(name: "screen.png", mime: "image/png"), .design)
        XCTAssertEqual(LibraryLogic.guessType(name: "flows.pdf", mime: ""), .design)
        XCTAssertEqual(LibraryLogic.guessType(name: "api.md", mime: "text/markdown"), .spec)
        XCTAssertTrue(LibraryLogic.isSVGFile(name: "A.SVG", mime: ""))

        let svg = LibraryLogic.blankWireframe(title: " Settings <beta> ")
        XCTAssertTrue(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1280\" height=\"800\""))
        XCTAssertTrue(svg.contains(">Settings &lt;beta&gt;</text>"))
        XCTAssertTrue(svg.contains("\n    <rect x=\"24\" y=\"96\" width=\"140\" height=\"12\" rx=\"6\" fill=\"#D9DCE3\"/>\n"))
        XCTAssertTrue(svg.hasSuffix("</svg>\n"))
        XCTAssertTrue(LibraryLogic.blankWireframe(title: "  ").contains(">Untitled mockup</text>"))
    }

    func testTimelineAndShortAgo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = APIDate.parse("2026-11-07T12:00:00Z")!
        XCTAssertEqual(APIDate.timeline("2026-11-07T11:59:30Z", now: now, calendar: calendar, locale: locale), "just now")
        XCTAssertEqual(APIDate.timeline("2026-11-07T11:48:00Z", now: now, calendar: calendar, locale: locale), "12m ago")
        XCTAssertEqual(APIDate.timeline("2026-11-07T09:05:00Z", now: now, calendar: calendar, locale: locale), "09:05")
        XCTAssertEqual(APIDate.timeline("2026-10-31T09:12:00Z", now: now, calendar: calendar, locale: locale), "Oct 31, 09:12")
        XCTAssertEqual(APIDate.timeline("2026-09-30T09:12:00Z", now: now, calendar: calendar, locale: locale), "Sep 30")
        XCTAssertEqual(APIDate.shortAgo("2026-11-07T11:59:30Z", now: now, calendar: calendar, locale: locale), "now")
        XCTAssertEqual(APIDate.shortAgo("2026-11-07T07:00:00Z", now: now, calendar: calendar, locale: locale), "5h")
        XCTAssertEqual(APIDate.shortAgo("2026-11-04T12:00:00Z", now: now, calendar: calendar, locale: locale), "Wed")
        XCTAssertEqual(APIDate.shortAgo("2026-10-30T12:00:00Z", now: now, calendar: calendar, locale: locale), "Oct 30")
    }
}

final class LibrarySelectionTests: XCTestCase {
    private let ids = ["a", "b", "c", "d", "e"]

    func testClickToggleAndExtend() {
        var s = LibrarySelection()
        s.click("b", in: ids)
        XCTAssertEqual(s.selected, ["b"])
        s.click("d", in: ids, modifier: .extend)
        XCTAssertEqual(s.selected, ["b", "c", "d"])
        XCTAssertEqual(s.focused, "d")
        s.click("a", in: ids, modifier: .toggle)
        XCTAssertEqual(s.selected, ["a", "b", "c", "d"])
        s.click("c", in: ids, modifier: .toggle)
        XCTAssertEqual(s.selected, ["a", "b", "d"])
        XCTAssertEqual(s.targets(for: "b", in: ids), ["a", "b", "d"])
        XCTAssertEqual(s.targets(for: "e", in: ids), ["e"], "a tile outside the selection acts alone")
        s.click("e", in: ids)
        XCTAssertEqual(s.selected, ["e"])
    }

    func testArrowKeysMoveByOneOrByARowAndStayInside() {
        var s = LibrarySelection()
        s.move(by: 1, in: ids)
        XCTAssertEqual(s.focused, "a", "the first arrow press starts at the first tile")
        s.move(by: 3, in: ids)
        XCTAssertEqual(s.focused, "d")
        s.move(by: 3, in: ids)
        XCTAssertEqual(s.focused, "e")
        s.move(by: -1, in: ids, extend: true)
        XCTAssertEqual(s.selected, ["d", "e"])
        s.move(by: -10, in: ids)
        XCTAssertEqual(s.selected, ["a"])
    }

    func testSelectAllAndPrune() {
        var s = LibrarySelection()
        s.click("c", in: ids)
        s.selectAll(ids)
        XCTAssertEqual(s.selected.count, 5)
        XCTAssertEqual(s.focused, "c")
        s.prune(to: ["a", "b"])
        XCTAssertEqual(s.selected, ["a", "b"])
        XCTAssertEqual(s.focused, "a")
        XCTAssertEqual(s.ordered(["b", "x", "a"]), ["b", "a"])
        s.clear()
        XCTAssertTrue(s.selected.isEmpty)
        XCTAssertNil(s.focused)
    }

    func testSelectModeHelpersAndAnchorReset() {
        XCTAssertEqual(LibrarySelection.tapModifier(selecting: false, command: false, shift: false), .none)
        XCTAssertEqual(LibrarySelection.tapModifier(selecting: false, command: true, shift: false), .toggle)
        XCTAssertEqual(LibrarySelection.tapModifier(selecting: false, command: false, shift: true), .extend)
        XCTAssertEqual(LibrarySelection.tapModifier(selecting: true, command: false, shift: false), .toggle)
        XCTAssertEqual(LibrarySelection.tapModifier(selecting: true, command: false, shift: true), .extend)

        var s = LibrarySelection()
        XCTAssertFalse(s.showsBar(selecting: false))
        XCTAssertTrue(s.showsBar(selecting: true))
        XCTAssertFalse(s.isAllSelected(in: []))
        XCTAssertFalse(s.isAllSelected(in: ids))

        s.click("b", in: ids, modifier: .toggle)
        XCTAssertFalse(s.showsBar(selecting: false))
        s.click("b", in: ids, modifier: .toggle)
        XCTAssertTrue(s.selected.isEmpty)
        XCTAssertNil(s.anchor, "deselecting the anchor clears it so a later shift-click starts fresh")
        s.click("d", in: ids, modifier: .extend)
        XCTAssertEqual(s.selected, ["d"])

        s.toggleAll(ids)
        XCTAssertTrue(s.isAllSelected(in: ids))
        XCTAssertTrue(s.showsBar(selecting: false))
        s.toggleAll(ids)
        XCTAssertTrue(s.selected.isEmpty)
    }
}
