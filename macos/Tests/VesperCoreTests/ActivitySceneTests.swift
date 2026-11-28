import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import VesperCore

final class ActivitySceneTests: XCTestCase {
    private static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/activity-scenes/fixtures.json")

    private struct Fixtures: Decodable {
        struct ViewBox: Decodable { var width: Double; var height: Double }
        struct Timing: Decodable { var holdMs: Double; var fadeMs: Double; var windDownMs: Double }
        struct AnimSpec: Decodable {
            var duration: Double
            var easing: String
            var direction: String
            var directions: [String]?
            var fillMode: String
            var stops: [Double]
        }
        var viewBox: ViewBox
        var timing: Timing
        var kinds: [String]
        var uniqueScenes: [String]
        var splitAliases: [String: String]
        var animations: [String: AnimSpec]
    }

    private func loadFixtures() throws -> Fixtures {
        let data = try Data(contentsOf: Self.fixturesURL)
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func nonTransparentPixelCount(_ data: Data) -> Int {
        var count = 0
        let bytes = [UInt8](data)
        var i = 3
        while i < bytes.count {
            if bytes[i] > 0 { count += 1 }
            i += 4
        }
        return count
    }

    // MARK: - Fixture Parity

    func testCoversAllKindsAliasesTimingAndKeyframesFromWebFixtures() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.viewBox.width, ActivitySceneDefinition.viewBoxSize.width)
        XCTAssertEqual(fixtures.viewBox.height, ActivitySceneDefinition.viewBoxSize.height)
        XCTAssertEqual(ActivitySceneTransitioner.holdDuration * 1000, fixtures.timing.holdMs, accuracy: 1e-6)
        XCTAssertEqual(ActivitySceneTransitioner.fadeDuration * 1000, fixtures.timing.fadeMs, accuracy: 1e-6)
        XCTAssertEqual(ActivitySceneTransitioner.windDownDuration * 1000, fixtures.timing.windDownMs, accuracy: 1e-6)

        XCTAssertEqual(ActivitySceneKind.allCases.map(\.rawValue), fixtures.kinds)
        XCTAssertEqual(ActivitySceneKind.uniqueSceneKinds.count, fixtures.uniqueScenes.count)
        XCTAssertEqual(Set(ActivitySceneKind.uniqueSceneKinds.map(\.rawValue)), Set(fixtures.uniqueScenes))

        let swiftAliases = Dictionary(uniqueKeysWithValues: ActivitySceneKind.splitAliases.map { ($0.key.rawValue, $0.value.rawValue) })
        XCTAssertEqual(swiftAliases, fixtures.splitAliases)

        var seenAnimations = Set<String>()
        for kind in ActivitySceneKind.uniqueSceneKinds {
            let def = try XCTUnwrap(ActivitySceneCatalog.definitions[kind], "Missing catalog definition for \(kind.rawValue)")
            let anims = def.collectedAnimations()
            XCTAssertFalse(anims.isEmpty, "Scene \(kind.rawValue) has no animations")

            for anim in anims {
                seenAnimations.insert(anim.name)
                let spec = try XCTUnwrap(fixtures.animations[anim.name], "Unknown animation \(anim.name) in \(kind.rawValue)")
                if anim.name == "scene-bar" && kind == .runs {
                    XCTAssertTrue([2.6, 3.7, 3.1].contains(anim.duration), "Unexpected runs bar duration \(anim.duration)")
                } else {
                    XCTAssertEqual(anim.duration, spec.duration, accuracy: 1e-6, "Duration mismatch for \(anim.name)")
                }
                XCTAssertEqual(anim.easing.cssName, spec.easing, "Easing mismatch for \(anim.name)")
                let validDirections = spec.directions ?? [spec.direction]
                XCTAssertTrue(validDirections.contains(anim.direction.rawValue), "Direction mismatch for \(anim.name)")
                XCTAssertEqual(anim.fillMode.rawValue, spec.fillMode, "FillMode mismatch for \(anim.name)")
                XCTAssertEqual(anim.keyframeStopsPercent, spec.stops, "Stops mismatch for \(anim.name)")
            }
        }

