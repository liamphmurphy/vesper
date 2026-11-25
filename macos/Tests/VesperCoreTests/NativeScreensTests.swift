import XCTest
@testable import VesperCore

final class NativeRoutesTests: XCTestCase {
    private let registry = NativeRouteRegistry(
        routes: [
            NativeRoute("/tickets/:key", .debugPlaceholder),
            NativeRoute("/knowledge/*", .debugPlaceholder),
            NativeRoute("/native-debug", .debugPlaceholder),
        ],
        enabled: [.debugPlaceholder]
    )

    func testResolvesParamsQueryAndIgnoresFragment() {
        let match = registry.resolve("/tickets/PAY-1?tab=runs&tab=ignored#activity")
        XCTAssertEqual(match, NativeRouteMatch(screen: .debugPlaceholder, path: "/tickets/PAY-1", params: ["key": "PAY-1"], query: ["tab": "runs"]))
    }

    func testSegmentsAreDecodedAndMustMatchExactly() {
        XCTAssertEqual(registry.resolve("/tickets/a%20b")?.params["key"], "a b")
        XCTAssertNil(registry.resolve("/tickets"))
        XCTAssertNil(registry.resolve("/tickets/PAY-1/runs"))
        XCTAssertNil(registry.resolve("/ticketsX/PAY-1"))
    }

    func testWildcardTakesTheRest() {
        XCTAssertEqual(registry.resolve("/knowledge/Projects/Plan%201")?.params["*"], "Projects/Plan 1")
        XCTAssertEqual(registry.resolve("/knowledge")?.params["*"], "")
    }

    func testDisabledScreensStayOnTheWebView() {
        let off = NativeRouteRegistry(routes: registry.routes, enabled: [])
        XCTAssertNil(off.resolve("/native-debug"))
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug"))
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/7")?.params["id"], "7")
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/markdown")?.screen, .markdownDebug)
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug/markdown"))
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/scenes")?.screen, .scenesDebug)
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug/scenes"))
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/embeds")?.screen, .embedsDebug)
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug/embeds"))
    }

