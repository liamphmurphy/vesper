import XCTest
@testable import VesperCore

private struct Counter: Codable, Sendable, Equatable { var n: Int }

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// A stub API: canned answers by path, a hit count per path, and optional gates that hold a path's
/// answers until opened.
private final class StubServer: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (Int, Any)] = [:]
    private var hitCounts: [String: Int] = [:]
    private var gates: [String: Gate] = [:]

    func answer(_ path: String, status: Int = 200, _ body: Any) {
        lock.lock(); answers[path] = (status, body); lock.unlock()
    }

    func hold(_ path: String) -> Gate {
        let gate = Gate()
        lock.lock(); gates[path] = gate; lock.unlock()
        return gate
    }

    func hits(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hitCounts[path] ?? 0
    }

    var client: APIClient {
        APIClient(baseURL: URL(string: "http://localhost:8080")!, sessionToken: "tok") { [self] request in
            let path = request.url!.path
            let gate: Gate? = lock.withLock {
                hitCounts[path, default: 0] += 1
                return gates[path]
            }
            if let gate { await gate.wait() }
            let (status, body) = lock.withLock { answers[path] ?? (404, ["message": "no"]) }
            let data = try JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private func get(_ path: String, _ template: String) -> APIRequest<Counter> {
    APIRequest(method: "GET", template: template, path: "/api/v1" + path, decode: .json)
}

private let ticket1 = get("/tickets/PAY-1", "/tickets/{key}")
private let ticket2 = get("/tickets/PAY-2", "/tickets/{key}")
private let run1 = get("/runs/r1", "/runs/{id}")
private let run2 = get("/runs/r2", "/runs/{id}")
private let save = APIRequest<APIEmpty>(method: "PATCH", template: "/tickets/{key}", path: "/api/v1/tickets/PAY-1", decode: .empty)

@MainActor
private func settle<V>(_ entry: QueryEntry<V>) async {
    while let task = entry.task { await task.value }
}

@MainActor
final class QueryStoreTests: XCTestCase {
    private var server: StubServer!
    private var clock: Date!
    private var store: QueryStore!

    override func setUp() async throws {
        server = StubServer()
        clock = Date(timeIntervalSince1970: 1_000_000)
        store = QueryStore(client: server.client, staleAfter: 30, now: { [unowned self] in self.clock })
    }

    func testConcurrentLoadsShareOneEntryAndOneFetch() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        let gate = server.hold("/api/v1/tickets/PAY-1")
        let a = store.load(ticket1)
        let b = store.load(ticket1)
        XCTAssertTrue(a === b)
        XCTAssertTrue(a.isFetching)
        await gate.open()
        await settle(a)
        XCTAssertEqual(server.hits("/api/v1/tickets/PAY-1"), 1)
        XCTAssertEqual(a.data, Counter(n: 1))
        XCTAssertFalse(a.isFetching)
    }

    func testFreshAnswerIsReusedUntilStale() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        await settle(store.load(ticket1))
        await settle(store.load(ticket1))
        XCTAssertEqual(server.hits("/api/v1/tickets/PAY-1"), 1)

        clock += 31
        await settle(store.load(ticket1))
        XCTAssertEqual(server.hits("/api/v1/tickets/PAY-1"), 2)
    }

    func testHintRefetchesObservedEntriesNowAndOthersOnNextLoad() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        server.answer("/api/v1/tickets/PAY-2", ["n": 2])
        let observed = store.load(ticket1)
        let idle = store.load(ticket2)
        await settle(observed)
        await settle(idle)
        store.observe(ticket1)

        server.answer("/api/v1/tickets/PAY-1", ["n": 10])
        store.handle(ServerEvent(type: "ticket.updated", ids: ["PAY-1"]))
        await settle(observed)
        XCTAssertEqual(observed.data, Counter(n: 10))
        XCTAssertFalse(observed.isInvalidated)
        XCTAssertEqual(server.hits("/api/v1/tickets/PAY-2"), 1, "an unobserved entry waits until it's used")
        XCTAssertTrue(idle.isInvalidated)

        await settle(store.load(ticket2))
        XCTAssertEqual(server.hits("/api/v1/tickets/PAY-2"), 2)
        XCTAssertFalse(idle.isInvalidated)
    }

    func testRunEventsRefetchOnlyTheNamedRun() async {
        server.answer("/api/v1/runs/r1", ["n": 1])
        server.answer("/api/v1/runs/r2", ["n": 2])
        let a = store.load(run1), b = store.load(run2)
        await settle(a); await settle(b)
        store.observe(run1); store.observe(run2)

        store.handle(ServerEvent(type: "run.events", ids: ["r1"]))
        await settle(a); await settle(b)
        XCTAssertEqual(server.hits("/api/v1/runs/r1"), 2)
        XCTAssertEqual(server.hits("/api/v1/runs/r2"), 1)
    }

    func testOptimisticUpdateShowsAtOnceAndRollsBackOnFailure() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        let entry = store.load(ticket1)
        await settle(entry)
        server.answer("/api/v1/tickets/PAY-1", status: 500, ["message": "boom"])
        let gate = server.hold("/api/v1/tickets/PAY-1")

        let mutation = Task { try await self.store.mutate(save, optimistic: [.update(ticket1) { $0.n = 99 }]) }
        await Task.yield()
        XCTAssertEqual(entry.data, Counter(n: 99), "the optimistic value shows before the server answers")
        await gate.open()
        do {
            _ = try await mutation.value
            XCTFail("the mutation should fail")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 500, message: "boom"))
        }
        XCTAssertEqual(entry.data, Counter(n: 1))
    }

    func testSuccessfulMutationRefetchesWhatItTouched() async throws {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        let entry = store.load(ticket1)
        await settle(entry)
        store.observe(ticket1)

        // The PATCH and the refetch share the path; the stub answers both with the server's value.
        server.answer("/api/v1/tickets/PAY-1", ["n": 2])
        try await store.mutate(save, optimistic: [.update(ticket1) { $0.n = 99 }])
        await settle(entry)
        XCTAssertEqual(entry.data, Counter(n: 2))
    }

    func testFetchStartedBeforeALocalWriteIsDropped() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        let gate = server.hold("/api/v1/tickets/PAY-1")
        let entry = store.load(ticket1)
        store.setData(Counter(n: 5), for: ticket1)
        await gate.open()
        await settle(entry)
        XCTAssertEqual(entry.data, Counter(n: 5))
    }

    func testErrorKeepsTheLastAnswer() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        await settle(store.load(ticket1))
        server.answer("/api/v1/tickets/PAY-1", status: 500, ["message": "down"])
        let entry = await store.refetch(ticket1)
        XCTAssertEqual(entry.data, Counter(n: 1))
        XCTAssertEqual(entry.error, .http(status: 500, message: "down"))
    }

    func testNewSessionDropsEveryCachedAnswer() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        let old = store.load(ticket1)
        await settle(old)
        store.setClient(server.client)
        let fresh = store.entry(ticket1)
        XCTAssertFalse(old === fresh)
        XCTAssertNil(fresh.data)
    }

    func testGarbageCollectionKeepsObservedAndRecentEntries() async {
        server.answer("/api/v1/tickets/PAY-1", ["n": 1])
        server.answer("/api/v1/tickets/PAY-2", ["n": 2])
        await settle(store.load(ticket1))
        await settle(store.load(ticket2))
        store.observe(ticket1)
        clock += 301
        store.collectGarbage()
        XCTAssertEqual(store.entryCount, 1)
        XCTAssertTrue(store.entry(ticket1).hasData)
    }
}

