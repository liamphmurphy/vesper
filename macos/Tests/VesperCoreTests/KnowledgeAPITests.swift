import XCTest
@testable import VesperCore

final class KnowledgeAPITests: XCTestCase {
    func testListPagesQueryBuilding() {
        let req = KnowledgeAPI.listPages(
            q: "design+notes",
            tag: "arch",
            folder: "Projects/Vesper",
            audience: .shared,
            includeAgent: true,
            limit: 200,
            offset: 200
        )
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.template, "/knowledge/pages")
        XCTAssertEqual(
            req.pathAndQuery,
            "/api/v1/knowledge/pages?q=design%2Bnotes&tag=arch&folder=Projects%2FVesper&audience=shared&include_agent=true&limit=200&offset=200"
        )
        XCTAssertEqual(req.key.resources, ["knowledge", "pages"])
    }

    func testPageDecodesFullPayloadWithNullablesAndEmbeds() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Architecture Spec",
          "path": "Projects/Architecture Spec",
          "audience": "shared",
          "kind": "document",
          "canvas_id": null,
          "body_md": "# Hi\\n![[spec.pdf]]",
          "version_id": "22222222-2222-2222-2222-222222222222",
          "seq": 4,
          "properties": {"tags": ["adr", "swift"], "score": 4.5},
          "direct": true,
          "paused": false,
          "chat_id": "33333333-3333-3333-3333-333333333333",
          "url": "/knowledge/11111111-1111-1111-1111-111111111111/architecture-spec",
          "embeds": [
            {"ref": "spec.pdf", "kind": "file", "url": "/api/v1/knowledge/assets/abc", "content_type": "application/pdf", "available": true}
          ],
          "reviews": [
            {"id": "r1", "state": "pending", "review_state": "pending", "changes": [{"kind": "patch", "before": "a", "after": "b", "why": "fix"}], "author_id": "a1", "created_at": "2026-11-22T00:00:00Z"}
          ],
          "versions": [
            {"id": "22222222-2222-2222-2222-222222222222", "seq": 4, "label": "v4", "note": "", "author_type": "user", "author_id": "u1", "created_at": "2026-11-22T00:00:00Z"}
          ]
        }
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(KnowledgePage.self, from: json)
        XCTAssertEqual(page.id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(page.audience, .shared)
        XCTAssertEqual(page.kind, .document)
        XCTAssertTrue(page.direct)
        XCTAssertEqual(page.embeds.first?.contentType, "application/pdf")
        XCTAssertEqual(page.reviews.first?.changes.first?.why, "fix")
        XCTAssertEqual(page.versions.first?.seq, 4)
        XCTAssertEqual(page.properties["score"], .double(4.5))
    }

    func testVaultImportDecodesNullSlicesAsEmptyArrays() throws {
        let json = """
        {
          "id": "imp-1",
          "state": "preview",
          "folder": "Imported",
          "policy": null,
          "plan": {
            "entries": [{"source": "Note.md", "path": "Imported/Note", "kind": "markdown", "conflict": false}],
            "notes": 1,
            "attachments": 0,
            "resolved": 0,
            "unresolved": null,
            "folders": null,
            "tags": null
          },
          "report": null,
          "files_done": 0,
          "error": null,
          "created_at": "2026-11-22T00:00:00Z",
          "updated_at": "2026-11-22T00:00:00Z"
        }
        """.data(using: .utf8)!
        let job = try JSONDecoder().decode(KnowledgeImportJob.self, from: json)
        XCTAssertEqual(job.state, "preview")
        XCTAssertEqual(job.plan?.entries.count, 1)
        XCTAssertEqual(job.plan?.unresolved, [])
        XCTAssertEqual(job.plan?.folders, [])
        XCTAssertEqual(job.plan?.tags, [])
    }

    func testQueryPayloadOmitsEmptyFields() throws {
        let query = KnowledgePageQuery(text: "vesper", includeAgent: false, limit: 50)
        let data = try JSONEncoder().encode(query)
        let obj = try XCTSerializationHelper.jsonDictionary(from: data)
        XCTAssertEqual(obj["text"] as? String, "vesper")
        XCTAssertEqual(obj["limit"] as? Int, 50)
        XCTAssertNil(obj["include_agent"])
        XCTAssertNil(obj["folder"])
    }
}

private enum XCTSerializationHelper {
    static func jsonDictionary(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
