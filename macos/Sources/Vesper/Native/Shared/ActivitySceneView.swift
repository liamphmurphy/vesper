import SwiftUI
import VesperCore

/// Native SwiftUI Canvas / CoreGraphics stage rendering any `ActivitySceneKind` with
/// 800ms hold, 240ms crossfade, 600ms wind-down on stop, and Reduce Motion freeze.
struct ActivitySceneView: View {
    let kind: ActivitySceneKind
    var stopping: Bool = false
    var width: CGFloat = 112
    var height: CGFloat = 54
    var showStageChrome: Bool = true

    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var box = TransitionerBox()
    @State private var holdTask: Task<Void, Never>?
    @State private var staticTick = 0

    var body: some View {
        let palette = ActivityScenePalette(theme: theme)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let _ = staticTick
            let now = timeline.date.timeIntervalSinceReferenceDate
            let frame = evaluatedFrame(at: now)

            Canvas { ctx, canvasSize in
                ctx.withCGContext { cg in
                    if !reduceMotion, let prev = frame.previous, frame.previousOpacity > 0.001 {
                        ActivitySceneRenderer.render(
                            prev,
                            at: frame.previousClock,
                            palette: palette,
                            reduceMotion: false,
                            opacity: frame.previousOpacity,
                            in: cg,
                            size: canvasSize
                        )
                    }
                    ActivitySceneRenderer.render(
                        frame.current,
                        at: frame.currentClock,
                        palette: palette,
                        reduceMotion: reduceMotion,
                        opacity: reduceMotion ? 1 : frame.currentOpacity,
                        in: cg,
                        size: canvasSize
                    )
                }
            }
        }
        .padding(.horizontal, showStageChrome ? 4 : 0)
        .padding(.vertical, showStageChrome ? 3 : 0)
        .frame(width: width, height: height)
        .background {
            if showStageChrome {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
            }
        }
        .overlay {
            if showStageChrome {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: showStageChrome ? 9 : 0))
        .opacity(stopping ? 0.5 : 1)
        .saturation(stopping ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: stopping)
        .accessibilityHidden(true)
        .onChange(of: kind) { _, newKind in
            let now = Date.timeIntervalSinceReferenceDate
            if box.transitioner == nil {
                box.transitioner = ActivitySceneTransitioner(initial: newKind, at: now)
            } else {
                box.transitioner?.request(newKind, at: now)
            }
            if reduceMotion { staticTick &+= 1 }
            scheduleHoldIfNeeded()
        }
        .onChange(of: stopping) { _, newStopping in
            let now = Date.timeIntervalSinceReferenceDate
            if box.transitioner == nil {
                box.transitioner = ActivitySceneTransitioner(initial: kind, at: now)
            }
            box.transitioner?.setStopping(newStopping, at: now)
        }
        .onChange(of: reduceMotion) { _, paused in
            if paused {
                scheduleHoldIfNeeded()
            } else {
                holdTask?.cancel()
                holdTask = nil
            }
        }
        .onDisappear {
            holdTask?.cancel()
            holdTask = nil
        }
    }

    private func evaluatedFrame(at now: Double) -> SceneFrame {
        if box.transitioner == nil {
            var initial = ActivitySceneTransitioner(initial: kind, at: now)
            if stopping { initial.setStopping(true, at: now) }
            box.transitioner = initial
        }
        box.transitioner?.advance(to: now)
        let tr = box.transitioner!
        return SceneFrame(
            current: tr.current,
            currentClock: tr.currentClock,
            currentOpacity: tr.currentOpacity(at: now),
            previous: tr.previous,
            previousClock: tr.previousClock,
            previousOpacity: tr.previousOpacity(at: now)
        )
    }

    private func scheduleHoldIfNeeded() {
        holdTask?.cancel()
        holdTask = nil
        guard reduceMotion, let tr = box.transitioner, tr.pending != nil else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let remaining = max(0, (tr.shownAt + ActivitySceneTransitioner.holdDuration) - now)
        holdTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            box.transitioner?.advance(to: Date.timeIntervalSinceReferenceDate)
            staticTick &+= 1
        }
    }

    private struct SceneFrame {
        var current: ActivitySceneKind
        var currentClock: Double
        var currentOpacity: Double
        var previous: ActivitySceneKind?
        var previousClock: Double
        var previousOpacity: Double
    }

    @MainActor
    private final class TransitionerBox {
        var transitioner: ActivitySceneTransitioner?
    }
}
