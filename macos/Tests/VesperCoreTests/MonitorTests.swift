import XCTest
@testable import VesperCore

private func mkRun(_ id: String, _ edit: (inout RunSummary) -> Void = { _ in }) -> RunSummary {
    var r = RunSummary(id: id, state: "running", purpose: "ticket", ticketKey: "PAY-1", workTitle: "Work \(id)", agent: AgentRef(name: "Pike"))
    edit(&r)
    return r
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [String] = []
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
    func add(_ u: String) { lock.lock(); _urls.append(u); lock.unlock() }
}

/// Serves canned JSON by URL suffix.
private func transport(_ recorder: Recorder = Recorder(), _ handler: @escaping @Sendable (String) -> (Int, Any)) -> HTTPTransport {
    { request in
        let url = request.url!.absoluteString
        recorder.add(url)
        let (status, body) = handler(url)
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func client(_ t: @escaping HTTPTransport, base: String = "http://localhost:8080") -> APIClient {
    APIClient(baseURL: URL(string: base)!, sessionToken: "tok", transport: t)
}

final class RunLogicTests: XCTestCase {
    func testDetectFinishedRunsAlertsOncePerRunThatLeftLiveInATerminalState() {
        var notified = Set<String>()
        let prev = [mkRun("a"), mkRun("b"), mkRun("c") { $0.purpose = "chat" }, mkRun("d"), mkRun("e")]
        let live = [mkRun("e")]
        let recent = [
            mkRun("a") { $0.state = "completed"; $0.outcome = "Opened PR #1" },
            mkRun("b") { $0.state = "failed" },
            mkRun("c") { $0.purpose = "chat"; $0.state = "completed" },
            mkRun("d") { $0.state = "cancelled" },
        ]
        let alerts = RunLogic.detectFinishedRuns(previousLive: prev, currentLive: live, recent: recent, notified: &notified)
        XCTAssertEqual(alerts.map(\.title), ["Run finished: Work a", "Run failed: Work b"])
        XCTAssertEqual(alerts[0].href, "/runs/a")
        XCTAssertEqual(alerts[0].kind, "run_finished")
        XCTAssertTrue(alerts[0].body.contains("Opened PR #1"))
        XCTAssertTrue(notified.contains("c") && notified.contains("d"), "chat and cancelled runs are marked so they never alert later")
        XCTAssertEqual(RunLogic.detectFinishedRuns(previousLive: prev, currentLive: live, recent: recent, notified: &notified), [], "never twice")
    }

    func testDetectFinishedRunsWaitsWhenEndStateUnknown() {
        var notified = Set<String>()
        XCTAssertEqual(RunLogic.detectFinishedRuns(previousLive: [mkRun("a")], currentLive: [], recent: [], notified: &notified), [])
        XCTAssertFalse(notified.contains("a"))
    }

    func testIsActiveAndPausableRuns() {
        XCTAssertTrue(RunLogic.isActive(mkRun("a")))
        XCTAssertFalse(RunLogic.isActive(mkRun("a") { $0.state = "waiting"; $0.waitReason = "approval" }))
        XCTAssertTrue(RunLogic.isActive(mkRun("a") { $0.state = "waiting"; $0.waitReason = "checks" }))
        XCTAssertFalse(RunLogic.isActive(mkRun("a") { $0.state = "paused" }))
        let p = RunLogic.pausableRuns([
            mkRun("a"), mkRun("b") { $0.purpose = "chat" }, mkRun("c") { $0.state = "waiting"; $0.waitReason = "checks" },
            mkRun("d") { $0.state = "waiting"; $0.waitReason = "human_reply" }, mkRun("e") { $0.state = "queued" },
        ])
        XCTAssertEqual(p.map(\.id), ["a", "d"])
    }
}

@MainActor
final class MonitorTests: XCTestCase {
    func testInboxMonitorUpdatesBadgeAndFiresAlertsFromPolledInbox() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let c = client(transport { _ in
            let a: [String: Any] = ["id": "a", "kind": "approval", "title": "Initial", "href": "/inbox", "created_at": "2026-11-16T00:00:00Z", "needs_you": true]
            let b: [String: Any] = ["id": "b", "kind": "blocked", "title": "Build failed", "summary": "Exit 1", "href": "/runs/99", "created_at": "2026-11-16T00:02:00Z", "needs_you": true]
            counter.n += 1
            return (200, ["items": counter.n == 1 ? [a] : [a, b]])
        })
        let monitor = InboxMonitor(pollInterval: .seconds(60))
        var badges: [String] = []
        var counts: [Int] = []
        var alerts: [DesktopAlert] = []
        monitor.onBadgeChange = { badge, count in badges.append(badge); counts.append(count) }
        monitor.onAlert = { alerts.append($0) }
        monitor.start(client: c)
        try await Task.sleep(for: .milliseconds(100))
        await monitor.refreshNow()
        monitor.stop()
        XCTAssertEqual(badges, ["1", "2"])
        XCTAssertEqual(counts, [1, 2])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].href, "/runs/99")
    }

    func testInboxMonitorClearsBadgeOnUnauthorizedAndRefreshesOnEvents() async throws {
        let rec = Recorder()
        let c = client(transport(rec) { _ in (401, ["message": "no"]) })
        let monitor = InboxMonitor(pollInterval: .seconds(60))
        var badges: [String] = []
        monitor.onBadgeChange = { badge, _ in badges.append(badge) }
        monitor.start(client: c)
        try await Task.sleep(for: .milliseconds(100))
        monitor.handleServerEvent("video.updated")
        monitor.handleServerEvent("inbox.updated")
        try await Task.sleep(for: .milliseconds(100))
        monitor.stop()
        XCTAssertEqual(badges, ["", ""])
        XCTAssertEqual(rec.urls.count, 2, "start + inbox.updated; video.updated is ignored")
        XCTAssertTrue(rec.urls.allSatisfy { $0 == "http://localhost:8080/api/v1/inbox" })
    }

    func testRunMonitorPollsLiveThenAllOnlyWhenOneVanished() async throws {
        final class State: @unchecked Sendable { var live: [[String: Any]] = [["id": "a", "state": "running", "purpose": "ticket", "work_title": "Work a"]] }
        let state = State()
        let rec = Recorder()
        let c = client(transport(rec) { url in
            url.hasSuffix("state=all")
                ? (200, ["runs": [["id": "a", "state": "completed", "purpose": "ticket", "work_title": "Work a"]], "has_more": false])
                : (200, ["runs": state.live])
        }, base: "http://localhost:8080")
        let monitor = RunMonitor(pollInterval: .seconds(60))
        var finished: [String] = []
        var snapshots: [[String]] = []
        monitor.onFinished = { finished.append($0.title) }
        monitor.onSnapshot = { snapshots.append($0.map(\.id)) }
        monitor.start(client: c)
        try await Task.sleep(for: .milliseconds(100))
        state.live = []
        await monitor.refreshNow()
        monitor.stop()
        XCTAssertEqual(rec.urls, [
            "http://localhost:8080/api/v1/runs?state=live",
            "http://localhost:8080/api/v1/runs?state=live",
            "http://localhost:8080/api/v1/runs?state=all",
        ])
        XCTAssertEqual(snapshots, [["a"], []])
        XCTAssertEqual(finished, ["Run finished: Work a"])
    }

    func testRunMonitorAlertsOnALaterPollWhenEndShowsUpLate() async throws {
        final class State: @unchecked Sendable { var live: [[String: Any]] = [["id": "a", "state": "running", "purpose": "ticket", "work_title": "Work a"]]; var all: [[String: Any]] = [] }
        let state = State()
        let c = client(transport { url in url.hasSuffix("state=all") ? (200, ["runs": state.all]) : (200, ["runs": state.live]) })
        let monitor = RunMonitor(pollInterval: .seconds(60))
        var finished: [String] = []
        monitor.onFinished = { finished.append($0.title) }
        monitor.start(client: c)
        try await Task.sleep(for: .milliseconds(100))
        state.live = []
        await monitor.refreshNow()
        XCTAssertEqual(finished, [])
        state.all = [["id": "a", "state": "failed", "purpose": "ticket", "work_title": "Work a"]]
        await monitor.refreshNow()
        monitor.stop()
        XCTAssertEqual(finished, ["Run failed: Work a"])
    }

    func testSSEParserReadsEventTypes() {
        XCTAssertEqual(SSE.eventType(fromLine: #"data: {"type":"run.updated","id":"x"}"#), "run.updated")
        XCTAssertEqual(SSE.eventType(fromLine: #"data:{"type":"reset"}"#), "reset")
        XCTAssertNil(SSE.eventType(fromLine: ": keepalive"))
        XCTAssertNil(SSE.eventType(fromLine: "event: ping"))
        XCTAssertNil(SSE.eventType(fromLine: "data: not json"))
        XCTAssertNil(SSE.eventType(fromLine: #"data: {"nope":1}"#))
    }

    func testEventStreamDeliversEventsAndReconnects() async throws {
        final class Attempts: @unchecked Sendable { var n = 0; var accept: [String] = []; var cookies: [String] = [] }
        let attempts = Attempts()
        let stream = EventStream(reconnectDelay: .milliseconds(20)) { request in
            attempts.n += 1
            attempts.accept.append(request.value(forHTTPHeaderField: "Accept") ?? "")
            attempts.cookies.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
            let n = attempts.n
            return AsyncThrowingStream { c in
                c.yield(": hello")
                c.yield(#"data: {"type":"run.started"}"#)
                if n == 1 { c.finish() } else { c.finish(throwing: URLError(.networkConnectionLost)) }
            }
        }
        var events: [String] = []
        stream.onEvent = { events.append($0) }
        stream.start(client: client(transport { _ in (200, [:]) }))
        try await Task.sleep(for: .milliseconds(300))
        stream.stop()
        XCTAssertGreaterThanOrEqual(events.count, 2, "reconnected after the stream ended")
        XCTAssertEqual(events.first, "run.started")
        XCTAssertEqual(attempts.accept.first, "text/event-stream")
        XCTAssertEqual(attempts.cookies.first, "vesper_session=tok")
    }
}

final class APIClientTests: XCTestCase {
    func testPathsMustBeAPIPathsAndErrorsMap() async throws {
        let ok = client(transport { _ in (200, ["x": 1]) })
        let data = try await ok.request("GET", "/api/v1/inbox")
        XCTAssertFalse(data.isEmpty)
        do { _ = try await ok.request("GET", "/events"); XCTFail("expected invalidPath") } catch let e as APIError { XCTAssertEqual(e, .invalidPath("/events")) }
        do { _ = try await ok.request("GET", "/api/v1/../admin"); XCTFail("expected invalidPath") } catch let e as APIError { XCTAssertEqual(e, .invalidPath("/api/v1/../admin")) }
        for status in [401, 403] {
            let c = client(transport { _ in (status, [:]) })
            do { _ = try await c.request("GET", "/api/v1/inbox"); XCTFail() } catch let e as APIError { XCTAssertEqual(e, .unauthorized) }
        }
        let missing = client(transport { _ in (404, [:]) })
        do { _ = try await missing.request("GET", "/api/v1/x"); XCTFail() } catch let e as APIError { XCTAssertEqual(e, .http(status: 404, message: "It's no longer there.")) }
        let withMessage = client(transport { _ in (409, ["code": "x", "message": "  Already approved  "]) })
        do { _ = try await withMessage.request("POST", "/api/v1/x"); XCTFail() } catch let e as APIError { XCTAssertEqual(e, .http(status: 409, message: "Already approved")) }
        let down = client({ _ in throw URLError(.cannotConnectToHost) })
        do { _ = try await down.request("GET", "/api/v1/x"); XCTFail() } catch let e as APIError { XCTAssertEqual(e, .unreachable) }
        let slow = client({ _ in throw URLError(.timedOut) })
        do { _ = try await slow.request("GET", "/api/v1/x"); XCTFail() } catch let e as APIError { XCTAssertEqual(e, .timeout) }
    }

    func testSendsCookieAndJSONBody() async throws {
        final class Seen: @unchecked Sendable { var request: URLRequest? }
        let seen = Seen()
        let c = client({ request in
            seen.request = request
            return (Data("{\"id\":\"x\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let answer = try await c.send(APICall(path: "/api/v1/chats", body: ["message": ["body": "hi"]]))
        XCTAssertEqual((answer as? [String: Any])?["id"] as? String, "x")
        XCTAssertEqual(seen.request?.value(forHTTPHeaderField: "Cookie"), "vesper_session=tok")
        XCTAssertEqual(seen.request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(seen.request?.httpMethod, "POST")
        XCTAssertEqual(String(decoding: seen.request?.httpBody ?? Data(), as: UTF8.self), #"{"message":{"body":"hi"}}"#)
    }

    func testUploadAttachmentSendsMultipartAndReturnsId() async throws {
        final class Seen: @unchecked Sendable { var request: URLRequest? }
        let seen = Seen()
        let c = client({ request in
            seen.request = request
            return (Data("{\"id\":\"6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        let id = try await c.uploadAttachment(fileName: "a.png", mime: "image/png", data: Data([1, 2, 3]))
        XCTAssertEqual(id, "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")
        XCTAssertEqual(seen.request?.url?.path, "/api/v1/chat-attachments")
        XCTAssertTrue(seen.request?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }
}
