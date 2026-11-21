import XCTest
@testable import VesperCore

/// The generated request builders and Codable types, at the boundary: the URL, headers and bytes that
/// go out, and what decodes from what the Go server sends.
final class GeneratedAPITests: XCTestCase {
    func testPathParametersAreOneEscapedSegment() {
        let request = API.getTicket(key: "PAY-1/../x y")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v1/tickets/PAY-1%2F..%2Fx%20y")
        XCTAssertEqual(request.key.resources, ["tickets"])
    }

    func testQueryKeepsPlusSignsAndSkipsNils() {
        let request = API.listTickets(status: .inProgress, ready: true, q: "a+b c&d")
        XCTAssertEqual(request.pathAndQuery, "/api/v1/tickets?status=in_progress&ready=true&q=a%2Bb%20c%26d")
        XCTAssertEqual(API.listTickets().pathAndQuery, "/api/v1/tickets")
    }

    func testHeaderParameters() {
        let request = API.getChatAudioContent(id: "c1", audioId: "a1", range: "bytes=0-9")
        XCTAssertEqual(request.headers, ["Range": "bytes=0-9"])
        XCTAssertEqual(request.path, "/api/v1/chats/c1/audio/a1/content")
    }

    func testRequiredCollectionsDecodeGoNilAsEmpty() throws {
        let list = try APIDecoding<API.ListInboxResponse>.json.decode(Data(#"{"items":null}"#.utf8))
        XCTAssertEqual(list.items, [])
    }

    func testUnknownEnumValuesStillDecodeAndRoundTrip() throws {
        let status = try JSONDecoder().decode(API.TicketStatus.self, from: Data(#""someday""#.utf8))
        XCTAssertEqual(status.rawValue, "someday")
        XCTAssertFalse(API.TicketStatus.allKnown.contains(status))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(status), as: UTF8.self), #""someday""#)
        XCTAssertEqual(try JSONDecoder().decode(API.TicketStatus.self, from: Data(#""done""#.utf8)), .done)
    }

    func testPatchBodiesTellNullFromAbsent() throws {
        var patch = API.TicketPatch()
        patch.dueDate = .null
        patch.estimatePoints = .value(5)
        patch.status = .done
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as! [String: Any]
        XCTAssertTrue(object["due_date"] is NSNull, "null clears the field")
        XCTAssertNil(object["epic_id"], "absent leaves it alone")
        XCTAssertEqual(object["estimate_points"] as? Int, 5)
        XCTAssertEqual(object["status"] as? String, "done")

        let decoded = try JSONDecoder().decode(API.TicketPatch.self, from: Data(#"{"due_date":null,"title":"x"}"#.utf8))
        XCTAssertEqual(decoded.dueDate, .null)
        XCTAssertNil(decoded.epicId)
        XCTAssertEqual(decoded.title, "x")
    }

    func testSendEncodesJSONBodyAndDecodesTheAnswer() async throws {
        let seen = Captured()
        let client = APIClient(baseURL: URL(string: "http://localhost:8080")!, sessionToken: "tok") { request in
            seen.set(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        var patch = API.TicketPatch()
        patch.title = "New"
        let request = APIRequest<APIEmpty>(
            method: "PATCH", template: "/tickets/{key}", path: "/api/v1/tickets/PAY-1",
            body: .json(patch), decode: .empty
        )
        let answer = try await client.send(request)
        XCTAssertEqual(answer, APIEmpty())
        let sent = try XCTUnwrap(seen.request)
        XCTAssertEqual(sent.httpMethod, "PATCH")
        XCTAssertEqual(sent.url?.absoluteString, "http://localhost:8080/api/v1/tickets/PAY-1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: sent.httpBody ?? Data(), as: UTF8.self), #"{"title":"New"}"#)
    }

    func testMultipartForm() {
        var form = APIMultipartForm(boundary: "B")
        form.addField("note", "hi")
        form.addFile("file", filename: "a\"b.txt", contentType: "text/plain", data: Data("x".utf8))
        let (body, contentType) = form.encode()
        XCTAssertEqual(contentType, "multipart/form-data; boundary=B")
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhi\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a%22b.txt\"\r\nContent-Type: text/plain\r\n\r\nx\r\n"
                + "--B--\r\n"
        )
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return _request }
    func set(_ r: URLRequest) { lock.lock(); _request = r; lock.unlock() }
}
