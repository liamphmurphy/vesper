import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VesperCore

final class PersonaStateLoopsTests: XCTestCase {
    func testEachCharacterStateMapsToTheLoopTheServerStores() {
        XCTAssertEqual(PersonaStateLoops.loopState(for: .staticState), "idle")
        XCTAssertEqual(PersonaStateLoops.loopState(for: .working), "coding")
        XCTAssertEqual(PersonaStateLoops.loopState(for: .needsYou), "needs_you")
        XCTAssertEqual(PersonaStateLoops.loopState(for: .reading), "reading")
    }

    func testRevealByWordCountCarriesAcrossClips() {
        let text = "One two three four five."
        XCTAssertEqual(PersonaStateLoops.revealSlice(text, words: 2).text, "One two ")
        XCTAssertFalse(PersonaStateLoops.revealSlice(text, words: 2).done)
        XCTAssertEqual(PersonaStateLoops.revealSlice(text, words: -1).text, "")
        XCTAssertTrue(PersonaStateLoops.revealSlice(text, words: 5).done)
        // The timed form is the same count.
        XCTAssertEqual(PersonaStateLoops.revealSlice(text, elapsed: 1, wordsPerSecond: 3).text, PersonaStateLoops.revealSlice(text, words: 3).text)
    }

    func testFallbacksMatchTheWeb() {
        let some = ["idle": "/i", "thinking": "/t", "reading": "/r"]
        XCTAssertEqual(PersonaStateLoops.loop(for: .reading, in: some)?.url, "/r")
        XCTAssertEqual(PersonaStateLoops.loop(for: .coding, in: some)?.state, "thinking", "a work state borrows thinking")
        XCTAssertEqual(PersonaStateLoops.loop(for: .needsYou, in: some)?.state, "idle", "needs-you never borrows thinking")
        XCTAssertEqual(PersonaStateLoops.loop(for: .working, in: ["idle": "/i"])?.state, "idle")
        XCTAssertEqual(PersonaStateLoops.loop(for: .idle, in: ["creating": "/c"])?.state, "creating")
        XCTAssertNil(PersonaStateLoops.loop(for: .idle, in: [:]))
        XCTAssertFalse(PersonaStateLoops.hasLoops(["idle": ""]))
        XCTAssertTrue(PersonaStateLoops.hasLoops(["idle": "/i"]))
    }

    /// An animated image with frames of the given delays, as WebP when ImageIO can write it, else
    /// GIF (the decoder reads both the same way).
    private func animated(delays: [Double], side: Int) throws -> Data {
        let data = NSMutableData()
        let type = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.webP.identifier) ? UTType.webP : UTType.gif
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, delays.count, nil))
        let dictKey = type == .webP ? kCGImagePropertyWebPDictionary : kCGImagePropertyGIFDictionary
        let delayKey = type == .webP ? kCGImagePropertyWebPDelayTime : kCGImagePropertyGIFDelayTime
        let loopKey = type == .webP ? kCGImagePropertyWebPLoopCount : kCGImagePropertyGIFLoopCount
        CGImageDestinationSetProperties(dest, [dictKey: [loopKey: 0]] as CFDictionary)
        for (i, d) in delays.enumerated() {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: side, height: side * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: CGFloat(i) / CGFloat(delays.count), green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side * 2))
            CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [dictKey: [delayKey: d]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testDecodesEveryFrameDownsampledWithItsDelay() throws {
        let data = try animated(delays: [0.05, 0.1, 0.2], side: 200)
        let frames = try XCTUnwrap(AnimatedImageFrames.decode(data, maxPixelSize: 100))
        XCTAssertEqual(frames.frames.count, 3)
        XCTAssertEqual(frames.frames[0].height, 100, "the longer side is bounded")
        XCTAssertEqual(frames.frames[0].width, 50)
        XCTAssertEqual(frames.delays[0], 0.05, accuracy: 0.011)
        XCTAssertEqual(frames.delays[2], 0.2, accuracy: 0.011)
        XCTAssertEqual(frames.duration, 0.35, accuracy: 0.03)

        let still = try XCTUnwrap(AnimatedImageFrames.decode(data, maxPixelSize: 100, firstFrameOnly: true))
        XCTAssertEqual(still.frames.count, 1, "Reduce Motion decodes only frame 0")
        XCTAssertNil(AnimatedImageFrames.decode(Data("<svg/>".utf8), maxPixelSize: 100))
    }

    func testFrameIndexLoops() throws {
        let frames = try XCTUnwrap(AnimatedImageFrames.decode(try animated(delays: [0.1, 0.2, 0.1], side: 20), maxPixelSize: 40))
        let total = frames.duration
        XCTAssertEqual(frames.frameIndex(at: 0), 0)
        XCTAssertEqual(frames.frameIndex(at: frames.delays[0] + 0.01), 1)
        XCTAssertEqual(frames.frameIndex(at: total - 0.01), 2)
        XCTAssertEqual(frames.frameIndex(at: total + 0.01), 0, "wraps at the end of the loop")
    }

    func testRecommendedTickIntervalTracksFastestFrameWithinBounds() throws {
        let twelveFps = try XCTUnwrap(AnimatedImageFrames.decode(try animated(delays: [0.08, 0.12], side: 20), maxPixelSize: 40))
        XCTAssertEqual(twelveFps.recommendedTickInterval, twelveFps.delays.min()!, accuracy: 0.001)

        let veryFast = try XCTUnwrap(AnimatedImageFrames.decode(try animated(delays: [0.02, 0.02], side: 20), maxPixelSize: 40))
        XCTAssertEqual(veryFast.recommendedTickInterval, 1.0 / 30.0, accuracy: 1e-6, "capped at 30fps")

        let verySlow = try XCTUnwrap(AnimatedImageFrames.decode(try animated(delays: [0.5, 0.5], side: 20), maxPixelSize: 40))
        XCTAssertEqual(verySlow.recommendedTickInterval, 0.25, accuracy: 1e-6, "bounded at 4Hz minimum")
    }
}

