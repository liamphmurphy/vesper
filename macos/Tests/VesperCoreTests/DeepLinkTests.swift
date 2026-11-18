import XCTest
@testable import VesperCore

final class DeepLinkTests: XCTestCase {
    let run = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b"

    func testSupportedTargets() {
        let cases: [(String, String)] = [
            ("vesper://run/\(run)", "/runs/\(run)"),
            ("vesper://ticket/LAZYAGENTS-244", "/tickets/LAZYAGENTS-244"),
            ("vesper://epic/\(run)", "/epics/\(run)"),
            ("vesper://page/\(run)", "/knowledge/\(run)"),
            ("vesper://chat/\(run)", "/chat/\(run)"),
            ("vesper://inbox", "/inbox"),
            ("vesper://inbox/", "/inbox"),
            ("VESPER://ticket/PAY-1", "/tickets/PAY-1"),
        ]
        for (link, path) in cases { XCTAssertEqual(DeepLinks.parse(link), .ok(.navigate(path: path)), link) }
        XCTAssertEqual(DeepLinks.parse("vesper://capture"), .ok(.capture))
    }

    func testRejectsHostileInput() {
        let hostile = [
            "", "vesper:", "vesper://", "https://example.com/runs/x", "javascript:alert(1)",
            "vesper://run/not-a-uuid", "vesper://run/\(run)/extra", "vesper://run/\(run)?next=https://evil.example",
            "vesper://run/\(run)#frag", "vesper://ticket/lowercase-1", "vesper://ticket/PAY-0",
            "vesper://ticket/PAY-1%2F..%2F..%2Fsettings", "vesper://ticket/..%2F..%2Fsettings", "vesper://settings",
            "vesper://user:pass@run/\(run)", "vesper://run:8080/\(run)", "vesper://run/\(run)%00",
            "vesper://ticket/PAY-1 ", "vesper://ticket/PAY-1\nX", "vesper://run\\\(run)",
            "vesper://chat/\(String(repeating: "a", count: 300))", "vesper://inbox/extra", "vesper://capture/now",
            "vesper:////evil.example/runs",
        ]
        for link in hostile {
            guard case .rejected = DeepLinks.parse(link) else { return XCTFail("should reject \(link.debugDescription)") }
        }
    }

    func testHrefToVesperLink() {
        XCTAssertEqual(DeepLinks.hrefToVesperLink("/runs/\(run)"), "vesper://run/\(run)")
        XCTAssertEqual(DeepLinks.hrefToVesperLink("/tickets/PAY-214?tab=runs"), "vesper://ticket/PAY-214")
        XCTAssertEqual(DeepLinks.hrefToVesperLink("/inbox"), "vesper://inbox")
        XCTAssertEqual(DeepLinks.hrefToVesperLink("/chat/\(run)#m-3"), "vesper://chat/\(run)")
        XCTAssertNil(DeepLinks.hrefToVesperLink("/wiki/Some/Page"))
        XCTAssertNil(DeepLinks.hrefToVesperLink("https://github.com/x/y/pull/1"))
        XCTAssertNil(DeepLinks.hrefToVesperLink("//evil.example/runs/\(run)"))
        for href in ["/runs/\(run)", "/tickets/PAY-214", "/inbox", "/knowledge/\(run)"] {
            let link = DeepLinks.hrefToVesperLink(href)!
            XCTAssertEqual(DeepLinks.parse(link), .ok(.navigate(path: href)))
        }
    }

    func testFindLink() {
        XCTAssertEqual(DeepLinks.findLink(in: ["/x/Vesper", "--foo", "vesper://inbox"]), "vesper://inbox")
        XCTAssertNil(DeepLinks.findLink(in: ["/x", "--inspect"]))
    }
}
