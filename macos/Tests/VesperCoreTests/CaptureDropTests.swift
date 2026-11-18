import XCTest
@testable import VesperCore

private let UUID1 = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b"

private func ok(_ r: Result<APICall, CaptureError>) -> APICall? { try? r.get() }

final class CaptureTests: XCTestCase {
    func testBuildsTheExistingAPICallForEachKind() {
        XCTAssertEqual(ok(Capture.buildCaptureRequest(CaptureInput(kind: .note, text: "  buy milk \r\n"))),
                       APICall(path: "/api/v1/knowledge/capture", body: ["body_md": "buy milk"]))
        XCTAssertEqual(ok(Capture.buildCaptureRequest(CaptureInput(kind: .message, text: "hi", personaId: UUID1)))?.body,
                       ["persona_id": .string(UUID1), "message": ["body": "hi"]])
        XCTAssertEqual(ok(Capture.buildCaptureRequest(CaptureInput(kind: .message, text: "hi")))?.body, ["message": ["body": "hi"]], "default persona")
        XCTAssertEqual(ok(Capture.buildCaptureRequest(CaptureInput(kind: .ticket, text: "Fix login\nIt 500s on submit.\n", projectKey: "PAY"))),
                       APICall(path: "/api/v1/tickets", body: ["project_key": "PAY", "title": "Fix login", "description_md": "It 500s on submit."]))
        XCTAssertEqual(ok(Capture.buildCaptureRequest(CaptureInput(kind: .ticket, text: "Just a title", projectKey: "PAY")))?.body,
                       ["project_key": "PAY", "title": "Just a title"])
    }

    func testRefusesEmptyTextBadIdsAndTooLong() {
        XCTAssertNil(ok(Capture.buildCaptureRequest(CaptureInput(kind: .note, text: "   "))))
        XCTAssertNil(ok(Capture.buildCaptureRequest(CaptureInput(kind: .message, text: "x", personaId: "../admin"))))
        XCTAssertNil(ok(Capture.buildCaptureRequest(CaptureInput(kind: .ticket, text: "x", projectKey: "pay/../x"))))
        XCTAssertNil(ok(Capture.buildCaptureRequest(CaptureInput(kind: .ticket, text: "x"))))
        XCTAssertNil(ok(Capture.buildCaptureRequest(CaptureInput(kind: .note, text: String(repeating: "x", count: 100_001)))))
        XCTAssertEqual(Capture.buildCaptureRequest(CaptureInput(kind: .note, text: " ")), .failure(CaptureError("Write something first.")))
    }

    func testTicketTitleIsClippedTo300() {
        let call = ok(Capture.buildCaptureRequest(CaptureInput(kind: .ticket, text: String(repeating: "t", count: 400), projectKey: "PAY")))
        if case .string(let title)? = call?.body["title"] { XCTAssertEqual(title.count, 300) } else { XCTFail() }
    }

    func testCaptureResultHrefOnlyLinksValidatedIds() {
        XCTAssertEqual(Capture.captureResultHref(.message, response: ["id": UUID1]), "/chat/\(UUID1)")
        XCTAssertEqual(Capture.captureResultHref(.ticket, response: ["key": "PAY-12"]), "/tickets/PAY-12")
        XCTAssertEqual(Capture.captureResultHref(.note, response: ["id": UUID1]), "/knowledge/\(UUID1)")
        XCTAssertNil(Capture.captureResultHref(.ticket, response: ["key": "../x"]))
        XCTAssertNil(Capture.captureResultHref(.message, response: nil))
    }

    func testValidateGlobalShortcutRequiresARealModifierAndOneKey() throws {
        XCTAssertEqual(try Capture.validateGlobalShortcut("Alt+Shift+Space").get(), "Alt+Shift+Space")
        XCTAssertEqual(try Capture.validateGlobalShortcut("CommandOrControl+Shift+k").get(), "CommandOrControl+Shift+K")
        XCTAssertNoThrow(try Capture.validateGlobalShortcut("Control+F5").get())
        for bad in ["", "K", "Shift+K", "Alt+Alt+K", "Alt+", "Foo+K", "Alt+Shift", "Alt+Enterprise"] {
            XCTAssertNil(try? Capture.validateGlobalShortcut(bad).get(), bad)
        }
        XCTAssertNil(try? Capture.validateGlobalShortcut(nil).get())
        XCTAssertEqual(Capture.formatAccelerator("Alt+Shift+Space"), "⌥⇧Space")
        XCTAssertEqual(Capture.formatAccelerator("CommandOrControl+K"), "⌘K")
    }

