import XCTest
@testable import VesperCore

final class CommandPaletteLogicTests: XCTestCase {
    func testParseFiltersPrefixesAndTokens() {
        let people = CommandPaletteLogic.parseFilters("@meow")
        XCTAssertEqual(people.types, [.people])
        XCTAssertEqual(people.text, "meow")

        let tickets = CommandPaletteLogic.parseFilters("# status:in_progress palette")
        XCTAssertEqual(tickets.types, [.ticket])
        XCTAssertEqual(tickets.status, "in_progress")
        XCTAssertEqual(tickets.text, "palette")
        XCTAssertEqual(tickets.tokens, ["status:in_progress"])

        let synonyms = CommandPaletteLogic.parseFilters("is:note in:project is:unknown roadmap")
        XCTAssertEqual(synonyms.types, [.page, .space])
        XCTAssertEqual(synonyms.text, "is:unknown roadmap")
        XCTAssertEqual(synonyms.tokens, ["is:note", "in:project"])
    }

    func testRemoveTokenAndStripTypeFilters() {
        XCTAssertEqual(CommandPaletteLogic.removeToken("is:ticket status:done deploy", token: "status:done"), "is:ticket deploy")
        XCTAssertEqual(CommandPaletteLogic.stripTypeFilters(from: "@ is:people status:open alice"), "status:open alice")
        XCTAssertEqual(CommandPaletteLogic.stripTypeFilters(from: "#LAZY-42"), "LAZY-42")
    }

    func testTicketKeyFrom() {
        XCTAssertEqual(CommandPaletteLogic.ticketKeyFrom("lazyagents-39"), "LAZYAGENTS-39")
        XCTAssertEqual(CommandPaletteLogic.ticketKeyFrom("42", project: "pay"), "PAY-42")
        XCTAssertNil(CommandPaletteLogic.ticketKeyFrom("42", project: nil))
        XCTAssertNil(CommandPaletteLogic.ticketKeyFrom("not a key", project: "PAY"))
    }

    func testKnowledgeQueryAndFolder() {
        let tagOnly = CommandPaletteLogic.parseKnowledgeQuery("#dnd")
        XCTAssertEqual(tagOnly.tag, "dnd")
        XCTAssertEqual(tagOnly.text, "")

        let tagAndText = CommandPaletteLogic.parseKnowledgeQuery("#dnd veil")
        XCTAssertEqual(tagAndText.tag, "dnd")
        XCTAssertEqual(tagAndText.text, "veil")

        let plain = CommandPaletteLogic.parseKnowledgeQuery("veilcleaver")
        XCTAssertEqual(plain.tag, "")
        XCTAssertEqual(plain.text, "veilcleaver")

        XCTAssertEqual(CommandPaletteLogic.knowledgeFolder("Campaign/Sessions/Dawn"), "Campaign / Sessions")
        XCTAssertEqual(CommandPaletteLogic.knowledgeFolder("Standalone"), "Top level")
    }

    func testPageScopeAndContext() {
        XCTAssertEqual(CommandPaletteLogic.pageScope(path: "/knowledge/123"), .knowledge)
        XCTAssertEqual(CommandPaletteLogic.pageScope(path: "/apps/designs/abc"), .knowledge)
        XCTAssertEqual(CommandPaletteLogic.pageScope(path: "/tickets", search: "?layout=epics"), .type(.epic, label: "Epics"))
        XCTAssertEqual(CommandPaletteLogic.pageScope(path: "/work?view=tickets"), .type(.ticket, label: "Tickets"))
        XCTAssertEqual(CommandPaletteLogic.pageScope(path: "/chat/abc"), .type(.chat, label: "Chats"))
        XCTAssertNil(CommandPaletteLogic.pageScope(path: "/inbox"))

        XCTAssertEqual(CommandPaletteLogic.pageContext(path: "/tickets/LAZY-412"), .ticket(key: "LAZY-412"))
        let uuid = "01a20427-8af8-7560-ae88-62e1c37d551e"
        XCTAssertEqual(CommandPaletteLogic.pageContext(path: "/knowledge/\(uuid)"), .knowledge(id: uuid))
        XCTAssertEqual(CommandPaletteLogic.pageContext(path: "/wiki/docs/dev%20guide"), .wiki(path: "docs/dev guide"))
    }

    func testMatchPartsSnippetPartsAndPlainExcerpt() {
        let parts = CommandPaletteLogic.matchParts(text: "Native Swift screens", query: "swift native")
        XCTAssertEqual(parts.map(\.text), ["Native", " ", "Swift", " screens"])
        XCTAssertEqual(parts.map(\.match), [true, false, true, false])

        let snip = CommandPaletteLogic.snippetParts("See [[docs/Native|Native App]] for «SwiftUI» details")
        XCTAssertEqual(snip.map(\.text), ["See Native App for ", "SwiftUI", " details"])
        XCTAssertEqual(snip.map(\.match), [false, true, false])
        XCTAssertTrue(CommandPaletteLogic.foundInBody(snippet: "about «SwiftUI»", title: "Command Palette"))
        XCTAssertFalse(CommandPaletteLogic.foundInBody(snippet: "about «Palette»", title: "Command Palette"))

        let excerpt = CommandPaletteLogic.plainExcerpt("# Heading\n\nCheck **bold** [[Foo|Bar]] and `code`.", max: 30)
        XCTAssertEqual(excerpt, "Heading Check bold Bar and co…")
    }

