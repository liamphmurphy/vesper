import Foundation
import Observation

/// One cached query: the last answer, the last error, and whether a fetch is in flight. Views read
/// it directly; it is `@Observable`, so they redraw when it changes.
@MainActor
@Observable
public final class QueryEntry<Value: Sendable> {
    public let key: QueryKey
    public internal(set) var data: Value?
    public internal(set) var error: APIError?
    public internal(set) var isFetching = false
    public internal(set) var updatedAt: Date?
    @ObservationIgnored public internal(set) var isInvalidated = false

    @ObservationIgnored let fetch: @Sendable (APIClient) async throws -> Value
    /// Bumped by every local write (optimistic update, rollback, `setData`); a fetch that started
    /// before the write is older than it and is dropped.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var lastAttempt: Date?
    @ObservationIgnored var refetchWhenDone = false
    @ObservationIgnored var observers = 0
    @ObservationIgnored var lastUsed: Date
    @ObservationIgnored var task: Task<Void, Never>?

    init(key: QueryKey, now: Date, fetch: @escaping @Sendable (APIClient) async throws -> Value) {
        self.key = key
        self.lastUsed = now
        self.fetch = fetch
    }

    /// True while there's an answer to show, even a stale one.
    public var hasData: Bool { data != nil }
}

/// The type-erased side of `QueryEntry` the store works with.
@MainActor
protocol StoredQuery: AnyObject {
    var key: QueryKey { get }
    var observers: Int { get set }
    var lastUsed: Date { get }
    var isFetching: Bool { get }
    func markInvalidated()
    func cancel()
    func refetch(in store: QueryStore)
}

extension QueryEntry: StoredQuery {
    func markInvalidated() { isInvalidated = true }
    func cancel() { task?.cancel() }
    func refetch(in store: QueryStore) { store.refetchNow(self) }
}

/// A local change applied to a cached query before a mutation lands, undone if it fails.
@MainActor
public struct OptimisticUpdate {
    let key: QueryKey
    let apply: (QueryStore) -> (() -> Void)?

    /// Changes the cached answer of `request` in place. Does nothing when nothing is cached yet.
    public static func update<V: Sendable>(_ request: APIRequest<V>, _ change: @escaping (inout V) -> Void) -> OptimisticUpdate {
        OptimisticUpdate(key: request.key) { store in
            guard let entry = store.existingEntry(request), var value = entry.data else { return nil }
            let previous = value
            change(&value)
            store.write(value, to: entry)
            return { [weak entry, weak store] in
                guard let entry, let store else { return }
                store.write(previous, to: entry)
            }
        }
    }
}

/// The native screens' shared data cache: the Swift counterpart of the web's React Query client.
///
/// - Queries are keyed by their request's path and query string, so every window and screen that asks
///   for `API.getTicket(key: "PAY-1")` shares one entry and one fetch.
/// - `handle(_:)` takes the /events change hints and marks matching entries stale (the same table
///   as the web, `LiveUpdates`); entries a view is observing refetch at once, the rest on next use.
/// - `mutate` applies optimistic updates, sends the request, and rolls them back if it fails.
@MainActor
@Observable
public final class QueryStore {
    public private(set) var client: APIClient?

    @ObservationIgnored private var entries: [QueryKey: any StoredQuery] = [:]
    @ObservationIgnored private let staleAfter: TimeInterval
    @ObservationIgnored private let now: () -> Date

    /// - Parameters:
    ///   - staleAfter: how long an answer counts as fresh; using an older one refetches it in the background.
    ///   - now: the clock, for tests.
    public init(client: APIClient? = nil, staleAfter: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.staleAfter = staleAfter
        self.now = now
    }

    /// Switches the session. Every cached answer belongs to the old one, so all are dropped.
    public func setClient(_ client: APIClient?) {
        for entry in entries.values { entry.cancel() }
        entries.removeAll()
        self.client = client
    }

    // MARK: Reading

    /// The shared entry for `request`, without fetching. Safe to call while SwiftUI computes a body.
    public func entry<V: Sendable>(_ request: APIRequest<V>) -> QueryEntry<V> {
        if let entry = existingEntry(request) { return entry }
        let entry = QueryEntry<V>(key: request.key, now: now()) { client in try await client.send(request) }
        entries[request.key] = entry
        return entry
    }

    /// The entry for `request`, fetching it when it has never been fetched, was invalidated, or is older
    /// than `staleAfter`. Call from `.task`/`onAppear`, not from a view body (it changes observed state).
    @discardableResult
    public func load<V: Sendable>(_ request: APIRequest<V>) -> QueryEntry<V> {
        let entry = entry(request)
        entry.lastUsed = now()
        if needsFetch(entry) { startFetch(entry) }
        return entry
    }

    /// Fetches `request` now and waits for the answer (pull to refresh, tests).
    @discardableResult
    public func refetch<V: Sendable>(_ request: APIRequest<V>) async -> QueryEntry<V> {
        let entry = entry(request)
        entry.lastUsed = now()
        if entry.isFetching {
            entry.refetchWhenDone = true
        } else {
            startFetch(entry)
        }
        while let task = entry.task {
            await task.value
            if entry.task == task { break }
        }
        return entry
    }