final class PersonaRevealTests: XCTestCase {
    func testTalkingPlaysItsLoopElseIdleNeverThinking() {
        XCTAssertEqual(PersonaStateLoops.loop(for: .coding, talking: true, in: ["idle": "/i", "thinking": "/t", "talking": "/k"])?.state, "talking")
        XCTAssertEqual(PersonaStateLoops.loop(for: .coding, talking: true, in: ["idle": "/i", "thinking": "/t"])?.state, "idle")
    }

    func testAutoPacesOnlyAPersonaWithATalkingLoop() {
        XCTAssertEqual(PersonaStateLoops.revealWordsPerSecond(pace: "auto", loops: ["idle": "/i"]), 0)
        XCTAssertEqual(PersonaStateLoops.revealWordsPerSecond(pace: "auto", loops: ["talking": "/k"]), 15)
        XCTAssertEqual(PersonaStateLoops.revealWordsPerSecond(pace: nil, loops: nil), 0)
        XCTAssertEqual(PersonaStateLoops.revealWordsPerSecond(pace: "off", loops: ["talking": "/k"]), 0)
        XCTAssertEqual(PersonaStateLoops.revealWordsPerSecond(pace: "deliberate", loops: nil), 8)
    }

    func testRevealCutsAfterWholeWordsLikeTheWeb() {
        let text = "Hello there, general Kenobi."
        XCTAssertEqual(PersonaStateLoops.revealSlice(text, elapsed: 0, wordsPerSecond: 10).text, "")
        XCTAssertEqual(PersonaStateLoops.revealSlice(text, elapsed: 0.1, wordsPerSecond: 10).text, "Hello ")
        XCTAssertEqual(PersonaStateLoops.revealSlice(text, elapsed: 0.25, wordsPerSecond: 10).text, "Hello there, ")
        XCTAssertTrue(PersonaStateLoops.revealSlice(text, elapsed: 0.4, wordsPerSecond: 10).done)
        XCTAssertTrue(PersonaStateLoops.revealSlice(text, elapsed: 0, wordsPerSecond: 0).done)
    }
}

final class PersonaCompleteLoopTests: XCTestCase {
    func testCompletePlaysItsLoopElseIdleAndTalkingWins() {
        let loops = ["idle": "/i", "thinking": "/t", "complete": "/c", "talking": "/k"]
        XCTAssertEqual(PersonaStateLoops.loop(for: .idle, complete: true, in: loops)?.state, "complete")
        XCTAssertEqual(PersonaStateLoops.loop(for: .idle, complete: true, in: ["idle": "/i", "thinking": "/t"])?.state, "idle")
        XCTAssertEqual(PersonaStateLoops.loop(for: .idle, talking: true, complete: true, in: loops)?.state, "talking")
    }
}