final class LiveUpdatesTests: XCTestCase {
    private func key(_ path: String, _ template: String) -> QueryKey {
        QueryKey(path: "/api/v1" + path, template: template)
    }

    func testTicketHintReachesBoardsInboxAndDashboards() {
        let inv = LiveUpdates.invalidation(for: ServerEvent(type: "ticket.updated", ids: ["PAY-1"]))
        XCTAssertTrue(inv.matches(key("/projects/PAY/board", "/projects/{key}/board")))
        XCTAssertTrue(inv.matches(key("/inbox", "/inbox")))
        XCTAssertTrue(inv.matches(key("/tickets/PAY-9", "/tickets/{key}")))
        XCTAssertTrue(inv.matches(key("/dashboard", "/dashboard")))
        XCTAssertFalse(inv.matches(key("/chats/c1", "/chats/{id}")))
        // A path parameter that happens to equal a resource name isn't a resource.
        XCTAssertFalse(inv.matches(key("/chats/inbox", "/chats/{id}")))
    }

    func testQuietHintsSkipTheDashboards() {
        XCTAssertEqual(LiveUpdates.invalidatedRoots("video.updated"), ["videos"])
        XCTAssertEqual(LiveUpdates.invalidatedRoots("video.created"), ["videos", "dashboard", "epics", "agent-overviews"])
    }

