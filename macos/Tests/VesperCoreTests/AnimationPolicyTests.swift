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

    func testDisplayLinkFrameRateTargetsProMotionAndClampsForExternalPanelsAndLowPower() {
        let working = AnimationPolicy.displayLinkFrameRate(working: true, lowPowerMode: false)
        XCTAssertEqual(working.minimum, 80)
        XCTAssertEqual(working.maximum, 120)
        XCTAssertEqual(working.preferred, 120)

        let idle = AnimationPolicy.displayLinkFrameRate(working: false, lowPowerMode: false)
        XCTAssertEqual(idle.minimum, 60)
        XCTAssertEqual(idle.maximum, 120)
        XCTAssertEqual(idle.preferred, 120)

        let lowPowerWorking = AnimationPolicy.displayLinkFrameRate(working: true, lowPowerMode: true)
        XCTAssertEqual(lowPowerWorking.minimum, 30)
        XCTAssertEqual(lowPowerWorking.maximum, 60)
        XCTAssertEqual(lowPowerWorking.preferred, 30)

        // Clamping onto a 60Hz external display keeps minimum <= preferred <= maximum <= 60.
        let external = working.clamped(toScreenMaxFPS: 60)
        XCTAssertEqual(external.minimum, 60)
        XCTAssertEqual(external.maximum, 60)
        XCTAssertEqual(external.preferred, 60)

        // Clamping onto a 120Hz ProMotion panel preserves the full 80–120Hz range.
        let proMotion = working.clamped(toScreenMaxFPS: 120)
        XCTAssertEqual(proMotion, working)

        // Authored loop cadence locks cleanly without exceeding 60Hz (or 30Hz in Low Power Mode).
        let loop24 = AnimationPolicy.displayLinkFrameRate(forTargetFPS: 24, lowPowerMode: false)
        XCTAssertEqual(loop24.preferred, 24)
        XCTAssertEqual(loop24.maximum, 60)

        let loopLowPower = AnimationPolicy.displayLinkFrameRate(forTargetFPS: 60, lowPowerMode: true)
        XCTAssertEqual(loopLowPower.preferred, 30)
        XCTAssertEqual(loopLowPower.maximum, 30)
    }
}
