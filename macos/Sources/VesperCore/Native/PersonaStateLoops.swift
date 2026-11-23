import CoreGraphics
import Foundation
import ImageIO

/// Which photorealistic state loop to play (web lib/persona-state-media.ts). The server stores
/// one transparent Animated WebP per state; the app drives them from the same `CharacterState`
/// the SVG characters use.
public enum PersonaStateLoops {
    /// Loop states in display order, as the API names them.
    public static let states = ["idle", "thinking", "reading", "coding", "creating", "needs_you", "talking", "complete"]

    /// The loop a character state wants: static is the idle pose, and generic work is coding.
    public static func loopState(for state: CharacterState) -> String {
        switch state {
        case .staticState, .idle: "idle"
        case .working, .coding: "coding"
        case .thinking: "thinking"
        case .reading: "reading"
        case .creating: "creating"
        case .needsYou: "needs_you"
        }
    }

    /// The loop to play for a state: its own, else thinking for a work state without one, else
    /// idle, else whichever exists. Nil when there are no loops, so callers fall back to the
    /// persona's picture or character. needs_you never borrows thinking.
    public static func loop(for state: CharacterState, talking: Bool = false, complete: Bool = false, in loops: [String: String]) -> (state: String, url: String)? {
        // Talking (a reply revealing) wins over the turn's state, and complete (the beat after a
        // turn that did work) over idle; SVG characters have neither pose.
        let want = talking ? "talking" : complete ? "complete" : loopState(for: state)
        var order = [want]
        if !["idle", "needs_you", "thinking", "talking", "complete"].contains(want) { order.append("thinking") }
        order.append("idle")
        order.append(contentsOf: states)
        for s in order {
            if let url = loops[s], !url.isEmpty { return (s, url) }
        }
        return nil
    }

    /// Words a second a new reply is revealed at; 0 shows it at once. `auto` paces only a persona
    /// with a talking loop to play meanwhile (web revealWordsPerSecond).
    public static func revealWordsPerSecond(pace: String?, loops: [String: String]?) -> Double {
        switch pace ?? "auto" {
        case "off": 0
        case "relaxed": 25
        case "natural": 15
        case "deliberate": 8
        default: (loops?["talking"]).map { $0.isEmpty ? 0 : 15 } ?? 0
        }
    }

    /// The part of a reply shown `elapsed` seconds into its reveal, cut after whole words (and the
    /// whitespace after them) so text never stops mid-word; `done` once it's all shown.
    public static func revealSlice(_ text: String, elapsed: TimeInterval, wordsPerSecond: Double) -> (text: String, done: Bool) {
        guard wordsPerSecond > 0 else { return (text, true) }
        return revealSlice(text, words: Int((elapsed * wordsPerSecond).rounded(.down)))
    }

    /// The first `words` words of a reply, cut the same way: for a reveal paced by more than one
    /// clip, where the count carries over from one clip to the next.
    public static func revealSlice(_ text: String, words: Int) -> (text: String, done: Bool) {
        var words = max(0, words)
        var index = text.startIndex
        var inWord = false
        while index < text.endIndex {
            let space = text[index].isWhitespace
            if space && inWord {
                words -= 1
                inWord = false
                if words < 0 { break }
            } else if !space && !inWord {
                if words == 0 { break }
                inWord = true
            }
            index = text.index(after: index)
        }
        if index >= text.endIndex || text[index...].allSatisfy(\.isWhitespace) { return (text, true) }
        return (String(text[..<index]), false)
    }

    /// Whether a persona has any loop to play.
    public static func hasLoops(_ loops: [String: String]?) -> Bool {
        loops?.values.contains { !$0.isEmpty } ?? false
    }
}

/// The decoded frames of an animated image (Animated WebP, GIF or APNG), scaled down to the
/// size they're drawn at so a 4s loop doesn't hold full-size bitmaps.
public struct AnimatedImageFrames: @unchecked Sendable {
    public let frames: [CGImage]
    /// Each frame's display time in seconds, parallel to `frames`.
    public let delays: [Double]
    public let duration: Double

    /// Browsers treat delays this short as "as fast as possible" and slow them to 100 ms; match
    /// them so a loop plays at the same speed on the web and here.
    static let minimumDelay = 0.011
    static let clampedDelay = 0.1

    /// Decodes `data`, each frame at most `maxPixelSize` on its longer side; `firstFrameOnly`
    /// decodes just frame 0 (Reduce Motion). Nil when it isn't an image ImageIO can read.
    public static func decode(_ data: Data, maxPixelSize: Int, firstFrameOnly: Bool = false) -> AnimatedImageFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = firstFrameOnly ? min(1, CGImageSourceGetCount(source)) : CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = []
        var delays: [Double] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
            frames.append(image)
            delays.append(frameDelay(source, index: i))
        }
        guard !frames.isEmpty else { return nil }
        return AnimatedImageFrames(frames: frames, delays: delays, duration: delays.reduce(0, +))
    }

    /// Suggested periodic tick interval matching the loop's own frame cadence, bounded to
    /// [1/30s, 0.25s]. Drives a `.periodic` TimelineView instead of a 120Hz DisplayLink.
    public var recommendedTickInterval: Double {
        guard let fastest = delays.min(), fastest > 0 else { return 1.0 / 24.0 }
        return min(max(fastest, 1.0 / 30.0), 0.25)
    }

    /// The frame shown `elapsed` seconds into playback, looping.
    public func frameIndex(at elapsed: Double) -> Int {
        guard frames.count > 1, duration > 0 else { return 0 }
        var t = elapsed.truncatingRemainder(dividingBy: duration)
        if t < 0 { t += duration }
        for (i, d) in delays.enumerated() {
            if t < d { return i }
            t -= d
        }
        return frames.count - 1
    }

    static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return clampedDelay }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dictKey, unclamped, clamped) in dicts {
            guard let dict = props[dictKey] as? [CFString: Any] else { continue }
            let value = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double)
            if let value { return value < minimumDelay ? clampedDelay : value }
        }
        return clampedDelay
    }
}
