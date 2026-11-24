import Foundation
import XCTest
@testable import VesperCore

final class CustomAppStandaloneTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:8080")!

    func testStandalonePathsAndAutosaveName() {
        XCTAssertEqual(CustomAppStandaloneLogic.standalonePath(slug: "budget"), "/apps/budget?standalone=1")
        XCTAssertEqual(CustomAppStandaloneLogic.workbenchPath(slug: "budget"), "/apps/budget")
        XCTAssertEqual(CustomAppStandaloneLogic.frameAutosaveName(slug: "budget"), "VesperCustomAppWindow.budget")
    }

    func testShouldStayInStandaloneWindow() {
        XCTAssertTrue(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "http://127.0.0.1:8080/apps/budget?standalone=1&view=ledger")!,
            baseURL: baseURL,
            slug: "budget"
        ))
        XCTAssertTrue(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "http://localhost:8080/apps/budget")!,
            baseURL: baseURL,
            slug: "budget"
        ))
        // Different custom app, hub, other Vesper route, or different origin/port leave the standalone window.
        XCTAssertFalse(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "http://127.0.0.1:8080/apps/other?standalone=1")!,
            baseURL: baseURL,
            slug: "budget"
        ))
        XCTAssertFalse(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "http://127.0.0.1:8080/apps")!,
            baseURL: baseURL,
            slug: "budget"
        ))
        XCTAssertFalse(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "http://127.0.0.1:8080/chat/123")!,
            baseURL: baseURL,
            slug: "budget"
        ))
        XCTAssertFalse(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "http://127.0.0.1:8090/apps/budget?standalone=1")!,
            baseURL: baseURL,
            slug: "budget"
        ))
        XCTAssertFalse(CustomAppStandaloneLogic.shouldStayInStandaloneWindow(
            url: URL(string: "https://evil.example/apps/budget?standalone=1")!,
            baseURL: baseURL,
            slug: "budget"
        ))
    }

    func testBuildPermissionsGroupsAndCountsPendingRequests() {
        let manifest = API.CustomAppManifest(
            entry: "index.tsx",
            requestedCapabilities: [
                "os.notifications": .requiresApproval,
                "os.clipboard": .requiresApproval,
                "vesper.api:read": .allowed,
                "nix:ffmpeg": .requiresApproval,
                "app.sql:read": .allowed,
            ],
            requestedMounts: [
                API.CustomAppMountRequest(description: "Imported CSVs", name: "receipts"),
                API.CustomAppMountRequest(description: "Reference notes", name: "archive"),
            ],
            toolScope: .appOnly
        )
        let version = API.CustomAppVersion(
            authorType: .user,
            bundleCss: "",
            bundleJs: "",
            createdAt: "2026-11-24T00:00:00Z",
            files: ["index.tsx": "export default () => null;"],
            manifest: manifest,
            note: "init",
            seq: 2
        )
        let detail = API.CustomAppDetail(
            capabilities: [
                "os.notifications": .allowed,
                "os.clipboard": .requiresApproval,
                "vesper.api:read": .allowed,
                "secret:stripe": .requiresApproval,
                "app.sql:read": .allowed,
            ],
            createdAt: "2026-11-24T00:00:00Z",
            current: version,
            currentSeq: 2,
            dbSizeBytes: 8192,
            description: "Budget tracker",
            hasMcpServer: false,
            icon: "dollar",
            id: "app-1",
            manifest: manifest,
            mounts: ["receipts": "/Users/liam/Receipts"],
            name: "Budget",
            schema: [],
            slug: "budget",
            updatedAt: "2026-11-24T00:00:00Z",
            versions: []
        )

        let snap = CustomAppStandaloneLogic.buildPermissions(from: detail)
        XCTAssertEqual(snap.osCapabilities.map(\.key), ["os.notifications", "os.clipboard", "os.file_picker"])
        XCTAssertEqual(snap.osCapabilities[0].mode, .allowed)
        XCTAssertFalse(snap.osCapabilities[0].isPendingRequest)
        XCTAssertEqual(snap.osCapabilities[1].mode, .requiresApproval)
        XCTAssertTrue(snap.osCapabilities[1].isPendingRequest)
        XCTAssertEqual(snap.osCapabilities[2].mode, .denied)
        XCTAssertFalse(snap.osCapabilities[2].isPendingRequest)

        // Internal app.sql:* capabilities are omitted from user-facing toggles.
        XCTAssertFalse(snap.allCapabilities.contains(where: { $0.key.hasPrefix("app.sql:") }))
        XCTAssertEqual(snap.externalCapabilities.map(\.key), ["nix:ffmpeg", "secret:stripe"])
        XCTAssertEqual(snap.externalCapabilities[0].label, "Nix · ffmpeg")
        XCTAssertTrue(snap.externalCapabilities[0].isPendingRequest)
        XCTAssertEqual(snap.externalCapabilities[1].label, "Secret · stripe")

        XCTAssertEqual(snap.mounts.map(\.name), ["receipts", "archive"])
        XCTAssertTrue(snap.mounts[0].isConfigured)
        XCTAssertFalse(snap.mounts[1].isConfigured)

        XCTAssertEqual(snap.allowedCount, 2) // os.notifications + vesper.api:read
        XCTAssertEqual(snap.askCount, 2) // os.clipboard + secret:stripe
        // Pending requests: os.clipboard + nix:ffmpeg + unconfigured mount "archive"
        XCTAssertEqual(snap.pendingRequestCount, 3)

        let updated = CustomAppStandaloneLogic.updatedCapabilities(detail.capabilities, key: "os.notifications", mode: .denied)
        XCTAssertEqual(updated["os.notifications"], .denied)
        XCTAssertEqual(updated["os.clipboard"], .requiresApproval)
    }

    func testOSRequestDecodeValidAndMalformed() throws {
        let notify = try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1,
            "requestId": "req-1",
            "slug": "budget",
            "action": "notify",
            "approved": true,
            "title": "  Bill due  ",
            "subtitle": "Rent",
            "body": "Due tomorrow",
            "silent": true,
        ])
        XCTAssertEqual(notify.requestId, "req-1")
        XCTAssertEqual(notify.slug, "budget")
        XCTAssertEqual(notify.action, .notify)
        XCTAssertTrue(notify.approved)
        XCTAssertEqual(notify.title, "Bill due")
        XCTAssertEqual(notify.subtitle, "Rent")
        XCTAssertEqual(notify.body, "Due tomorrow")
        XCTAssertTrue(notify.silent)

        let picker = try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1,
            "requestId": "req-2",
            "slug": "budget",
            "action": "filePicker",
            "multiple": true,
            "extensions": [".CSV", "json", "../etc", "csv", "txt"],
        ])
        XCTAssertEqual(picker.action, .filePicker)
        XCTAssertTrue(picker.multiple)
        XCTAssertEqual(picker.extensions, ["csv", "json", "txt"])

        let write = try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1,
            "requestId": "req-3",
            "slug": "budget",
            "action": "clipboard.write",
            "text": "hello",
        ])
        XCTAssertEqual(write.action, .clipboardWrite)
        XCTAssertEqual(write.text, "hello")

        // Rejects wrong version, empty requestId, reserved slug, empty notify title, oversized clipboard text, unknown action.
        XCTAssertThrowsError(try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 2, "requestId": "r", "slug": "budget", "action": "clipboard.read",
        ]))
        XCTAssertThrowsError(try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1, "requestId": "   ", "slug": "budget", "action": "clipboard.read",
        ]))
        XCTAssertThrowsError(try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1, "requestId": "r", "slug": "docs", "action": "clipboard.read",
        ]))
        XCTAssertThrowsError(try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1, "requestId": "r", "slug": "budget", "action": "notify", "title": "   ",
        ]))
        XCTAssertThrowsError(try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1, "requestId": "r", "slug": "budget", "action": "clipboard.write",
            "text": String(repeating: "a", count: CustomAppOSLimits.maxClipboardBytes + 1),
        ]))
        XCTAssertThrowsError(try CustomAppOSRequest.decode(fromJSONObject: [
            "v": 1, "requestId": "r", "slug": "budget", "action": "shell.exec",
        ]))
    }

    func testOSPolicyURLMatchesSlug() {
        XCTAssertTrue(CustomAppOSPolicy.urlMatchesSlug(URL(string: "http://127.0.0.1:8080/apps/budget?standalone=1"), slug: "budget"))
        XCTAssertTrue(CustomAppOSPolicy.urlMatchesSlug(URL(string: "http://127.0.0.1:8080/apps/budget"), slug: "budget"))
        XCTAssertFalse(CustomAppOSPolicy.urlMatchesSlug(URL(string: "http://127.0.0.1:8080/apps/other"), slug: "budget"))
        XCTAssertFalse(CustomAppOSPolicy.urlMatchesSlug(URL(string: "http://127.0.0.1:8080/apps/budget/extra"), slug: "budget"))
        XCTAssertFalse(CustomAppOSPolicy.urlMatchesSlug(URL(string: "http://127.0.0.1:8080/apps/docs"), slug: "docs"))
        XCTAssertFalse(CustomAppOSPolicy.urlMatchesSlug(nil, slug: "budget"))
    }

    func testOSPolicyEnforcesModesStrictlyWithoutBypass() {
        let unapproved = CustomAppOSRequest(requestId: "r1", slug: "budget", action: .notify, approved: false, title: "Ping")
        let approved = CustomAppOSRequest(requestId: "r2", slug: "budget", action: .notify, approved: true, title: "Ping")

        // Missing capability defaults closed to denied — even with approved: true.
        if case .deny = CustomAppOSPolicy.evaluate(slug: "budget", capabilities: [:], request: approved) {
            // expected
        } else {
            XCTFail("Missing capability must deny even when approved=true")
        }

        // Explicitly denied capability can NEVER be bypassed with approved: true.
        let deniedCaps: API.CustomAppCapabilities = ["os.notifications": .denied]
        if case .deny = CustomAppOSPolicy.evaluate(slug: "budget", capabilities: deniedCaps, request: approved) {
            // expected
        } else {
            XCTFail("Denied capability must never be bypassed")
        }

        // Unknown capability mode string fails closed.
        let unknownCaps: API.CustomAppCapabilities = ["os.notifications": API.CustomAppCapabilityMode(rawValue: "magic")]
        if case .deny = CustomAppOSPolicy.evaluate(slug: "budget", capabilities: unknownCaps, request: approved) {
            // expected
        } else {
            XCTFail("Unknown capability mode must fail closed")
        }

        // requires_approval asks when approved=false and allows when approved=true.
        let askCaps: API.CustomAppCapabilities = ["os.notifications": .requiresApproval]
        if case .requireApproval(let cap, let summary) = CustomAppOSPolicy.evaluate(slug: "budget", capabilities: askCaps, request: unapproved) {
            XCTAssertEqual(cap, .notifications)
            XCTAssertTrue(summary.contains("Ping"))
        } else {
            XCTFail("Expected requireApproval for unapproved request")
        }
        XCTAssertEqual(CustomAppOSPolicy.evaluate(slug: "budget", capabilities: askCaps, request: approved), .allow)

        // allowed permits immediately without approval flag.
        let allowCaps: API.CustomAppCapabilities = ["os.notifications": .allowed]
        XCTAssertEqual(CustomAppOSPolicy.evaluate(slug: "budget", capabilities: allowCaps, request: unapproved), .allow)
    }

    func testEncodePickedFileTextVsBinary() {
        let utf8 = Data("a,b\n1,2\n".utf8)
        let textFile = CustomAppOSPolicy.encodePickedFile(name: "ledger.csv", data: utf8, contentType: "text/csv")
        guard case .object(let textObj) = textFile else { return XCTFail("expected object") }
        XCTAssertEqual(textObj["name"], .string("ledger.csv"))
        XCTAssertEqual(textObj["size"], .int(utf8.count))
        XCTAssertEqual(textObj["contentType"], .string("text/csv"))
        XCTAssertEqual(textObj["text"], .string("a,b\n1,2\n"))
        XCTAssertEqual(textObj["base64"], .string(utf8.base64EncodedString()))
        XCTAssertNil(textObj["path"])

        let binary = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let binFile = CustomAppOSPolicy.encodePickedFile(name: "img.png", data: binary, contentType: "image/png")
        guard case .object(let binObj) = binFile else { return XCTFail("expected object") }
        XCTAssertNil(binObj["text"])
        XCTAssertEqual(binObj["base64"], .string(binary.base64EncodedString()))
    }
}