    func testSystemShortcutConflictNamesShortcutsMacOSKeepsForItself() {
        XCTAssertEqual(Capture.systemShortcutConflict("CommandOrControl+Space"), "Spotlight")
        XCTAssertEqual(Capture.systemShortcutConflict("Cmd+Alt+Space"), "Finder search")
        XCTAssertEqual(Capture.systemShortcutConflict("Command+Shift+4"), "screenshots")
        XCTAssertNil(Capture.systemShortcutConflict("Alt+Shift+Space"))
    }
}

final class DropTests: XCTestCase {
    func testClassifyMirrorsServerAttachmentRules() {
        let (accepted, rejected) = Drop.classifyDroppedFiles([
            DroppedFile(path: "/u/a.PDF", size: 10), DroppedFile(path: "/u/b.png", size: 10), DroppedFile(path: "/u/a.PDF", size: 10),
            DroppedFile(path: "/u/folder", size: 0, isFile: false), DroppedFile(path: "/u/c.exe", size: 10),
            DroppedFile(path: "/u/empty.txt", size: 0), DroppedFile(path: "/u/huge.zip", size: Drop.maxAttachmentBytes + 1),
            DroppedFile(path: "/u/c.md", size: 1), DroppedFile(path: "/u/d.csv", size: 1), DroppedFile(path: "/u/e.json", size: 1),
            DroppedFile(path: "/u/f.txt", size: 1),
        ])
        XCTAssertEqual(accepted.map { [$0.name, $0.mime] }, [
            ["a.PDF", "application/pdf"], ["b.png", "image/png"], ["c.md", "text/markdown"], ["d.csv", "text/csv"], ["e.json", "application/json"],
        ])
        XCTAssertEqual(rejected.map(\.name), ["folder", "c.exe", "empty.txt", "huge.zip", "f.txt"])
        XCTAssertTrue(rejected.last!.reason.contains("at most 5"))
    }

    func testMultipartBodyEncodesOneFileFieldWithSafeFilename() {
        let (body, contentType) = Drop.buildMultipartBody(fileName: "we\"ird\r\nname.txt", mime: "text/plain", data: Data("hello".utf8), boundary: "BOUNDARY")
        XCTAssertEqual(contentType, "multipart/form-data; boundary=BOUNDARY")
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"we_ird__name.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--BOUNDARY--\r\n"
        )
        XCTAssertEqual(Drop.safeMultipartFilename(""), "file")
    }

    func testBuildSendFilesRequestPostsToNewOrExistingChatAndValidatesIds() {
        XCTAssertEqual(ok(Drop.buildSendFilesRequest(SendFilesInput(target: "new", message: "", attachmentIds: [UUID1]))),
                       APICall(path: "/api/v1/chats", body: ["message": ["body": "Here's this file.", "attachment_ids": [.string(UUID1)]]]))
        XCTAssertEqual(ok(Drop.buildSendFilesRequest(SendFilesInput(target: UUID1, message: " look ", attachmentIds: [UUID1, UUID1]))),
                       APICall(path: "/api/v1/chats/\(UUID1)/messages", body: ["body": "look", "attachment_ids": [.string(UUID1), .string(UUID1)]]))
        XCTAssertEqual(ok(Drop.buildSendFilesRequest(SendFilesInput(target: "new", attachmentIds: [UUID1, UUID1])))?.body["message"],
                       ["body": "Here's these files.", "attachment_ids": [.string(UUID1), .string(UUID1)]])
        XCTAssertNil(ok(Drop.buildSendFilesRequest(SendFilesInput(target: "../x", attachmentIds: [UUID1]))))
        XCTAssertNil(ok(Drop.buildSendFilesRequest(SendFilesInput(target: "new", attachmentIds: ["nope"]))))
        XCTAssertNil(ok(Drop.buildSendFilesRequest(SendFilesInput(target: "new", attachmentIds: []))))
        XCTAssertNil(ok(Drop.buildSendFilesRequest(SendFilesInput(target: "new", personaId: "x", attachmentIds: [UUID1]))))
    }
}