    func testGroupChatsAndRankGroups() {
        let titleHit = API.SearchHit(
            detail: "Meow",
            score: 10,
            snippet: "SwiftUI polish",
            target: API.LinkTarget(href: "/chat/c1", id: "c1", kind: .chat, title: "SwiftUI polish"),
            updatedAt: "2026-11-22T12:00:00Z"
        )
        let msgHit = API.SearchHit(
            detail: "You",
            score: 12,
            snippet: "fix «command palette» contrast",
            target: API.LinkTarget(anchor: "m1", href: "/chat/c1#m1", id: "c1", kind: .chat, title: "SwiftUI polish"),
            updatedAt: "2026-11-22T12:05:00Z"
        )
        let chats = CommandPaletteLogic.groupChats([titleHit, msgHit])
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].score, 12)
        XCTAssertTrue(chats[0].titled)
        XCTAssertEqual(chats[0].persona, "Meow")
        XCTAssertEqual(chats[0].messages.count, 1)
        XCTAssertEqual(chats[0].messages[0].id, "m1")

        let ranked = CommandPaletteLogic.rankGroups(
            [
                (.page, [1.0, 2.0]),
                (.ticket, [9.0, 8.0, 7.0, 6.0]),
            ],
            score: { $0 },
            cap: 3,
            counts: [.ticket: 5, .page: 2]
        )
        XCTAssertEqual(ranked.map(\.type), [.ticket, .page])
        XCTAssertEqual(ranked[0].items.count, 3)
        XCTAssertEqual(ranked[0].more, 2)
    }

    func testRecentsAndAttachQuery() {
        let a = CommandPaletteLink(id: "1", title: "One", href: "/a", kind: "Pages")
        let b = CommandPaletteLink(id: "2", title: "Two", href: "/b", kind: "Pages")
        let list = CommandPaletteLogic.pushRecent([a, b], item: b)
        XCTAssertEqual(list.map(\.href), ["/b", "/a"])

        let q = CommandPaletteLogic.attachQuery(project: "LAZY", kind: "ticket", idOrKey: "LAZY-42", title: "Fix palette")
        XCTAssertTrue(q.contains("project=LAZY"))
        XCTAssertTrue(q.contains("attach=ticket:LAZY-42"))
        XCTAssertTrue(q.contains("attach_title=Fix%20palette"))
    }

    func testPanelFrameCentersOnContentPaneNotFullWindow() {
        // Window is 1440×900 at (0,0) with a 220pt left sidebar and 44pt right rail:
        // content pane spans x=220..1396 (width 1176, midX = 808).
        let screen = CommandPaletteRect(x: 0, y: 0, width: 1728, height: 1080)
        let window = CommandPaletteRect(x: 100, y: 80, width: 1440, height: 900)
        let contentPane = CommandPaletteRect(x: 320, y: 80, width: 1176, height: 900)

        let frame = CommandPaletteLayout.panelFrame(
            contentPane: contentPane,
            window: window,
            visibleScreen: screen
        )
        XCTAssertEqual(frame.width, 920)
        XCTAssertEqual(frame.height, 520)
        // Centered on contentPane (midX = 320 + 588 = 908), NOT window (midX = 820)
        XCTAssertEqual(frame.midX, contentPane.midX, accuracy: 1.0)
        let leftGap = frame.minX - contentPane.minX
        let rightGap = contentPane.maxX - frame.maxX
        XCTAssertEqual(leftGap, rightGap, accuracy: 1.0)
    }

    func testPanelFrameClampsInsideVisibleScreen() {
        let screen = CommandPaletteRect(x: 0, y: 0, width: 1000, height: 700)
        let offEdgeWindow = CommandPaletteRect(x: 600, y: 50, width: 900, height: 600)
        let frame = CommandPaletteLayout.panelFrame(
            contentPane: offEdgeWindow,
            window: offEdgeWindow,
            visibleScreen: screen
        )
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + CommandPaletteLayout.screenMargin)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - CommandPaletteLayout.screenMargin)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + CommandPaletteLayout.screenMargin)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - CommandPaletteLayout.screenMargin)
    }

    func testPrefersLightTextOnAccentFixesMacOSBlueContrast() {
        // macOS Dark (#0a84ff) and Light (#007aff) blues MUST use crisp white text.
        XCTAssertTrue(CommandPaletteLogic.prefersLightText(onAccentHex: "#0a84ff"))
        XCTAssertTrue(CommandPaletteLogic.prefersLightText(onAccentHex: "#007aff"))
        XCTAssertTrue(CommandPaletteLogic.prefersLightText(onAccentHex: "#9b8cff"))
        // Bright yellow/gold accents (Gruvbox / Monokai Pro) must use dark text.
        XCTAssertFalse(CommandPaletteLogic.prefersLightText(onAccentHex: "#fabd2f"))
        XCTAssertFalse(CommandPaletteLogic.prefersLightText(onAccentHex: "#ffd866"))
    }
}
