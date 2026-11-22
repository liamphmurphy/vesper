import XCTest
@testable import VesperCore

final class KnowledgeInspectorLogicTests: XCTestCase {
    func testExtractHeadingsSkipsCodeFencesAndTracksSegments() {
        let md = """
        # Top Title

        Intro paragraph.

        ```markdown
        # Not A Heading
        ```

        ## Details

        | Col A | Col B |
        | --- | --- |
        | 1 | 2 |

        ### After Table
        """
        let headings = KnowledgeInspectorLogic.extractHeadings(from: md)
        XCTAssertEqual(headings.map(\.level), [1, 2, 3])
        XCTAssertEqual(headings.map(\.text), ["Top Title", "Details", "After Table"])
        XCTAssertEqual(headings.map(\.index), [0, 1, 2])
        XCTAssertEqual(headings[0].segmentIndex, 0)
        XCTAssertEqual(headings[1].segmentIndex, 0)
        // The third heading sits in the prose segment after the table segment.
        XCTAssertGreaterThan(headings[2].segmentIndex, headings[1].segmentIndex)
        XCTAssertEqual(KnowledgeInspectorLogic.parseHeadingIndex(from: headings[2].id), 2)
        XCTAssertNil(KnowledgeInspectorLogic.parseHeadingIndex(from: "invalid"))
    }

    func testBuildOutlineSectionsEmptyAndIndentedHierarchy() {
        let empty = KnowledgeInspectorLogic.buildOutlineSections(headings: [])
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty[0].title, "Outline")
        XCTAssertTrue(empty[0].items.isEmpty)
        XCTAssertNotNil(empty[0].emptyText)

        let headings = [
            KnowledgeOutlineHeading(index: 0, level: 2, text: "Overview", segmentIndex: 0, utf16Location: 0, utf16Length: 11),
            KnowledgeOutlineHeading(index: 1, level: 3, text: "Architecture", segmentIndex: 0, utf16Location: 12, utf16Length: 16),
            KnowledgeOutlineHeading(index: 2, level: 4, text: "Details", segmentIndex: 0, utf16Location: 30, utf16Length: 12),
        ]
        let sections = KnowledgeInspectorLogic.buildOutlineSections(headings: headings)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].aside, "3")
        XCTAssertEqual(sections[0].items.first?.kind, .list)
        XCTAssertEqual(sections[0].items.first?.actionId, KnowledgeInspectorLogic.jumpHeadingActionId)
        let rows = sections[0].items.first?.rows ?? []
        XCTAssertEqual(rows.map(\.title), ["Overview", "  ↳ Architecture", "    ↳ Details"])
        XCTAssertEqual(rows.map(\.trailing), ["H2", "H3", "H4"])
    }

    func testBuildInspectorModelForMarkdownPageIncludesAllRightRailTabs() {
        let review = KnowledgeReview(
            id: "rev-1",
            state: "pending",
            changes: [
                KnowledgePageChange(raw: ["index": .int(0), "state": .string("pending"), "before": .string("a"), "after": .string("b")]),
            ]
        )
        let page = KnowledgePage(
            id: "page-1",
            title: "Design Notes",
            path: "Notes/Design Notes",
            audience: .private,
            kind: .document,
            bodyMd: "# Intro\n## Goals",
            versionId: "v1",
            reviews: [review]
        )
        let headings = KnowledgeInspectorLogic.extractHeadings(from: page.bodyMd ?? "")
        let model = KnowledgeInspectorLogic.buildInspectorModel(
            destination: .page(id: page.id),
            loadedPage: page,
            headings: headings,
            open: true,
            activeTabId: KnowledgeInspectorLogic.outlineTabId
        )

        XCTAssertEqual(model.id, KnowledgeInspectorLogic.modelId)
        XCTAssertTrue(model.open)
        XCTAssertEqual(model.activeTabId, KnowledgeInspectorLogic.outlineTabId)
        XCTAssertEqual(
            model.tabs.map(\.id),
            ["chat", "outline", "links", "properties", "query", "history", "reviews", "calendar"]
        )
        XCTAssertEqual(model.tabs.first(where: { $0.id == "chat" })?.kind, .panel)
        XCTAssertEqual(model.tabs.first(where: { $0.id == "chat" })?.panel?.kind, "knowledge.chat")
        XCTAssertEqual(model.tabs.first(where: { $0.id == "chat" })?.panel?.key, "knowledge.chat:page-1")
        XCTAssertEqual(model.tabs.first(where: { $0.id == "outline" })?.sections?.first?.aside, "2")
        XCTAssertEqual(model.tabs.first(where: { $0.id == "reviews" })?.unread, true)
        XCTAssertEqual(model.tabs.first(where: { $0.id == "calendar" })?.kind, .native)
        XCTAssertNil(model.tabs.first(where: { $0.id == "calendar" })?.panel)
    }

    func testBuildInspectorModelForNonMarkdownPageOmitsOutline() {
        let docPage = KnowledgePage(
            id: "doc-1",
            title: "Spec",
            path: "Docs/Spec",
            audience: .private,
            kind: .document,
            canvasId: "canvas-1",
            bodyMd: nil,
            versionId: "v1"
        )
        let model = KnowledgeInspectorLogic.buildInspectorModel(
            destination: .page(id: docPage.id),
            loadedPage: docPage,
            headings: [],
            open: false,
            activeTabId: KnowledgeInspectorLogic.outlineTabId
        )
        XCTAssertFalse(model.tabs.contains(where: { $0.id == KnowledgeInspectorLogic.outlineTabId }))
        // Falls back to first available tab when outline isn't present.
        XCTAssertEqual(model.activeTabId, KnowledgeInspectorLogic.chatTabId)
    }

    func testBuildInspectorModelForNonPageDestinations() {
        let model = KnowledgeInspectorLogic.buildInspectorModel(
            destination: .graph,
            loadedPage: nil,
            headings: [],
            generalChatId: "chat-general-1",
            open: true,
            activeTabId: "links"
        )
        XCTAssertEqual(model.tabs.map(\.id), ["chat", "calendar"])
        XCTAssertEqual(model.activeTabId, "chat")
        let propsJson = model.tabs[0].panel?.propsJson ?? ""
        XCTAssertTrue(propsJson.contains("\"screen\":\"Graph\""))
        XCTAssertTrue(propsJson.contains("\"chatId\":\"chat-general-1\""))
        XCTAssertEqual(
            KnowledgeInspectorLogic.parseGeneralChatId(from: "{\"chatId\":\"c-42\"}"),
            "c-42"
        )
    }
}
