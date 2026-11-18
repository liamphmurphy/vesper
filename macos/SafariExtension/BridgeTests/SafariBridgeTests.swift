import Foundation
import XCTest
@testable import VesperSafariBridge

final class SafariBridgeTests: XCTestCase {
    let id = "0F9A3C1E-2B4D-4E6F-8A1B-3C5D7E9F1A2B"

    func testRoutesOnlyKnownOperations() throws {
        let cases: [([String: Any], String, String)] = [
            (["op": "config"], "GET", "/api/v1/browser-extension/config"),
            (["op": "share_start", "body": ["url": "https://a.example/"]], "POST", "/api/v1/browser-extension/shares"),
            (["op": "share_get", "share_id": id], "GET", "/api/v1/browser-extension/shares/\(id.lowercased())"),
            (["op": "snapshot", "share_id": id, "body": [:] as [String: Any]], "POST", "/api/v1/browser-extension/shares/\(id.lowercased())/snapshot"),
            (["op": "share_stop", "share_id": id, "body": ["reason": "stopped"]], "POST", "/api/v1/browser-extension/shares/\(id.lowercased())/stop"),
            (["op": "ask", "body": ["prompt": "x"]], "POST", "/api/v1/browser-extension/ask"),
            (["op": "clip", "body": ["as": "note"]], "POST", "/api/v1/browser-extension/clip"),
            (["op": "never_add", "body": ["host": "bank.example"]], "POST", "/api/v1/browser-extension/never-share"),
            (["op": "never_remove", "host": "bank.example"], "DELETE", "/api/v1/browser-extension/never-share/bank.example"),
        ]
        for (message, method, path) in cases {
            guard case .api(let call) = try SafariBridge.route(message) else { return XCTFail("\(message) didn't route to the API") }
            XCTAssertEqual(call.method, method)
            XCTAssertEqual(call.path, path)
        }
        XCTAssertEqual(try SafariBridge.route(["op": "open_chat", "chat_id": id]), .open(URL(string: "vesper://chat/\(id.lowercased())")!))
        XCTAssertEqual(try SafariBridge.route(["op": "open_page", "page_id": id]), .open(URL(string: "vesper://page/\(id.lowercased())")!))
    }

    func testRefusesAnythingElse() {
        let hostile: [[String: Any]] = [
            [:],
            ["op": "chats"],
            ["op": "share_get", "share_id": "../../chats"],
            ["op": "snapshot", "share_id": id],                      // no body
            ["op": "share_start", "body": "not an object"],
            ["op": "never_remove", "host": "../../settings"],
            ["op": "never_remove", "host": "Bank.example"],
            ["op": "open_chat", "chat_id": "x"],
        ]
        for message in hostile {
            XCTAssertThrowsError(try SafariBridge.route(message), "\(message)")
        }
    }

    func testRequestsGoOnlyToThisMacWithTheToken() throws {
        let call = BridgeCall(method: "GET", path: "/api/v1/browser-extension/config", body: nil)
        let req = try XCTUnwrap(SafariBridge.request(call, connection: SafariConnection(baseURL: "http://127.0.0.1:8080", token: "vbx_t")))
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8080/api/v1/browser-extension/config")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer vbx_t")
        for base in ["https://127.0.0.1:8080", "http://evil.example:8080", "http://user@127.0.0.1:8080", "not a url"] {
            XCTAssertNil(SafariBridge.request(call, connection: SafariConnection(baseURL: base, token: "vbx_t")), base)
        }
    }

    func testRepliesCarryBodyOrMessage() {
        let url = URL(string: "http://127.0.0.1:8080/")!
        let ok = SafariBridge.reply(data: Data(#"{"id":"1"}"#.utf8), response: HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil), error: nil)
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual((ok["body"] as? [String: Any])?["id"] as? String, "1")
        let conflict = SafariBridge.reply(data: Data(#"{"message":"url: this page can't be shared"}"#.utf8), response: HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil), error: nil)
        XCTAssertEqual(conflict["ok"] as? Bool, false)
        XCTAssertEqual(conflict["status"] as? Int, 409)
        XCTAssertEqual(conflict["error"] as? String, "url: this page can't be shared")
        let down = SafariBridge.reply(data: nil, response: nil, error: URLError(.cannotConnectToHost))
        XCTAssertEqual(down["ok"] as? Bool, false)
    }

    func testHandleWithoutAConnectionFileSaysOpenVesper() {
        var reply: [String: Any]?
        SafariBridge.handle(["op": "config"], connection: { throw CocoaError(.fileNoSuchFile) }, transport: { _, _ in XCTFail("no request without a connection") }, open: { _ in false }) { reply = $0 }
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertTrue((reply?["error"] as? String ?? "").contains("Open the Vesper app"))
    }

    func testConnectionFileIsPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = SafariConnectionFile.url(home: home)
        try SafariConnectionFile.write(SafariConnection(baseURL: "http://127.0.0.1:8080", token: "vbx_one"), to: file)
        try SafariConnectionFile.write(SafariConnection(baseURL: "http://127.0.0.1:8080", token: "vbx_two"), to: file)
        XCTAssertEqual(try SafariConnectionFile.read(from: file).token, "vbx_two")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertTrue(file.path.hasSuffix("Library/Application Support/Vesper Safari/connection.json"))
    }
}
