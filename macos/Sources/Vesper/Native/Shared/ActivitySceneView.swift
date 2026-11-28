import SwiftUI
import VesperCore

/// Visual framing mode for `ActivitySceneView`.
enum ActivitySceneStageStyle: Equatable {
    /// Standalone bordered pill/card stage (used in the debug showcase).
    case boxed
    /// Borderless scene canvas without background chrome.
    case bare
    /// Flush full-height lit mini-diorama stage embedded inside a live activity card:
    /// subtle architectural dot grid, radial ambient bloom tinted by `tint`, and top specular hairline.
    case diorama(tint: Color, ambientPulse: Bool = true)
}

/// Native SwiftUI Canvas / CoreGraphics stage rendering any `ActivitySceneKind` with
/// 800ms hold, 240ms crossfade + scale settle, 600ms wind-down on stop, 60fps active cadence
/// (30fps in Low Power Mode), and Reduce Motion freeze.
struct ActivitySceneView: View {
    let kind: ActivitySceneKind
    var stopping: Bool = false
    var width: CGFloat = 112
    var height: CGFloat = 54
    var showStageChrome: Bool = true
    var stageStyle: ActivitySceneStageStyle? = nil

    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowVisible) private var windowVisible

    @State private var box = TransitionerBox()
    @State private var holdTask: Task<Void, Never>?
    @State private var staticTick = 0
    @State private var start = Date()

    private var resolvedStageStyle: ActivitySceneStageStyle {
        stageStyle ?? (showStageChrome ? .boxed : .bare)
    }

    var body: some View {
        let palette = ActivityScenePalette(theme: theme)
        let power = AppPowerState.shared
        let animate = AnimationPolicy.shouldAnimate(
            working: true,
            context: power.animationContext(
                reduceMotion: reduceMotion,
                windowVisible: windowVisible
            )
        )
        let tickInterval = AnimationPolicy.activitySceneTickInterval(lowPowerMode: power.isLowPowerMode)

        Group {
            if animate {
                TimelineView(.periodic(from: start, by: tickInterval)) { timeline in
                    let _ = staticTick
                    stagedScene(at: timeline.date.timeIntervalSinceReferenceDate, palette: palette)
                }
            } else {
                let _ = staticTick
                stagedScene(at: Date.timeIntervalSinceReferenceDate, palette: palette)
            }
        }
        .opacity(stopping ? 0.55 : 1)
        .saturation(stopping ? 0.15 : 1)
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

    @ViewBuilder
    private func stagedScene(at now: Double, palette: ActivityScenePalette) -> some View {
        switch resolvedStageStyle {
        case .boxed:
            sceneCanvas(at: now, palette: palette)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))

        case .bare:
            sceneCanvas(at: now, palette: palette)
                .frame(width: width, height: height)

        case .diorama(let tint, let ambientPulse):
            let isDark = theme.mode == .dark
            let pulseWave: Double = (ambientPulse && !reduceMotion && !stopping)
                ? (0.5 + 0.5 * sin(now * 1.45))
                : 0.35
            let bloomPeak = (isDark ? 0.18 : 0.11) + (isDark ? 0.08 : 0.05) * pulseWave

            ZStack {
                theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)

                // Architectural micro dot-grid backdrop
                Canvas { ctx, size in
                    let step: CGFloat = 10
                    let dotColor = (isDark ? Color.white : Color.black).opacity(isDark ? 0.045 : 0.04)
                    let cols = Int(size.width / step)
                    let rows = Int(size.height / step)
                    let offsetX = (size.width - CGFloat(cols) * step) * 0.5
                    let offsetY = (size.height - CGFloat(rows) * step) * 0.5
                    for row in 0...rows {
                        for col in 0...cols {
                            let x = offsetX + CGFloat(col) * step
                            let y = offsetY + CGFloat(row) * step
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(dotColor))
                        }
                    }
                }

                // Soft semantic / persona radial ambient bloom
                RadialGradient(
                    colors: [
                        tint.opacity(bloomPeak),
                        tint.opacity(bloomPeak * 0.32),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: max(width, height) * 0.72
                )

                sceneCanvas(at: now, palette: palette)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .frame(width: width)
            .frame(minHeight: height, maxHeight: .infinity)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(isDark ? 0.06 : 0.5))
                    .frame(height: 1)
            }
        }
    }

    private func sceneCanvas(at now: Double, palette: ActivityScenePalette) -> some View {
        let frame = evaluatedFrame(at: now)
        return Canvas { ctx, canvasSize in
            ctx.withCGContext { cg in
                if !reduceMotion, let prev = frame.previous, frame.previousOpacity > 0.001 {
                    ActivitySceneRenderer.render(
                        prev,
                        at: frame.previousClock,
                        palette: palette,
                        reduceMotion: false,
                        opacity: frame.previousOpacity,
                        contentScale: frame.previousScale,
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
                    contentScale: reduceMotion ? 1 : frame.currentScale,
                    in: cg,
                    size: canvasSize
                )
            }
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
            currentScale: tr.currentScale(at: now),
            previous: tr.previous,
            previousClock: tr.previousClock,
            previousOpacity: tr.previousOpacity(at: now),
            previousScale: tr.previousScale(at: now)
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
        var currentScale: Double
        var previous: ActivitySceneKind?
        var previousClock: Double
        var previousOpacity: Double
        var previousScale: Double
    }

    @MainActor
    private final class TransitionerBox {
        var transitioner: ActivitySceneTransitioner?
    }
}