    /// While observed, an entry refetches as soon as it's invalidated. Pair every call with `stopObserving`.
    public func observe<V: Sendable>(_ request: APIRequest<V>) { entry(request).observers += 1 }

    public func stopObserving(_ key: QueryKey) {
        guard let entry = entries[key] else { return }
        entry.observers = max(0, entry.observers - 1)
    }

    func existingEntry<V: Sendable>(_ request: APIRequest<V>) -> QueryEntry<V>? {
        entries[request.key] as? QueryEntry<V>
    }

    private func needsFetch<V>(_ entry: QueryEntry<V>) -> Bool {
        guard !entry.isFetching else { return false }
        if entry.isInvalidated { return true }
        guard let last = entry.lastAttempt else { return true }
        return now().timeIntervalSince(last) >= staleAfter
    }

    private func startFetch<V: Sendable>(_ entry: QueryEntry<V>) {
        guard let client else { return }
        entry.isFetching = true
        entry.lastAttempt = now()
        let generation = entry.generation
        let fetch = entry.fetch
        entry.task = Task { [weak self, weak entry] in
            let result: Result<V, any Error>
            do { result = .success(try await fetch(client)) } catch { result = .failure(error) }
            guard let self, let entry else { return }
            self.finish(entry, result: result, generation: generation, client: client)
        }
    }

    private func finish<V: Sendable>(_ entry: QueryEntry<V>, result: Result<V, any Error>, generation: Int, client: APIClient) {
        if entry.isFetching { entry.isFetching = false }
        entry.task = nil
        // A newer session, or a local write since this fetch began, makes the answer outdated.
        guard self.client === client, (entries[entry.key] as AnyObject?) === entry else { return }
        if generation == entry.generation {
            switch result {
            case .success(let value):
                // Skip writing identical Equatable payloads so SSE refetches while a persona is
                // working don't re-evaluate unrelated views that observe `.data`.
                if let existing = entry.data, Self.valuesEqual(existing, value) {
                    // Unchanged
                } else {
                    entry.data = value
                }
                if entry.error != nil { entry.error = nil }
                entry.updatedAt = now()
                entry.isInvalidated = false
            case .failure(is CancellationError):
                break
            case .failure(let error as APIError):
                if entry.error != error { entry.error = error }
            case .failure:
                if entry.error != .unreachable { entry.error = .unreachable }
            }
        }
        if entry.refetchWhenDone {
            entry.refetchWhenDone = false
            startFetch(entry)
        }
    }

    private static func valuesEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
        guard let a = lhs as? any Equatable else { return false }
        return isEqualExistential(a, rhs)
    }

    private static func isEqualExistential<E: Equatable>(_ lhs: E, _ rhs: Any) -> Bool {
        guard let r = rhs as? E else { return false }
        return lhs == r
    }

    // MARK: Invalidation

    /// Marks every matching entry stale; observed ones refetch now, the rest when next loaded.
    public func invalidate(_ invalidation: QueryInvalidation) {
        guard !invalidation.isEmpty else { return }
        for entry in entries.values where invalidation.matches(entry.key) {
            markStale(entry)
        }
        collectGarbage()
    }

    private func markStale(_ entry: any StoredQuery) {
        entry.markInvalidated()
        if entry.observers > 0 { entry.refetch(in: self) }
    }

    /// Feed every /events hint here.
    public func handle(_ event: ServerEvent) {
        invalidate(LiveUpdates.invalidation(for: event))
    }

    func refetchNow<V: Sendable>(_ entry: QueryEntry<V>) {
        if entry.isFetching {
            entry.refetchWhenDone = true
        } else {
            startFetch(entry)
        }
    }

    /// Drops entries nobody has observed or loaded for `idle` seconds.
    public func collectGarbage(idle: TimeInterval = 300) {
        let cutoff = now().addingTimeInterval(-idle)
        for (key, entry) in entries where entry.observers == 0 && !entry.isFetching && entry.lastUsed < cutoff {
            entries[key] = nil
        }
    }

    var entryCount: Int { entries.count }

    // MARK: Writing

    /// Replaces the cached answer of `request` (e.g. with a mutation's answer).
    public func setData<V: Sendable>(_ value: V, for request: APIRequest<V>) {
        write(value, to: entry(request))
    }

    func write<V: Sendable>(_ value: V, to entry: QueryEntry<V>) {
        entry.generation += 1
        entry.data = value
        entry.error = nil
        entry.updatedAt = now()
    }

    /// Sends a mutation. `optimistic` updates apply first and are rolled back if it fails; on success
    /// the entries they touched and everything `invalidating` matches are refetched.
    @discardableResult
    public func mutate<V: Sendable>(
        _ request: APIRequest<V>, optimistic: [OptimisticUpdate] = [], invalidating: QueryInvalidation = QueryInvalidation()
    ) async throws -> V {
        guard let client else { throw APIError.unauthorized }
        let rollbacks = optimistic.compactMap { $0.apply(self) }
        do {
            let value = try await client.send(request)
            // The server's answer replaces the guesses: refetch what the optimistic updates touched.
            for update in optimistic {
                if let entry = entries[update.key] { markStale(entry) }
            }
            invalidate(invalidating)
            return value
        } catch {
            for rollback in rollbacks.reversed() { rollback() }
            throw error
        }
    }
}