    func testSpacesRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/spaces")?.screen, .spacesHome)
        XCTAssertEqual(standard.resolve("/spaces/new")?.screen, .spaceNew)
        let sp = standard.resolve("/spaces/sp-1")
        XCTAssertEqual(sp?.screen, .spaceDetail)
        XCTAssertEqual(sp?.params["id"], "sp-1")
        XCTAssertNil(standard.resolve("/work"))
        XCTAssertNil(standard.resolve("/tickets"))
        XCTAssertNil(standard.resolve("/epics"))
        XCTAssertNil(standard.resolve("/runs/r1"))
    }

    func testWorkflowRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/workflows")?.screen, .workflows)
        let wfRun = standard.resolve("/workflows/runs/wr-1")
        XCTAssertEqual(wfRun?.screen, .workflowRun)
        XCTAssertEqual(wfRun?.params["id"], "wr-1")
        let wfEditor = standard.resolve("/workflows/wf-1")
        XCTAssertEqual(wfEditor?.screen, .workflowEditor)
        XCTAssertEqual(wfEditor?.params["id"], "wf-1")
        XCTAssertNil(standard.resolve("/workflows/runs/wr-1/extra"))
    }

    func testChatRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/chat")?.screen, .chat)
        let detail = standard.resolve("/chat/c1?message=m42&view=archived")
        XCTAssertEqual(detail?.screen, .chatDetail)
        XCTAssertEqual(detail?.params["id"], "c1")
        XCTAssertEqual(detail?.query["message"], "m42")
        XCTAssertEqual(detail?.query["view"], "archived")
        XCTAssertNil(standard.resolve("/chat/c1/extra"))
        XCTAssertEqual(NativeScreen.chat.hostGroup, .chat)
        XCTAssertEqual(NativeScreen.chatDetail.hostGroup, .chat)
        XCTAssertNotEqual(NativeScreen.chat.hostGroup, .knowledge)
    }

    func testLibraryAndPDFViewerAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        let library = standard.resolve("/library?tab=videos&item=v1")
        XCTAssertEqual(library?.screen, .library)
        XCTAssertEqual(library?.query, ["tab": "videos", "item": "v1"])
        XCTAssertEqual(standard.resolve("/library?source=projects&type=report")?.query["source"], "projects")
        let pdf = standard.resolve("/pdf?src=%2Fapi%2Fv1%2Fknowledge%2Fassets%2Fa1&title=Spec")
        XCTAssertEqual(pdf?.screen, .pdf)
        XCTAssertEqual(pdf?.query["src"], "/api/v1/knowledge/assets/a1")
        // Only the Library's own path: other screens under it stay on the web view until they move.
        XCTAssertNil(standard.resolve("/library/anything"))
    }

    func testDevTerminalIsNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/dev")?.screen, .dev)
        XCTAssertNil(standard.resolve("/dev/anything"))
    }

    /// The area bar marks a native screen's area from its path; these match web/lib/navigator.ts's
    /// currentArea() for the same paths (old addresses like /wiki and /board follow their screen).
    func testNativeScreensBelongToTheWebsAreas() {
        let standard = NativeRouteRegistry.standard(debug: true)
        let expected: [String: AreaId?] = [
            "/chat": .chat, "/chat/c1": .chat,
            "/spaces": .spaces, "/spaces/new": .spaces, "/spaces/sp-1": .spaces,
            "/knowledge": .knowledge, "/knowledge/graph": .knowledge, "/knowledge/p1": .knowledge, "/wiki/a/b": .knowledge,
            "/library": .library, "/artifacts/art-1": .library, "/artifacts/art-1/review": .library,
            "/workflows": .apps, "/workflows/wf-1": .apps, "/workflows/runs/wr-1": .apps, "/scheduled": .apps,
            "/learn": .apps, "/learn/l1": .apps, "/reports": .apps, "/costs": .apps, "/http": .apps, "/dev": .apps,
            "/apps": .apps, "/apps/docs": .apps, "/apps/slides": .apps, "/apps/designs": .apps,
            "/apps/finance": .apps,
            "/apps/docs/d1": .knowledge, "/apps/slides/s1": .knowledge, "/apps/designs/g1": .knowledge,
            "/present/slides/s1": nil, "/present/designs/g1": nil,
            "/print/knowledge/p1": nil, "/print/artifacts/a1": nil,
            "/": .chat, "/setup": nil,
            "/inbox": nil, "/pdf": nil, "/native-debug": nil,
        ]
        for (path, area) in expected {
            let screen = standard.resolve(path)?.screen
            XCTAssertNotNil(screen, path)
            XCTAssertEqual(screen?.area, area, path)
        }
        XCTAssertEqual(standard.resolve("/apps/finance")?.screen, .customApp)
    }

    func testHttpClientIsNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/http")?.screen, .http)
        let withWorkspace = standard.resolve("/http?workspace=ws-1")
        XCTAssertEqual(withWorkspace?.screen, .http)
        XCTAssertEqual(withWorkspace?.query, ["workspace": "ws-1"])
        XCTAssertNil(standard.resolve("/http/anything"))
    }

    func testLearnRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/learn")?.screen, .learn)
        let lesson = standard.resolve("/learn/c1?lesson=snapshots")
        XCTAssertEqual(lesson?.screen, .learnCourse)
        XCTAssertEqual(lesson?.params["id"], "c1")
        XCTAssertEqual(lesson?.query["lesson"], "snapshots")
        let review = standard.resolve("/learn/c1?review=1")
        XCTAssertEqual(review?.screen, .learnCourse)
        XCTAssertEqual(review?.query["review"], "1")
        XCTAssertNil(standard.resolve("/learn/c1/extra"))
    }

    func testScheduledAndReportsRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/scheduled")?.screen, .scheduled)
        XCTAssertEqual(standard.resolve("/reports")?.screen, .reports)
        XCTAssertEqual(standard.resolve("/costs")?.screen, .reports)
    }

    func testKnowledgeAndWikiRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/knowledge")?.screen, .knowledge)
        XCTAssertEqual(standard.resolve("/knowledge?kind=deck")?.screen, .knowledge)
        XCTAssertEqual(standard.resolve("/knowledge?kind=deck")?.query["kind"], "deck")
        XCTAssertEqual(standard.resolve("/knowledge?q=architecture")?.query["q"], "architecture")

        // Specific routes must match before /knowledge/:id.
        XCTAssertEqual(standard.resolve("/knowledge/connect")?.screen, .knowledge)
        XCTAssertEqual(standard.resolve("/knowledge/graph")?.screen, .knowledgeGraph)

        let page = standard.resolve("/knowledge/11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(page?.screen, .knowledgePage)
        XCTAssertEqual(page?.params["id"], "11111111-1111-1111-1111-111111111111")

        let slugPage = standard.resolve("/knowledge/11111111-1111-1111-1111-111111111111/my-slug")
        XCTAssertEqual(slugPage?.screen, .knowledgePage)
        XCTAssertEqual(slugPage?.params["id"], "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(slugPage?.params["*"], "my-slug")

        XCTAssertEqual(standard.resolve("/wiki")?.screen, .knowledge)
        let wiki = standard.resolve("/wiki/Architecture/ADR%201")
        XCTAssertEqual(wiki?.screen, .knowledgePage)
        XCTAssertEqual(wiki?.params["*"], "Architecture/ADR 1")

        XCTAssertEqual(NativeScreen.knowledge.hostGroup, .knowledge)
        XCTAssertEqual(NativeScreen.knowledgeGraph.hostGroup, .knowledge)
        XCTAssertEqual(NativeScreen.knowledgePage.hostGroup, .knowledge)
        XCTAssertNotEqual(NativeScreen.inbox.hostGroup, .knowledge)
        XCTAssertNotEqual(NativeScreen.learn.hostGroup, .knowledge)
        XCTAssertNotEqual(NativeScreen.learnCourse.hostGroup, .knowledge)
    }

    func testOnlyInAppPathsResolve() {
        XCTAssertNil(registry.resolve("https://example.com/native-debug"))
        XCTAssertNil(registry.resolve("//evil.example/native-debug"))
        XCTAssertNil(registry.resolve("native-debug"))
    }

    func testDeepLinksReachNativeScreensThroughTheirPath() {
        guard case .ok(.navigate(let path)) = DeepLinks.parse("vesper://ticket/PAY-214") else { return XCTFail("parse") }
        XCTAssertEqual(registry.resolve(path)?.params["key"], "PAY-214")
        guard case .ok(.navigate(let inbox)) = DeepLinks.parse("vesper://inbox") else { return XCTFail("parse") }
        XCTAssertEqual(NativeRouteRegistry.standard(debug: false).resolve(inbox)?.screen, .inbox)
    }
}

