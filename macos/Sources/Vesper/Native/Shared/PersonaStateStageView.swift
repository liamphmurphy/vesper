import AppKit
import QuartzCore
import SwiftUI
import VesperCore

/// A persona's photorealistic state loop on a transparent background (web PersonaStateStage),
/// sized by width at the loops' 9:16. A new state decodes its loop first, then crossfades over
/// the old one so the switch never flashes empty. With Reduce Motion it shows the idle loop's
/// first frame, still.
struct PersonaStateStageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.vesperWindowVisible) private var windowVisible
    let loops: [String: String]
    let state: CharacterState
    /// A reply is revealing: play the talking loop over the turn's state.
    var talking = false
    /// The brief pleased beat after a turn that did work delivers its reply.
    var complete = false
    let width: CGFloat
    /// Accessible name, e.g. "Iris, thinking"; decorative without one.
    var label: String?

    @State private var shown: (url: String, frames: AnimatedImageFrames)?

    private static let fade = 0.22

    var body: some View {
        let height = (width * 16 / 9).rounded()
        let target = PersonaStateLoops.loop(for: reduceMotion ? .idle : state, talking: talking && !reduceMotion, complete: complete && !reduceMotion, in: loops)
        let pixels = Int((height * displayScale).rounded(.up))
        let isActiveState = (state != .idle && state != .staticState) || talking || complete
        let power = AppPowerState.shared
        let animate = AnimationPolicy.shouldAnimate(
            working: isActiveState,
            context: power.animationContext(
                reduceMotion: reduceMotion,
                windowVisible: windowVisible
            )
        )
        ZStack {
            if let shown {
                LoopPlayer(
                    frames: shown.frames,
                    animate: animate,
                    lowPowerMode: power.isLowPowerMode
                )
                .id(shown.url)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
        .task(id: "\(target?.url ?? "")|\(pixels)|\(reduceMotion)") {
            guard let target else {
                shown = nil
                return
            }
            guard let frames = await PersonaLoopFrames.shared.frames(for: target.url, maxPixelSize: pixels, firstFrameOnly: reduceMotion),
                  !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.fade)) { shown = (target.url, frames) }
        }
    }
}

/// Plays decoded frames phase-locked to VSync via `CADisplayLink`, only redrawing when `frameIndex`
/// advances. Paused or single-frame loops run zero display links.
private struct LoopPlayer: View {
    let frames: AnimatedImageFrames
    let animate: Bool
    let lowPowerMode: Bool
    @State private var clock = LoopClock()

    var body: some View {
        let shouldAnimate = animate && frames.frames.count >= 2
        let nativeFPS = frames.recommendedTickInterval > 0 ? (1.0 / frames.recommendedTickInterval) : 24.0
        let profile = AnimationPolicy.displayLinkFrameRate(forTargetFPS: nativeFPS, lowPowerMode: lowPowerMode)
        let loopFrames = frames
        let loopClock = clock

        DisplayLinkCanvasView(
            isAnimating: shouldAnimate,
            frameRateProfile: profile,
            redrawToken: shouldAnimate ? 1 : 0,
            shouldDraw: { timestamp in
                let idx = loopFrames.frameIndex(at: max(0, timestamp - loopClock.start))
                if idx == loopClock.lastDrawnIndex {
                    return false
                }
                loopClock.lastDrawnIndex = idx
                return true
            }
        ) { cg, size, timestamp in
            let idx = shouldAnimate ? loopFrames.frameIndex(at: max(0, timestamp - loopClock.start)) : 0
            loopClock.lastDrawnIndex = idx
            guard loopFrames.frames.indices.contains(idx) else { return }
            Self.drawAspectFit(loopFrames.frames[idx], in: cg, boundsSize: size)
        }
    }

    /// Draws `image` aspect-fit centered inside a Y-down `CGContext` (flipping locally because
    /// `CGContext.draw(_:in:)` renders bitmaps in Y-up coordinates).
    private static func drawAspectFit(_ image: CGImage, in cg: CGContext, boundsSize: CGSize) {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0, boundsSize.width > 0, boundsSize.height > 0 else { return }
        let scale = min(boundsSize.width / imgW, boundsSize.height / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let dx = (boundsSize.width - drawW) * 0.5
        let dy = (boundsSize.height - drawH) * 0.5

        cg.saveGState()
        cg.interpolationQuality = .medium
        cg.translateBy(x: dx, y: dy + drawH)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
        cg.restoreGState()
    }

    @MainActor
    private final class LoopClock {
        let start: CFTimeInterval = CACurrentMediaTime()
        var lastDrawnIndex: Int = -1
    }
}

/// Decoded loops, a few at a time: each is tens of megabytes of frames, and only the loop on
/// screen and the one fading out need to stay. Loads join, so two stages of the same persona
/// decode once.
@MainActor
final class PersonaLoopFrames {
    static let shared = PersonaLoopFrames()
    private static let capacity = 3

    private var cache: [String: AnimatedImageFrames] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<AnimatedImageFrames?, Never>] = [:]

    func frames(for url: String, maxPixelSize: Int, firstFrameOnly: Bool) async -> AnimatedImageFrames? {
        let key = "\(url)|\(maxPixelSize)|\(firstFrameOnly)"
        if let hit = cache[key] {
            touch(key)
            return hit
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<AnimatedImageFrames?, Never> {
            guard let data = await AvatarImages.shared.loopData(for: url) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                AnimatedImageFrames.decode(data, maxPixelSize: maxPixelSize, firstFrameOnly: firstFrameOnly)
            }.value
        }
        inFlight[key] = task
        let frames = await task.value
        inFlight[key] = nil
        if let frames {
            cache[key] = frames
            touch(key)
        }
        return frames
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.capacity {
            cache[order.removeFirst()] = nil
        }
    }
}

extension API.Persona {
    /// Its state loops by state, or nil when disabled or it has none to play.
    var playableLoops: [String: String]? {
        guard stateMediaEnabled, let loops = stateMedia?.loops, PersonaStateLoops.hasLoops(loops) else { return nil }
        return loops
    }
}