    func testRunEventsWithIdsArePathPrefixes() {
        let inv = LiveUpdates.invalidation(for: ServerEvent(type: "run.events", ids: ["r1"]))
        XCTAssertTrue(inv.matches(key("/runs/r1/events", "/runs/{id}/events")))
        XCTAssertFalse(inv.matches(key("/runs/r2", "/runs/{id}")))
        XCTAssertFalse(inv.matches(key("/runs", "/runs")))

        let all = LiveUpdates.invalidation(for: ServerEvent(type: "run.events"))
        XCTAssertTrue(all.matches(key("/runs", "/runs")))
    }

    func testWebKeyAliasesReachTheirEndpoints() {
        let chat = LiveUpdates.invalidation(for: ServerEvent(type: "chat.updated", ids: ["c1"]))
        XCTAssertTrue(chat.matches(key("/persona-dock", "/persona-dock")))
        XCTAssertTrue(chat.matches(key("/chat-search", "/chat-search")))
        XCTAssertTrue(chat.matches(key("/chats/c1/videos", "/chats/{id}/videos")))
    }

    func testUnknownEntitiesOnlyRefreshDashboards() {
        XCTAssertEqual(LiveUpdates.invalidatedRoots("mystery.updated"), ["dashboard", "epics", "agent-overviews"])
    }

    func testSSELineCarriesIds() {
        XCTAssertEqual(
            SSE.event(fromLine: #"data: {"type":"run.events","ids":["r1",7,"r2"]}"#),
            ServerEvent(type: "run.events", ids: ["r1", "r2"])
        )
        XCTAssertEqual(SSE.event(fromLine: #"data: {"type":"inbox.updated"}"#), ServerEvent(type: "inbox.updated"))
        XCTAssertNil(SSE.event(fromLine: ": keepalive"))
    }

    func testSettingsHintsInvalidateMatchingSettingsEndpoints() {
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "profile.updated")).matches(key("/me", "/me")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "memory.updated")).matches(key("/memories", "/memories")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "secret.updated")).matches(key("/secrets", "/secrets")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "secret.updated")).matches(key("/chat-models", "/chat-models")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "api_secret.updated")).matches(key("/api-secrets", "/api-secrets")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "connector.updated")).matches(key("/connectors", "/connectors")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "repository.updated")).matches(key("/repositories", "/repositories")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "runner.updated")).matches(key("/runner/environment", "/runner/environment")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "dev_workspace.updated")).matches(key("/dev-workspace", "/dev-workspace")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "space.updated")).matches(key("/chat-spaces", "/chat-spaces")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "persona.updated")).matches(key("/personas", "/personas")))
    }

    func testLearnHintsInvalidateCourses() {
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "course.updated")).matches(key("/learn/courses", "/learn/courses")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "course.updated")).matches(key("/learn/courses/c1", "/learn/courses/{id}")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "learning.updated")).matches(key("/learn/courses/c1", "/learn/courses/{id}")))
        XCTAssertTrue(LiveUpdates.invalidation(for: ServerEvent(type: "run.updated")).matches(key("/learn/courses/c1", "/learn/courses/{id}")))
    }
}
