import Foundation

/// Rolling main-thread VSync frame-time sampler for the opt-in macOS Performance HUD.
/// Uses a fixed-capacity ring buffer so per-frame sampling (`recordTick`) performs zero heap allocations.
public struct PerfHUDMetrics: Sendable {
    public enum FrameHealth: Equatable, Sendable {
        case smooth
        case caution
        case hitch
    }

    public struct Snapshot: Equatable, Sendable {
        public var fps: Double
        public var onePercentLowFPS: Double
        public var avgFrameTimeMs: Double
        public var worstFrameTimeMs: Double
        public var hitchCount: Int
        public var targetFPS: Int
        public var targetFrameTimeMs: Double
        public var health: FrameHealth
        public var recentFrameTimesMs: [Double]
    }

    /// Gaps larger than this (occlusion, sleep, hidden window) reset timing rather than logging a fake hitch.
    public static let maxContinuousGapSeconds: Double = 0.5

    public let capacity: Int
    public private(set) var targetFPS: Int
    private var ring: [Double]
    private var writeIndex: Int = 0
    private var sampleCount: Int = 0
    private var lastTimestamp: Double?

    public init(capacity: Int = 60, targetFPS: Int = 120) {
        let safeCapacity = max(8, capacity)
        self.capacity = safeCapacity
        self.targetFPS = max(30, targetFPS)
        self.ring = Array(repeating: 0, count: safeCapacity)
    }

    public var count: Int { sampleCount }

    public mutating func setTargetFPS(_ fps: Int) {
        targetFPS = max(30, fps)
    }

    public mutating func reset() {
        writeIndex = 0
        sampleCount = 0
        lastTimestamp = nil
    }

    /// Records one VSync delivery timestamp (in seconds, e.g. `CADisplayLink.timestamp`).
    /// Performs O(1) work with zero heap allocations.
    public mutating func recordTick(timestamp: Double) {
        guard timestamp.isFinite else { return }
        guard let prev = lastTimestamp else {
            lastTimestamp = timestamp
            return
        }
        let delta = timestamp - prev
        lastTimestamp = timestamp
        guard delta > 0 else { return }
        if delta > Self.maxContinuousGapSeconds {
            return
        }
        ring[writeIndex] = delta * 1000.0
        writeIndex = (writeIndex + 1) % capacity
        if sampleCount < capacity {
            sampleCount += 1
        }
    }

    /// Classifies a single frame duration in milliseconds relative to `targetFPS`.
    public func classify(frameTimeMs: Double) -> FrameHealth {
        let budget = 1000.0 / Double(targetFPS)
        if frameTimeMs <= budget * 1.15 {
            return .smooth
        }
        if frameTimeMs <= max(budget * 2.15, 18.0) {
            return .caution
        }
        return .hitch
    }

    /// Aggregates rolling FPS, 1% low FPS, average/worst frame times, hitch count, and chronological
    /// sparkline samples. Designed to be called at HUD redraw cadence (~4 Hz), not every VSync.
    public func snapshot() -> Snapshot {
        let targetMs = 1000.0 / Double(targetFPS)
        guard sampleCount > 0 else {
            return Snapshot(
                fps: 0,
                onePercentLowFPS: 0,
                avgFrameTimeMs: 0,
                worstFrameTimeMs: 0,
                hitchCount: 0,
                targetFPS: targetFPS,
                targetFrameTimeMs: targetMs,
                health: .smooth,
                recentFrameTimesMs: []
            )
        }

        var ordered: [Double] = []
        ordered.reserveCapacity(sampleCount)
        let startIndex = sampleCount < capacity ? 0 : writeIndex
        var sumMs = 0.0
        var worstMs = 0.0
        var hitches = 0
        for offset in 0..<sampleCount {
            let ms = ring[(startIndex + offset) % capacity]
            ordered.append(ms)
            sumMs += ms
            if ms > worstMs { worstMs = ms }
            if classify(frameTimeMs: ms) == .hitch { hitches += 1 }
        }

        let avgMs = sumMs / Double(sampleCount)
        let fps = avgMs > 0 ? (1000.0 / avgMs) : 0

        let sorted = ordered.sorted()
        let p99Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99 + 0.999))
        let p99Ms = sorted[p99Index]
        let onePercentLow = p99Ms > 0 ? (1000.0 / p99Ms) : 0

        let health: FrameHealth = if hitches > 0 {
            .hitch
        } else {
            classify(frameTimeMs: avgMs)
        }

        return Snapshot(
            fps: fps,
            onePercentLowFPS: onePercentLow,
            avgFrameTimeMs: avgMs,
            worstFrameTimeMs: worstMs,
            hitchCount: hitches,
            targetFPS: targetFPS,
            targetFrameTimeMs: targetMs,
            health: health,
            recentFrameTimesMs: ordered
        )
    }
}
