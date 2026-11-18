import XCTest
@testable import VesperCore

final class RoutingTests: XCTestCase {
    func testClassifyNavigation() {
        let local = "http://localhost:8080"
        XCTAssertEqual(classifyNavigation("http://localhost:8080/tickets/X-228", serverURL: local), .vesper)
        XCTAssertEqual(classifyNavigation("http://localhost:8090/preview", serverURL: local), .playground)
        XCTAssertEqual(classifyNavigation("http://127.0.0.1:8094/", serverURL: local), .playground)
        XCTAssertEqual(classifyNavigation("http://localhost:9000/other", serverURL: local), .external)
        XCTAssertEqual(classifyNavigation("https://github.com/liamphmurphy/vesper", serverURL: local), .external)
        XCTAssertEqual(classifyNavigation("mailto:team@example.com", serverURL: local), .external)
        XCTAssertEqual(classifyNavigation("about:blank", serverURL: local), .ignore)
        XCTAssertEqual(classifyNavigation("javascript:void(0)", serverURL: local), .ignore)
        XCTAssertEqual(classifyNavigation("not a url", serverURL: local), .ignore)
        XCTAssertEqual(classifyNavigation("", serverURL: local), .ignore)

        let remote = "https://vesper.tailnet.ts.net"
        XCTAssertEqual(classifyNavigation("https://vesper.tailnet.ts.net/chat/123", serverURL: remote), .vesper)
        XCTAssertEqual(classifyNavigation("http://vesper.tailnet.ts.net:8092/app", serverURL: remote), .playground)
        XCTAssertEqual(classifyNavigation("http://localhost:8090/", serverURL: remote), .external)
    }

    func testCleanTabTitle() {
        XCTAssertEqual(cleanTabTitle(nil), "Vesper")
        XCTAssertEqual(cleanTabTitle(""), "Vesper")
        XCTAssertEqual(cleanTabTitle("Vesper"), "Vesper")
        XCTAssertEqual(cleanTabTitle("Inbox · Vesper"), "Inbox")
        XCTAssertEqual(cleanTabTitle("LAZYAGENTS-228 - Vesper"), "LAZYAGENTS-228")
        XCTAssertEqual(cleanTabTitle("Designs — Vesper"), "Designs")
        XCTAssertEqual(cleanTabTitle("  Chat   with   Meow  · Vesper  "), "Chat with Meow")
        XCTAssertEqual(cleanTabTitle("· Vesper"), "Vesper")
    }

    func testClosedTabStack() {
        var stack = ClosedTabStack(maxItems: 3)
        stack.push("file:///app/offline.html")
        stack.push("about:blank")
        XCTAssertEqual(stack.size, 0)
        stack.push("http://localhost:8080/a")
        stack.push("http://localhost:8080/a")
        XCTAssertEqual(stack.size, 1)
        stack.push("http://localhost:8080/b")
        stack.push("http://localhost:8080/c")
        stack.push("http://localhost:8080/d")
        XCTAssertEqual(stack.size, 3)
        XCTAssertEqual(stack.pop(), "http://localhost:8080/d")
        XCTAssertEqual(stack.pop(), "http://localhost:8080/c")
        XCTAssertEqual(stack.pop(), "http://localhost:8080/b")
        XCTAssertNil(stack.pop())
        XCTAssertEqual(ClosedTabStack().size, 0)
    }
}
