import XCTest
@testable import VesperCore

final class AnimationPolicyTests: XCTestCase {
    func testIdleAnimationsPauseWhenHiddenOccludedBackgroundedOrLowPower() {
        let activeVisible = AnimationPolicy.Context(reduceMotion: false, windowVisible: true, appActive: true, lowPowerMode: false)
        XCTAssertTrue(AnimationPolicy.shouldAnimate(working: false, context: activeVisible))

        XCTAssertFalse(AnimationPolicy.shouldAnimate(
            working: false,
            context: AnimationPolicy.Context(reduceMotion: true, windowVisible: true, appActive: true, lowPowerMode: false)
        ))
        XCTAssertFalse(AnimationPolicy.shouldAnimate(
            working: false,
            context: AnimationPolicy.Context(reduceMotion: false, windowVisible: false, appActive: true, lowPowerMode: false)
        ))
        XCTAssertFalse(AnimationPolicy.shouldAnimate(
            working: false,
            context: AnimationPolicy.Context(reduceMotion: false, windowVisible: true, appActive: false, lowPowerMode: false)
        ), "idle animations must pause when another app is in the foreground")
        XCTAssertFalse(AnimationPolicy.shouldAnimate(
            working: false,
            context: AnimationPolicy.Context(reduceMotion: false, windowVisible: true, appActive: true, lowPowerMode: true)
        ), "idle animations must pause in Low Power Mode")
    }

    func testWorkingAnimationsKeepRunningWhenVisibleSideBySide() {
        XCTAssertTrue(AnimationPolicy.shouldAnimate(
            working: true,
            context: AnimationPolicy.Context(reduceMotion: false, windowVisible: true, appActive: false, lowPowerMode: false)
        ), "working animations stay visible beside another focused app")
        XCTAssertTrue(AnimationPolicy.shouldAnimate(
            working: true,
            context: AnimationPolicy.Context(reduceMotion: false, windowVisible: true, appActive: false, lowPowerMode: true)
        ))
        XCTAssertFalse(AnimationPolicy.shouldAnimate(
            working: true,
            context: AnimationPolicy.Context(reduceMotion: false, windowVisible: false, appActive: true, lowPowerMode: false)
        ), "occluded or hidden windows must not animate even when working")
        XCTAssertFalse(AnimationPolicy.shouldAnimate(
            working: true,
            context: AnimationPolicy.Context(reduceMotion: true, windowVisible: true, appActive: true, lowPowerMode: false)
        ))
    }

    func testPeriodicIntervalsAreCappedAndSlowerWhenIdle() {
        XCTAssertEqual(AnimationPolicy.harnessTickInterval(working: true), 1.0 / 24.0, accuracy: 1e-6)
        XCTAssertEqual(AnimationPolicy.harnessTickInterval(working: false), 1.0 / 10.0, accuracy: 1e-6)
        XCTAssertGreaterThan(
            AnimationPolicy.harnessTickInterval(working: false),
            AnimationPolicy.harnessTickInterval(working: true)
        )
        XCTAssertEqual(AnimationPolicy.activitySceneTickInterval, 1.0 / 24.0, accuracy: 1e-6)
    }
}
