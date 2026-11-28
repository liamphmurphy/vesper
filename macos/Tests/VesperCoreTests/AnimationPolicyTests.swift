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
        XCTAssertEqual(AnimationPolicy.activitySceneTickInterval, 1.0 / 60.0, accuracy: 1e-6)
        XCTAssertEqual(AnimationPolicy.activitySceneTickInterval(lowPowerMode: false), 1.0 / 60.0, accuracy: 1e-6)
        XCTAssertEqual(AnimationPolicy.activitySceneTickInterval(lowPowerMode: true), 1.0 / 30.0, accuracy: 1e-6)
        XCTAssertGreaterThan(
            AnimationPolicy.activitySceneTickInterval(lowPowerMode: true),
            AnimationPolicy.activitySceneTickInterval(lowPowerMode: false)
        )

        // Display-link minimumInterval leaves a 10% VSync jitter margin so 60Hz/120Hz ProMotion panels
        // lock cleanly to every 2nd VSync (60fps) or 4th VSync (30fps) instead of dropping frames.
        let normalMin = AnimationPolicy.activitySceneDisplayLinkMinimumInterval(lowPowerMode: false)
        XCTAssertGreaterThan(normalMin, 1.0 / 120.0)
        XCTAssertLessThan(normalMin, 1.0 / 60.0)
        XCTAssertEqual(normalMin, 0.015, accuracy: 1e-6)

        let lowPowerMin = AnimationPolicy.activitySceneDisplayLinkMinimumInterval(lowPowerMode: true)
        XCTAssertGreaterThan(lowPowerMin, 3.0 / 120.0)
        XCTAssertLessThan(lowPowerMin, 1.0 / 30.0)
        XCTAssertEqual(lowPowerMin, 0.030, accuracy: 1e-6)
    }
}
