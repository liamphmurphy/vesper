import QuartzCore
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
    /// Set `fillWidth: true` when an enclosing layout proposes the stage's exact width so both
    /// side-by-side columns and stacked narrow banners fill edge-to-edge.
    case diorama(tint: Color, ambientPulse: Bool = true, fillWidth: Bool = false)
}

/// Native `CADisplayLink` + CoreGraphics stage rendering any `ActivitySceneKind` with
/// 800ms hold, 240ms crossfade + scale settle, 600ms wind-down on stop, 120Hz ProMotion cadence
/// (30Hz in Low Power Mode, adapting automatically to 60Hz panels), and Reduce Motion freeze.
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
        let frameRate = AnimationPolicy.displayLinkFrameRate(working: true, lowPowerMode: power.isLowPowerMode)

        Group {
            switch resolvedStageStyle {
            case .boxed:
                sceneCanvas(animate: animate, frameRate: frameRate, palette: palette)
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
                sceneCanvas(animate: animate, frameRate: frameRate, palette: palette)
                    .frame(width: width, height: height)

            case .diorama(let tint, let ambientPulse, let fillWidth):
                dioramaStage(
                    tint: tint,
                    ambientPulse: ambientPulse,
                    fillWidth: fillWidth,
                    animate: animate,
                    frameRate: frameRate,
                    palette: palette
                )
            }
        }
        .opacity(stopping ? 0.55 : 1)
        .saturation(stopping ? 0.15 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: stopping)
        .accessibilityHidden(true)
        .onChange(of: kind) { _, newKind in
            let now = CACurrentMediaTime()
            if box.transitioner == nil {
                box.transitioner = ActivitySceneTransitioner(initial: newKind, at: now)
            } else {
                box.transitioner?.request(newKind, at: now)
            }
            if reduceMotion || !animate { staticTick &+= 1 }
            scheduleHoldIfNeeded()
        }
        .onChange(of: stopping) { _, newStopping in
            let now = CACurrentMediaTime()
            if box.transitioner == nil {
                box.transitioner = ActivitySceneTransitioner(initial: kind, at: now)
            }
            box.transitioner?.setStopping(newStopping, at: now)
            if !animate { staticTick &+= 1 }
        }
        .onChange(of: reduceMotion) { _, paused in
            if paused {
                staticTick &+= 1
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

    /// Static diorama layers (sunken fill, batched architectural dot grid, GPU-composited ambient
    /// bloom, top hairline) stay independent of the foreground `CADisplayLink` scene canvas.
    private func dioramaStage(
        tint: Color,
        ambientPulse: Bool,
        fillWidth: Bool,
        animate: Bool,
        frameRate: AnimationPolicy.FrameRateProfile,
        palette: ActivityScenePalette
    ) -> some View {
        let isDark = theme.mode == .dark
        let pulseBloom = animate && ambientPulse && !reduceMotion && !stopping
        return ZStack {
            theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)

            DioramaDotGridView(isDark: isDark)
                .equatable()

            DioramaAmbientBloomView(tint: tint, isDark: isDark, pulsing: pulseBloom)

            sceneCanvas(animate: animate, frameRate: frameRate, palette: palette)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(
            minWidth: fillWidth ? 0 : width,
            maxWidth: fillWidth ? .infinity : width,
            minHeight: fillWidth ? 0 : height,
            maxHeight: .infinity
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(isDark ? 0.06 : 0.5))
                .frame(height: 1)
        }
    }

    private func sceneCanvas(
        animate: Bool,
        frameRate: AnimationPolicy.FrameRateProfile,
        palette: ActivityScenePalette
    ) -> some View {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(stopping)
        hasher.combine(reduceMotion)
        hasher.combine(theme.mode)
        hasher.combine(staticTick)
        let redrawToken = hasher.finalize()
        let transitionerBox = box
        let initialKind = kind
        let initialStopping = stopping
        let isReduceMotion = reduceMotion

        return DisplayLinkCanvasView(
            isAnimating: animate,
            frameRateProfile: frameRate,
            redrawToken: redrawToken
        ) { cg, canvasSize, timestamp in
            let frame = Self.evaluatedFrame(
                in: transitionerBox,
                kind: initialKind,
                stopping: initialStopping,
                at: timestamp
            )
            if !isReduceMotion, let prev = frame.previous, frame.previousOpacity > 0.001 {
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
                reduceMotion: isReduceMotion,
                opacity: isReduceMotion ? 1 : frame.currentOpacity,
                contentScale: isReduceMotion ? 1 : frame.currentScale,
                in: cg,
                size: canvasSize
            )
        }
    }

    private static func evaluatedFrame(
        in box: TransitionerBox,
        kind: ActivitySceneKind,
        stopping: Bool,
        at now: Double
    ) -> SceneFrame {
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
        let now = CACurrentMediaTime()
        let remaining = max(0, (tr.shownAt + ActivitySceneTransitioner.holdDuration) - now)
        holdTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            box.transitioner?.advance(to: CACurrentMediaTime())
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

/// Batched single-path architectural dot grid that skips redraws across 1s timer ticks.
private struct DioramaDotGridView: View, Equatable {
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 10
            let dotColor = (isDark ? Color.white : Color.black).opacity(isDark ? 0.045 : 0.04)
            let cols = Int(size.width / step)
            let rows = Int(size.height / step)
            let offsetX = (size.width - CGFloat(cols) * step) * 0.5
            let offsetY = (size.height - CGFloat(rows) * step) * 0.5
            var dots = Path()
            for row in 0...rows {
                let y = offsetY + CGFloat(row) * step - 0.5
                for col in 0...cols {
                    let x = offsetX + CGFloat(col) * step - 0.5
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            ctx.fill(dots, with: .color(dotColor))
        }
    }
}

/// GPU-composited elliptical ambient bloom animated via Core Animation opacity.
private struct DioramaAmbientBloomView: View {
    let tint: Color
    let isDark: Bool
    let pulsing: Bool

    @State private var atPeak = false

    var body: some View {
        let peak = isDark ? 0.26 : 0.16
        let minFactor: Double = isDark ? (0.18 / 0.26) : (0.11 / 0.16)
        let restingFactor: Double = isDark ? (0.208 / 0.26) : (0.1275 / 0.16)
        let opacity = pulsing ? (atPeak ? 1.0 : minFactor) : restingFactor

        EllipticalGradient(
            colors: [
                tint.opacity(peak),
                tint.opacity(peak * 0.32),
                .clear,
            ],
            center: .center,
            startRadiusFraction: 0.02,
            endRadiusFraction: 0.72
        )
        .opacity(opacity)
        .animation(
            pulsing ? .easeInOut(duration: 2.15).repeatForever(autoreverses: true) : .default,
            value: atPeak
        )
        .onAppear {
            if pulsing { atPeak = true }
        }
        .onChange(of: pulsing) { _, active in
            atPeak = active
        }
    }
}
