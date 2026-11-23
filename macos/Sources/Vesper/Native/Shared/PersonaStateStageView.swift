import AppKit
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
        let animate = AnimationPolicy.shouldAnimate(
            working: isActiveState,
            context: AppPowerState.shared.animationContext(
                reduceMotion: reduceMotion,
                windowVisible: windowVisible
            )
        )
        ZStack {
            if let shown {
                LoopPlayer(frames: shown.frames, animate: animate)
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

/// Plays decoded frames on a periodic timer matching the loop's own frame delay; paused/single-frame
/// loops mount no `TimelineView` at all so zero wakeups occur while occluded or backgrounded.
private struct LoopPlayer: View {
    let frames: AnimatedImageFrames
    let animate: Bool
    @State private var start = Date()

    var body: some View {
        if !animate || frames.frames.count < 2 {
            frame(0)
        } else {
            TimelineView(.periodic(from: start, by: frames.recommendedTickInterval)) { ctx in
                frame(frames.frameIndex(at: ctx.date.timeIntervalSince(start)))
            }
        }
    }

    private func frame(_ i: Int) -> some View {
        Image(decorative: frames.frames[i], scale: 1)
            .resizable()
            .interpolation(.medium)
            .scaledToFit()
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