        let expectedAnimations = Set(fixtures.animations.keys)
        XCTAssertEqual(seenAnimations, expectedAnimations, "Missing animations: \(expectedAnimations.subtracting(seenAnimations))")
    }

    // MARK: - Bitmap Snapshot & Motion Tests Across All 59 Kinds

    func testAll59ScenesRenderDeterministicallyAnimateAndFreezeUnderReduceMotion() {
        // Scenes whose CSS keyframes begin with all elements invisible at 0% (opacity: 0 / scale: 0 / dashoffset: 1).
        let emptyAtZero: Set<ActivitySceneKind> = [.projects, .space]
        let times = [0.0, 0.45, 1.15]

        for kind in ActivitySceneKind.allCases {
            var frameHashes: [String] = []
            for t in times {
                let bmpA = ActivitySceneRenderer.renderBitmap(kind, at: t, palette: .dark)
                let bmpB = ActivitySceneRenderer.renderBitmap(kind, at: t, palette: .dark)
                XCTAssertEqual(bmpA.count, 264 * 112 * 4)
                let hashA = sha256Hex(bmpA)
                let hashB = sha256Hex(bmpB)
                XCTAssertEqual(hashA, hashB, "\(kind.rawValue) not deterministic at t=\(t)")
                frameHashes.append(hashA)

                let drawn = nonTransparentPixelCount(bmpA)
                if t == 0.0 && emptyAtZero.contains(kind) {
                    XCTAssertEqual(drawn, 0, "\(kind.rawValue) expected empty at t=0.0")
                } else {
                    XCTAssertGreaterThan(drawn, 10, "\(kind.rawValue) produced empty bitmap at t=\(t)")
                }
            }

            XCTAssertGreaterThanOrEqual(
                Set(frameHashes).count, 2,
                "\(kind.rawValue) did not animate across t=0.0, 0.45, 1.15"
            )

            let frozenZero = ActivitySceneRenderer.renderBitmap(kind, at: 0.0, palette: .dark, reduceMotion: true)
            let frozenLater = ActivitySceneRenderer.renderBitmap(kind, at: 1.15, palette: .dark, reduceMotion: true)
            XCTAssertGreaterThan(nonTransparentPixelCount(frozenZero), 10, "\(kind.rawValue) frozen frame empty")
            XCTAssertEqual(sha256Hex(frozenZero), sha256Hex(frozenLater), "\(kind.rawValue) moved under reduceMotion")
        }
    }

    func testSplitAliasesMatchBackingScenePixels() {
        for (alias, backing) in ActivitySceneKind.splitAliases {
            for t in [0.0, 0.45, 1.15] {
                let aliasBmp = ActivitySceneRenderer.renderBitmap(alias, at: t, palette: .dark)
                let backingBmp = ActivitySceneRenderer.renderBitmap(backing, at: t, palette: .dark)
                XCTAssertEqual(aliasBmp, backingBmp, "\(alias.rawValue) != \(backing.rawValue) at t=\(t)")
            }
            let aliasFrozen = ActivitySceneRenderer.renderBitmap(alias, at: 0, palette: .light, reduceMotion: true)
            let backingFrozen = ActivitySceneRenderer.renderBitmap(backing, at: 0, palette: .light, reduceMotion: true)
            XCTAssertEqual(aliasFrozen, backingFrozen)
        }
    }

    func testImageBlurAndTopDownOrientationAndPalettes() {
        let blurred = ActivitySceneRenderer.renderBitmap(.image, at: 0.0, palette: .dark)
        let sharp = ActivitySceneRenderer.renderBitmap(.image, at: 2.5, palette: .dark)
        XCTAssertNotEqual(sha256Hex(blurred), sha256Hex(sharp))

        // Verify Y-down orientation on `image` at t=2.5 (bottom row tiles are stateDone green; top row has accent/border).
        let width = 264
        let height = 112
        let bytes = [UInt8](sharp)
        var topGreenCount = 0
        var bottomGreenCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r = Int(bytes[idx]), g = Int(bytes[idx + 1]), b = Int(bytes[idx + 2]), a = Int(bytes[idx + 3])
                if a > 200 && g > r + 20 && g > b + 20 {
                    if y < height / 2 { topGreenCount += 1 } else { bottomGreenCount += 1 }
                }
            }
        }
        XCTAssertEqual(topGreenCount, 0)
        XCTAssertGreaterThan(bottomGreenCount, 50)

        let darkThinking = ActivitySceneRenderer.renderBitmap(.thinking, at: 0.45, palette: .dark)
        let lightThinking = ActivitySceneRenderer.renderBitmap(.thinking, at: 0.45, palette: .light)
        XCTAssertNotEqual(darkThinking, lightThinking)
    }

    // MARK: - Transitioner State Machine

    func testTransitionerHoldRapidSkipCrossfadeAndWindDown() {
        var t = ActivitySceneTransitioner(initial: .thinking, at: 0.0)

        // Rapid transient kind inside 800ms hold gets skipped when superseded before hold expires.
        t.request(.readingCode, at: 0.2)
        t.request(.writingCode, at: 0.4)
        XCTAssertEqual(t.current, .thinking)
        XCTAssertNil(t.previous)

        t.advance(to: 0.79)
        XCTAssertEqual(t.current, .thinking)

        // Hold expires at 0.8s -> switches directly to writingCode, skips readingCode, starts 240ms crossfade + scale settle.
        t.advance(to: 0.92)
        XCTAssertEqual(t.current, .writingCode)
        XCTAssertEqual(t.previous, .thinking)
        XCTAssertGreaterThan(t.currentOpacity(at: 0.92), 0.1)
        XCTAssertLessThan(t.currentOpacity(at: 0.92), 1.0)
        XCTAssertGreaterThan(t.previousOpacity(at: 0.92), 0.0)
        XCTAssertLessThan(t.previousOpacity(at: 0.92), 0.9)
        XCTAssertGreaterThan(t.currentScale(at: 0.92), 0.95)
        XCTAssertLessThan(t.currentScale(at: 0.92), 1.0)
        XCTAssertGreaterThan(t.previousScale(at: 0.92), 0.98)
        XCTAssertLessThan(t.previousScale(at: 0.92), 1.0)

        // Crossfade finishes at 0.8 + 0.24 = 1.04s.
        t.advance(to: 1.05)
        XCTAssertNil(t.previous)
        XCTAssertEqual(t.currentOpacity(at: 1.05), 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.currentScale(at: 1.05), 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.previousScale(at: 1.05), 1.0, accuracy: 1e-6)

        // Returning to current kind inside hold cancels pending transition.
        t.request(.tests, at: 1.1)
        t.request(.writingCode, at: 1.2)
        t.advance(to: 2.0)
        XCTAssertEqual(t.current, .writingCode)
        XCTAssertNil(t.previous)

        // Wind-down coasts linearly to 0 over 600ms (exact integral = 0.3s virtual clock advance).
        t.setStopping(true, at: 2.0)
        XCTAssertEqual(t.playbackRate(at: 2.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.playbackRate(at: 2.3), 0.5, accuracy: 1e-6)
        XCTAssertEqual(t.playbackRate(at: 2.6), 0.0, accuracy: 1e-6)

        let clockBeforeStop = t.currentClock
        t.advance(to: 2.6)
        XCTAssertEqual(t.currentClock - clockBeforeStop, 0.3, accuracy: 1e-6)

        // Virtual clock remains frozen once wound down.
        t.advance(to: 4.0)
        XCTAssertEqual(t.currentClock - clockBeforeStop, 0.3, accuracy: 1e-6)

        // Canceling stop resumes normal playback speed.
        t.setStopping(false, at: 4.0)
        XCTAssertEqual(t.playbackRate(at: 4.0), 1.0, accuracy: 1e-6)
        t.advance(to: 4.5)
        XCTAssertEqual(t.currentClock - clockBeforeStop, 0.8, accuracy: 1e-6)
    }

    // MARK: - SVGPathParser & Trimming

    func testSVGPathParserSupportsAllCommandsArcsAndTrimming() {
        // Basic commands + smooth curves + closepath.
        let path = SVGPathParser.parseUncached("M0 0 L10 0 H20 V10 C20 20 30 20 30 10 S40 0 40 10 Q45 20 50 10 T60 10 Z")
        XCTAssertFalse(path.isEmpty)
        XCTAssertGreaterThan(SVGPathParser.totalLength(path), 60)

        // Compact arc flag syntax from persona & canvas scenes.
        let circleArc = SVGPathParser.parseUncached("M66 13a8 8 0 1 1-.01 0")
        let box = circleArc.boundingBoxOfPath
        XCTAssertEqual(box.minX, 58, accuracy: 0.2)
        XCTAssertEqual(box.maxX, 74, accuracy: 0.2)
        XCTAssertEqual(box.minY, 13, accuracy: 0.2)
        XCTAssertEqual(box.maxY, 29, accuracy: 0.2)

        let cloud = SVGPathParser.parseUncached("M92 28a8 8 0 0 1 0-16 11 11 0 0 1 21-2 9 9 0 0 1 3 18z")
        XCTAssertFalse(cloud.isEmpty)
        XCTAssertGreaterThan(SVGPathParser.totalLength(cloud), 60)

        // Multi-subpath pathLength=1 trimming (`connector` scene).
        let multi = SVGPathParser.parseUncached("M64 23H82M64 33H82")
        XCTAssertEqual(SVGPathParser.totalLength(multi), 36, accuracy: 1e-4)
        XCTAssertTrue(SVGPathParser.trimmedPath(multi, from: 0, to: 0).isEmpty)
        XCTAssertEqual(SVGPathParser.totalLength(SVGPathParser.trimmedPath(multi, from: 0, to: 0.5)), 18, accuracy: 1e-3)
        XCTAssertEqual(SVGPathParser.totalLength(SVGPathParser.trimmedPath(multi, from: 0, to: 1.0)), 36, accuracy: 1e-3)

        // Cubic curve midpoint trim.
        let cubic = SVGPathParser.parseUncached("M0 0 C0 50 100 50 100 0")
        let fullLen = SVGPathParser.totalLength(cubic)
        let halfLen = SVGPathParser.totalLength(SVGPathParser.trimmedPath(cubic, from: 0, to: 0.5))
        XCTAssertEqual(halfLen, fullLen * 0.5, accuracy: 1.0)
    }

    // MARK: - MotionPrimitives Channel Interpolation & Easings

    func testMotionPrimitivesPerChannelInterpolationStepsAndEasings() {
        // `scene-scan` defines ty only at 0%/100% and opacity at 0%/12%/88%/100%.
        let scan = MotionAnimation(
            name: "scene-scan",
            duration: 2.2,
            easing: .linear,
            keyframes: [
                .at(0.0, ty: -13, opacity: 0),
                .at(0.12, opacity: 0.25),
                .at(0.88, opacity: 0.25),
                .at(1.0, ty: 17, opacity: 0),
            ]
        )
        let mid = scan.pose(at: 1.1, base: MotionPose(opacity: 0.25))
        XCTAssertEqual(mid.ty, 2.0, accuracy: 1e-6)
        XCTAssertEqual(mid.opacity, 0.25, accuracy: 1e-6)

        // Stepped easing.
        let steps3 = MotionAnimation(
            name: "scene-scroll-3",
            duration: 3.0,
            easing: .steps(3),
            keyframes: [.at(1.0, ty: -30)]
        )
        XCTAssertEqual(steps3.pose(at: 0.5).ty, 0.0, accuracy: 1e-6)
        XCTAssertEqual(steps3.pose(at: 1.01).ty, -10.0, accuracy: 1e-6)
        XCTAssertEqual(steps3.pose(at: 2.01).ty, -20.0, accuracy: 1e-6)

        // Positive delay + fillMode: .none vs .both.
        let animNone = MotionAnimation(name: "n", duration: 2, delay: 0.5, fillMode: .none, keyframes: [.at(0, opacity: 0), .at(1, opacity: 1)])
        let animBoth = MotionAnimation(name: "b", duration: 2, delay: 0.5, fillMode: .both, keyframes: [.at(0, opacity: 0), .at(1, opacity: 1)])
        XCTAssertEqual(animNone.pose(at: 0.2, base: MotionPose(opacity: 0.7)).opacity, 0.7, accuracy: 1e-6)
        XCTAssertEqual(animBoth.pose(at: 0.2, base: MotionPose(opacity: 0.7)).opacity, 0.0, accuracy: 1e-6)

        // `--motion-ease` endpoints & monotonicity.
        XCTAssertEqual(MotionEasing.motionEase.apply(0), 0, accuracy: 1e-6)
        XCTAssertEqual(MotionEasing.motionEase.apply(1), 1, accuracy: 1e-6)
        XCTAssertGreaterThan(MotionEasing.motionEase.apply(0.25), 0.5)
    }
}
