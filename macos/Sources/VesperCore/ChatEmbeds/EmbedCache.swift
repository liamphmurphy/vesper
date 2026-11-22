import Foundation

/// A block drawn once off-screen: a one-page PDF (vector, so it stays sharp at any zoom) and its size
/// in points. `svg` is the self-contained SVG Save to Library sends, for diagrams; `ascent` is how far
/// the baseline sits below the top, for math set inline with text.
public struct RenderedEmbed: Sendable, Equatable {
    public var pdf: Data
    public var width: Double
    public var height: Double
    public var ascent: Double?
    public var svg: String?

    public init(pdf: Data, width: Double, height: Double, ascent: Double? = nil, svg: String? = nil) {
        self.pdf = pdf
        self.width = width
        self.height = height
        self.ascent = ascent
        self.svg = svg
    }
}

/// A least-recently-used cache with a count and a cost limit, safe from any thread. Rendered embeds
/// are keyed per message, theme and source (`EmbedCacheKey`), so a transcript that scrolls back, or a
/// theme that flips back, draws nothing again.
public final class EmbedLRUCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    public let countLimit: Int
    public let costLimit: Int

    private let lock = NSLock()
    private var entries: [Key: (value: Value, cost: Int)] = [:]
    /// Least recent first.
    private var order: [Key] = []
    private var totalCost = 0

    public init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(1, countLimit)
        self.costLimit = max(1, costLimit)
    }

    public func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    /// Stores `value`, then drops the least recently used entries until both limits hold. An entry
    /// costing more than the whole limit isn't kept.
    public func insert(_ value: Value, for key: Key, cost: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard cost <= costLimit else { return }
        if let old = entries[key] {
            totalCost -= old.cost
            order.removeAll { $0 == key }
        }
        entries[key] = (value, cost)
        order.append(key)
        totalCost += cost
        while entries.count > countLimit || totalCost > costLimit, let oldest = order.first {
            order.removeFirst()
            totalCost -= entries.removeValue(forKey: oldest)?.cost ?? 0
        }
    }

    public func removeValue(for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard let old = entries.removeValue(forKey: key) else { return }
        totalCost -= old.cost
        order.removeAll { $0 == key }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Keys from least to most recently used.
    public var keys: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    private func touch(_ key: Key) {
        if order.last == key { return }
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// The app-wide cache of drawn embeds: 400 entries or 96 MB of PDF, whichever comes first.
public enum EmbedRenderCache {
    public static let shared = EmbedLRUCache<EmbedCacheKey, RenderedEmbed>(countLimit: 400, costLimit: 96 << 20)
}

/// Bookkeeping for a pool of reusable live views (app blocks' web views): which owner holds which
/// slot, which slots sit idle for reuse, and which owner to evict when every slot is taken. The views
/// themselves are the platform's; this only decides, so it's the same on macOS and iOS.
public struct EmbedPoolLedger<Owner: Hashable & Sendable>: Sendable {
    public enum Acquisition: Equatable, Sendable {
        /// The owner already holds this slot.
        case existing(Int)
        /// An idle view in this slot is the owner's now.
        case reuse(Int)
        /// Make a new view for this slot.
        case create(Int)
        /// Every slot is busy: snapshot `previous`, take its view away, and give the slot to the owner.
        case evict(Int, previous: Owner)

        public var slot: Int {
            switch self {
            case .existing(let s), .reuse(let s), .create(let s), .evict(let s, _): s
            }
        }
    }

    /// At most this many views exist at once.
    public let capacity: Int
    /// Each created slot's owner, nil while it's idle.
    public private(set) var slots: [Owner?] = []
    private var lastUse: [Owner: UInt64] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func slot(of owner: Owner) -> Int? { slots.firstIndex(of: owner) }

    /// Owners holding a view, least recently used first.
    public var liveOwners: [Owner] {
        slots.compactMap { $0 }.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
    }

    public var idleCount: Int { slots.filter { $0 == nil }.count }

    /// A view for `owner`: its own, an idle one, a new one while under capacity, or the least recently
    /// used owner's.
    public mutating func acquire(_ owner: Owner) -> Acquisition {
        clock += 1
        defer { lastUse[owner] = clock }
        if let held = slot(of: owner) { return .existing(held) }
        if let idle = slots.firstIndex(where: { $0 == nil }) {
            slots[idle] = owner
            return .reuse(idle)
        }
        if slots.count < capacity {
            slots.append(owner)
            return .create(slots.count - 1)
        }
        let victim = liveOwners[0]
        let at = slot(of: victim)!
        slots[at] = owner
        lastUse[victim] = nil
        return .evict(at, previous: victim)
    }

    /// Marks the owner's view as just used, so it's the last to be evicted.
    public mutating func touch(_ owner: Owner) {
        guard slot(of: owner) != nil else { return }
        clock += 1
        lastUse[owner] = clock
    }

    /// Gives the owner's view back (it scrolled off): the slot stays, idle, for the next owner.
    @discardableResult
    public mutating func release(_ owner: Owner) -> Int? {
        guard let at = slot(of: owner) else { return nil }
        slots[at] = nil
        lastUse[owner] = nil
        return at
    }
}
