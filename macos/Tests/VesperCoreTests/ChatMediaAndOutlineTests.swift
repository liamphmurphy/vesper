import XCTest
@testable import VesperCore

final class ChatMediaAndOutlineTests: XCTestCase {
    func testGalleryAndProductParsingAndSanitization() {
        let galleryJSON = """
        {
          "title": "Article Stills",
          "items": [
            {"image": "https://cdn.example/a.png", "url": "https://news.example/a", "caption": "Main view", "source": "News"},
            {"image": "javascript:alert(1)", "url": "ftp://bad.example/file"}
          ]
        }
        """
        let gallery = ChatGallerySpec.parse(galleryJSON)
        XCTAssertEqual(gallery?.title, "Article Stills")
        XCTAssertEqual(gallery?.items.count, 1)
        XCTAssertEqual(gallery?.items.first?.image, "https://cdn.example/a.png")

        let productJSON = """
        {
          "title": "Top Docks",
          "items": [
            {
              "name": "CalDigit TS4",
              "url": "https://shop.example/ts4",
              "image": "https://cdn.example/ts4.jpg",
              "price": "$399",
              "rating": "4.8/5",
              "badge": "Best overall",
              "specs": ["18 ports", "98W charging"]
            }
          ]
        }
        """
        let product = ChatProductSpec.parse(productJSON)
        XCTAssertEqual(product?.items.count, 1)
        XCTAssertEqual(product?.items.first?.price, "$399")
        XCTAssertEqual(product?.items.first?.specs, ["18 ports", "98W charging"])
    }

    func testTranscriptParsesGalleryAndProductSegments() {
        let md = """
        Here are the options:

        ```gallery
        {"title":"Photos","items":[{"image":"https://cdn.example/1.jpg","caption":"Shot 1"}]}
        ```

        ```product
        {"items":[{"name":"Lamp","url":"https://shop.example/lamp","price":"$65"}]}
        ```
        """
        let parsed = ChatTranscriptLogic.parseMessage(md, extractSources: true)
        let hasGallery = parsed.segments.contains { if case .gallery = $0 { return true }; return false }
        let hasProduct = parsed.segments.contains { if case .product = $0 { return true }; return false }
        XCTAssertTrue(hasGallery)
        XCTAssertTrue(hasProduct)
    }

    func testOutlineExtractsBookmarksChecklistsLinksAndCode() {
        let msg = API.ChatMessage(
            bodyMd: """
            Checklist:
            - [ ] Write migration
            - [ ] Add tests

            ```diff
            {"title":"Fix race","before":"a","after":"b"}
            ```

            Sources:
            1. [Spec](https://spec.example/v1)
            """,
            bookmarked: true,
            checklistState: ["0": true],
            createdAt: "2026-11-23T12:00:00Z",
            id: "m-1",
            role: .assistant,
            seq: 2
        )
        let items = ChatOutlineLogic.build(messages: [msg])
        let counts = ChatOutlineLogic.counts(items)
        XCTAssertEqual(counts[.bookmarks], 1)
        XCTAssertEqual(counts[.checklists], 1)
        XCTAssertEqual(counts[.code], 1)
        XCTAssertEqual(counts[.links], 1)

        let checklist = ChatOutlineLogic.filter(items, category: .checklists, query: "").first
        XCTAssertEqual(checklist?.badge, "1/2")
    }

    func testQuoteForComposerFormatsMentionAndBlockquote() {
        let quoted = ChatQuoteLogic.quoteForComposer("Line 1\nLine 2", mention: "Tech Lead")
        XCTAssertEqual(quoted, "@Tech Lead \n\n> Line 1\n> Line 2\n\n")
        XCTAssertEqual(ChatQuoteLogic.defaultTicketTitle(from: "## Fix SSE reconnect\nDetails", fallback: "Chat"), "Fix SSE reconnect")
    }

    func testInspectorIncludesOutlineTabWithBookmarkBadge() {
        let msg = API.ChatMessage(
            bodyMd: "Important decision",
            bookmarked: true,
            createdAt: "2026-11-23T12:00:00Z",
            id: "m-1",
            role: .assistant,
            seq: 1
        )
        let inspector = ChatInspectorLogic.buildInspectorModel(ChatInspectorLogic.Input(
            chatId: "chat-1",
            messages: [msg]
        ))
        let outline = inspector.tabs.first { $0.id == ChatInspectorLogic.outlineTabId }
        XCTAssertNotNil(outline)
        XCTAssertEqual(outline?.badge?.text, "1")
    }
}
