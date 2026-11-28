import XCTest
@testable import VesperCore

final class PerfHUDMetricsTests: XCTestCase {
    func testSteady120HzProMotionReportsSmoothAndFullFPS() {
        var metrics = PerfHUDMetrics(capacity: 60, targetFPS: 120)
        var t = 100.0
        metrics.recordTick(timestamp: t)
        for _ in 0..<60 {
            t += 1.0 / 120.0
            metrics.recordTick(timestamp: t)
        }
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.fps, 120.0, accuracy: 0.2)
        XCTAssertEqual(snap.onePercentLowFPS, 120.0, accuracy: 0.2)
        XCTAssertEqual(snap.avgFrameTimeMs, 8.333, accuracy: 0.05)
        XCTAssertEqual(snap.hitchCount, 0)
        XCTAssertEqual(snap.health, .smooth)
        XCTAssertEqual(snap.recentFrameTimesMs.count, 60)
    }

    func testSingleHitchSurfacesInOnePercentLowAndHitchCount() {
        var metrics = PerfHUDMetrics(capacity: 60, targetFPS: 120)
        var t = 10.0
        metrics.recordTick(timestamp: t)
        for _ in 0..<59 {
            t += 1.0 / 120.0
            metrics.recordTick(timestamp: t)
        }
        // Inject one 33.3ms (30fps) hitch frame.
        t += 1.0 / 30.0
        metrics.recordTick(timestamp: t)

        let snap = metrics.snapshot()
        XCTAssertEqual(snap.hitchCount, 1)
        XCTAssertEqual(snap.health, .hitch)
        XCTAssertEqual(snap.worstFrameTimeMs, 33.333, accuracy: 0.1)
        XCTAssertEqual(snap.onePercentLowFPS, 30.0, accuracy: 0.5)
        XCTAssertGreaterThan(snap.fps, 100.0)
    }

    func testOcclusionGapsAndNonMonotonicTicksAreIgnored() {
        var metrics = PerfHUDMetrics(capacity: 30, targetFPS: 120)
        metrics.recordTick(timestamp: 1.0)
        metrics.recordTick(timestamp: 1.0 + 1.0 / 120.0)
        // Simulate 4-second pause while minimized/occluded.
        metrics.recordTick(timestamp: 5.0)
        metrics.recordTick(timestamp: 5.0 + 1.0 / 120.0)
        // Non-monotonic timestamp ignored cleanly.
        metrics.recordTick(timestamp: 4.9)

        let snap = metrics.snapshot()
        XCTAssertEqual(snap.recentFrameTimesMs.count, 2)
        XCTAssertEqual(snap.hitchCount, 0)
        XCTAssertEqual(snap.fps, 120.0, accuracy: 0.2)
    }

    func testClassificationAdaptsTo60HzExternalDisplay() {
        var metrics = PerfHUDMetrics(capacity: 16, targetFPS: 60)
        XCTAssertEqual(metrics.classify(frameTimeMs: 16.67), .smooth)
        XCTAssertEqual(metrics.classify(frameTimeMs: 25.0), .caution)
        XCTAssertEqual(metrics.classify(frameTimeMs: 40.0), .hitch)

        metrics.setTargetFPS(120)
        XCTAssertEqual(metrics.classify(frameTimeMs: 8.33), .smooth)
        XCTAssertEqual(metrics.classify(frameTimeMs: 16.67), .caution)
        XCTAssertEqual(metrics.classify(frameTimeMs: 25.0), .hitch)
    }

    func testRingBufferPreservesChronologicalOrderAfterWraparound() {
        var metrics = PerfHUDMetrics(capacity: 8, targetFPS: 120)
        var t = 0.0
        metrics.recordTick(timestamp: t)
        for i in 1...12 {
            t += Double(i) * 0.001
            metrics.recordTick(timestamp: t)
        }
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.recentFrameTimesMs.count, 8)
        XCTAssertEqual(snap.recentFrameTimesMs.first ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(snap.recentFrameTimesMs.last ?? 0, 12.0, accuracy: 0.01)
    }
}