final class NativeFindAndCommandTests: XCTestCase {
    private let rows = ["Alpha", "beta", "Gamma", "alphabet", "Delta"]

    func testNextMatchWrapsBothWays() {
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: nil, backwards: false), 0)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: 0, backwards: false), 3)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: 3, backwards: false), 0)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: 0, backwards: true), 3)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: nil, backwards: true), 3)
    }

    func testCaseSensitivityAndNoMatch() {
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "Alpha", caseSensitive: true, after: 0, backwards: false), 0)
        XCTAssertNil(FindLogic.nextMatch(in: rows, query: "zeta", caseSensitive: false, after: nil, backwards: false))
        XCTAssertNil(FindLogic.nextMatch(in: rows, query: "", caseSensitive: false, after: nil, backwards: false))
    }

    func testScreenCommandsGoToTheNativeScreen() {
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.toolbarAction(itemId: "refresh")))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.titleAction(menuItemId: "rename")))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.inspectorAction(tabId: "t", actionId: "a")))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.inspectorVisibility(open: false)))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.panelEvent(tabId: "code", event: "openFull")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navigate(path: "/inbox")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navActivate(navigatorId: "n", itemId: "i")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.railAction(itemId: "r")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.command(.find)))
    }

    func testAScreensOwnNavigatorCommandsGoToTheScreen() {
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.navActivate(navigatorId: "work-activity", itemId: "i"), navigatorId: "work-activity"))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.navSearch(navigatorId: "work-activity", searchId: "s", value: ""), navigatorId: "work-activity"))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.navToggle(navigatorId: "work-activity", itemId: "s", expanded: false), navigatorId: "work-activity"))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navActivate(navigatorId: "runs", itemId: "i"), navigatorId: "work-activity"))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navFilter(navigatorId: "work-activity", filterId: "f", value: "", checked: true)))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navigate(path: "/work"), navigatorId: "work-activity"))
    }

    func testNavigatorCommandsGoToTheScreenThatPublishesTheNavigator() {
        let commands: [NativeCommand] = [
            .navActivate(navigatorId: "library", itemId: "videos"),
            .navAction(navigatorId: "library", actionId: "project", menuItemId: "space:PAY"),
            .navPicker(navigatorId: "library", pickerId: "source", value: "projects"),
            .navFilter(navigatorId: "library", filterId: "f", value: "v", checked: true),
            .navSearch(navigatorId: "library", searchId: "library-search", value: "spec"),
            .navToggle(navigatorId: "library", itemId: "i", expanded: true),
        ]
        for command in commands {
            XCTAssertTrue(NativeCommandRouting.isScreenCommand(command, navigatorId: "library"), "\(command)")
            // Another navigator's commands (the page's, still running underneath) stay with the page.
            XCTAssertFalse(NativeCommandRouting.isScreenCommand(command, navigatorId: "inbox"), "\(command)")
            XCTAssertFalse(NativeCommandRouting.isScreenCommand(command), "\(command)")
        }
    }
}
