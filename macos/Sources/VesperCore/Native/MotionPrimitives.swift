import Foundation

/// Affine components of a CSS `transform` (`translate`, `rotate`, `scale`) before pivot application.
public struct MotionTransform: Sendable, Equatable {
    public var tx: Double
    public var ty: Double
    public var rot: Double
    public var sx: Double
    public var sy: Double

    public static let identity = MotionTransform()

    public init(tx: Double = 0, ty: Double = 0, rot: Double = 0, sx: Double = 1, sy: Double = 1) {
        self.tx = tx
        self.ty = ty
        self.rot = rot
        self.sx = sx
        self.sy = sy
    }

    public func mixed(with other: MotionTransform, _ f: Double) -> MotionTransform {
        MotionTransform(
            tx: tx + (other.tx - tx) * f,
            ty: ty + (other.ty - ty) * f,
            rot: rot + (other.rot - rot) * f,
            sx: sx + (other.sx - sx) * f,
            sy: sy + (other.sy - sy) * f
        )
    }
}

/// Full animated property state resolved for a scene node at a point in time.
public struct MotionPose: Sendable, Equatable {
    public var tx: Double
    public var ty: Double
    public var rot: Double
    public var sx: Double
    public var sy: Double
    public var opacity: Double
    public var dashOffset: Double
    public var blur: Double
    public var fillOverride: RGBA?

    public init(
        tx: Double = 0,
        ty: Double = 0,
        rot: Double = 0,
        sx: Double = 1,
        sy: Double = 1,
        opacity: Double = 1,
        dashOffset: Double = 0,
        blur: Double = 0,
        fillOverride: RGBA? = nil
    ) {
        self.tx = tx
        self.ty = ty
        self.rot = rot
        self.sx = sx
        self.sy = sy
        self.opacity = opacity
        self.dashOffset = dashOffset
        self.blur = blur
        self.fillOverride = fillOverride
    }

    public init(
        transform: MotionTransform,
        opacity: Double = 1,
        dashOffset: Double = 0,
        blur: Double = 0,
        fillOverride: RGBA? = nil
    ) {
        self.tx = transform.tx
        self.ty = transform.ty
        self.rot = transform.rot
        self.sx = transform.sx
        self.sy = transform.sy
        self.opacity = opacity
        self.dashOffset = dashOffset
        self.blur = blur
        self.fillOverride = fillOverride
    }

    public var transform: MotionTransform {
        MotionTransform(tx: tx, ty: ty, rot: rot, sx: sx, sy: sy)
    }
}

/// CSS animation timing functions used across `globals.css`.
public enum MotionEasing: Sendable, Equatable {
    case linear
    case ease
    case easeIn
    case easeOut
    case easeInOut
    case cubicBezier(Double, Double, Double, Double)
    case steps(Int)

    /// Matches `--motion-ease: cubic-bezier(0.16, 1, 0.3, 1)` in `globals.css`.
    public static let motionEase = MotionEasing.cubicBezier(0.16, 1, 0.3, 1)

    /// Normalized CSS timing function string for parity checks against `protocol/activity-scenes/fixtures.json`.
    public var cssName: String {
        switch self {
        case .linear: "linear"
        case .ease: "ease"
        case .easeIn: "ease-in"
        case .easeOut: "ease-out"
        case .easeInOut: "ease-in-out"
        case .cubicBezier(let x1, let y1, let x2, let y2):
            "cubic-bezier(\(Self.formatNumber(x1)), \(Self.formatNumber(y1)), \(Self.formatNumber(x2)), \(Self.formatNumber(y2)))"
        case .steps(let count):
            "steps(\(count))"
        }
    }

    private static func formatNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.6g", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    public func apply(_ rawX: Double) -> Double {
        let x = min(max(rawX, 0), 1)
        switch self {
        case .linear:
            return x
        case .ease:
            return Self.bezier(0.25, 0.1, 0.25, 1, x)
        case .easeIn:
            return Self.bezier(0.42, 0, 1, 1, x)
        case .easeOut:
            return Self.bezier(0, 0, 0.58, 1, x)
        case .easeInOut:
            return Self.bezier(0.42, 0, 0.58, 1, x)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return Self.bezier(x1, y1, x2, y2, x)
        case .steps(let count):
            guard count > 0 else { return x }
            if x >= 1 { return 1 }
            return floor(x * Double(count)) / Double(count)
        }
    }

    /// CSS `cubic-bezier(x1, y1, x2, y2)` solved for `y` at normalized time `x`.
    private static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func sample(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let inv = 1 - s
            return 3 * a * s * inv * inv + 3 * b * s * s * inv + s * s * s
        }
        var lo = 0.0
        var hi = 1.0
        var s = x
        for _ in 0..<24 {
            s = (lo + hi) * 0.5
            if sample(x1, x2, s) < x {
                lo = s
            } else {
                hi = s
            }
        }
        return sample(y1, y2, s)
    }
}

public enum MotionDirection: String, Sendable, Equatable {
    case normal
    case reverse
    case alternate
    case alternateReverse = "alternate-reverse"
}

public enum MotionFillMode: String, Sendable, Equatable {
    case none
    case forwards
    case backwards
    case both
}

/// One CSS keyframe stop (`0...1`) setting zero or more animated property channels.
public struct MotionKeyframe: Sendable, Equatable {
    public var offset: Double
    public var transform: MotionTransform?
    public var opacity: Double?
    public var dashOffset: Double?
    public var blur: Double?
    public var fill: SceneColorToken?

    public init(
        offset: Double,
        transform: MotionTransform? = nil,
        opacity: Double? = nil,
        dashOffset: Double? = nil,
        blur: Double? = nil,
        fill: SceneColorToken? = nil
    ) {
        self.offset = offset
        self.transform = transform
        self.opacity = opacity
        self.dashOffset = dashOffset
        self.blur = blur
        self.fill = fill
    }

    /// Builds a keyframe; specifying any transform component (or `identityTransform: true`) populates `transform`.
    public static func at(
        _ offset: Double,
        tx: Double? = nil,
        ty: Double? = nil,
        rot: Double? = nil,
        sx: Double? = nil,
        sy: Double? = nil,
        scale: Double? = nil,
        identityTransform: Bool = false,
        opacity: Double? = nil,
        dashOffset: Double? = nil,
        blur: Double? = nil,
        fill: SceneColorToken? = nil
    ) -> MotionKeyframe {
        let hasTransform = identityTransform || tx != nil || ty != nil || rot != nil || sx != nil || sy != nil || scale != nil
        let transform: MotionTransform? = hasTransform
            ? MotionTransform(
                tx: tx ?? 0,
                ty: ty ?? 0,
                rot: rot ?? 0,
                sx: scale ?? sx ?? 1,
                sy: scale ?? sy ?? 1
            )
            : nil
        return MotionKeyframe(
            offset: offset,
            transform: transform,
            opacity: opacity,
            dashOffset: dashOffset,
            blur: blur,
            fill: fill
        )
    }
}

/// A CSS `@keyframes` animation binding (`duration`, `delay`, `easing`, `direction`, `fillMode`, and stops).
public struct MotionAnimation: Sendable, Equatable {
    public var name: String
    public var duration: Double
    public var delay: Double
    public var easing: MotionEasing
    public var direction: MotionDirection
    public var fillMode: MotionFillMode
    public var keyframes: [MotionKeyframe]

    public init(
        name: String,
        duration: Double,
        delay: Double = 0,
        easing: MotionEasing = .ease,
        direction: MotionDirection = .normal,
        alternate: Bool = false,
        fillMode: MotionFillMode = .none,
        keyframes: [MotionKeyframe]
    ) {
        self.name = name
        self.duration = duration
        self.delay = delay
        self.easing = easing
        self.direction = alternate ? .alternate : direction
        self.fillMode = fillMode
        self.keyframes = keyframes.sorted { $0.offset < $1.offset }
    }

    public func delayed(by seconds: Double) -> MotionAnimation {
        var copy = self
        copy.delay = seconds
        return copy
    }

    public func withDuration(_ seconds: Double) -> MotionAnimation {
        var copy = self
        copy.duration = seconds
        return copy
    }

    /// Sorted unique keyframe stops in CSS percentage (`0...100`) for parity assertions.
    public var keyframeStopsPercent: [Double] {
        var seen: [Double] = []
        for k in keyframes {
            let pct = (k.offset * 100 * 1000).rounded() / 1000
            if !seen.contains(where: { abs($0 - pct) < 1e-6 }) {
                seen.append(pct)
            }
        }
        return seen.sorted()
    }

    /// Normalized `0...1` progress inside the keyframe timeline at virtual clock `t`, or `nil` when inactive during positive delay.
    public func phase(at t: Double) -> Double? {
        guard duration > 0 else { return 0 }
        let elapsed = t - delay
        if elapsed < 0 {
            switch fillMode {
            case .backwards, .both:
                return (direction == .reverse || direction == .alternateReverse) ? 1.0 : 0.0
            case .none, .forwards:
                return nil
            }
        }
        let cycles = elapsed / duration
        let cycleIndex = Int(floor(cycles))
        let frac = cycles - floor(cycles)
        switch direction {
        case .normal:
            return frac
        case .reverse:
            return 1 - frac
        case .alternate:
            return cycleIndex.isMultiple(of: 2) ? frac : (1 - frac)
        case .alternateReverse:
            return cycleIndex.isMultiple(of: 2) ? (1 - frac) : frac
        }
    }

    /// Evaluates the pose at virtual clock `t` using CSS per-property channel interpolation.
    public func pose(
        at t: Double,
        base: MotionPose = MotionPose(),
        baseFill: RGBA? = nil,
        palette: ActivityScenePalette? = nil
    ) -> MotionPose {
        guard let p = phase(at: t) else { return base }

        let transform = interpolateChannel(
            phase: p,
            base: base.transform,
            extract: { $0.transform },
            mix: { $0.mixed(with: $1, $2) }
        )
        let opacity = interpolateChannel(
            phase: p,
            base: base.opacity,
            extract: { $0.opacity },
            mix: { $0 + ($1 - $0) * $2 }
        )
        let dashOffset = interpolateChannel(
            phase: p,
            base: base.dashOffset,
            extract: { $0.dashOffset },
            mix: { $0 + ($1 - $0) * $2 }
        )
        let blur = interpolateChannel(
            phase: p,
            base: base.blur,
            extract: { $0.blur },
            mix: { $0 + ($1 - $0) * $2 }
        )
        let fillOverride: RGBA? = if let palette {
            interpolateChannel(
                phase: p,
                base: baseFill,
                extract: { $0.fill.map { palette.resolve($0) } },
                mix: { a, b, f in
                    guard let a, let b else { return f < 0.5 ? a : b }
                    return RGBA(
                        red: a.red + (b.red - a.red) * f,
                        green: a.green + (b.green - a.green) * f,
                        blue: a.blue + (b.blue - a.blue) * f,
                        alpha: a.alpha + (b.alpha - a.alpha) * f
                    )
                }
            )
        } else {
            baseFill
        }

        return MotionPose(
            transform: transform,
            opacity: opacity,
            dashOffset: dashOffset,
            blur: blur,
            fillOverride: fillOverride
        )
    }

    private func interpolateChannel<Value>(
        phase p: Double,
        base: Value,
        extract: (MotionKeyframe) -> Value?,
        mix: (Value, Value, Double) -> Value
    ) -> Value {
        var stops: [(Double, Value)] = []
        stops.reserveCapacity(keyframes.count + 2)
        for kf in keyframes {
            if let v = extract(kf) {
                if let last = stops.last, abs(last.0 - kf.offset) < 1e-9 {
                    stops[stops.count - 1] = (kf.offset, v)
                } else {
                    stops.append((kf.offset, v))
                }
            }
        }
        guard !stops.isEmpty else { return base }
        if stops[0].0 > 1e-9 {
            stops.insert((0, base), at: 0)
        }
        if stops[stops.count - 1].0 < 1 - 1e-9 {
            stops.append((1, base))
        }
        if p <= stops[0].0 { return stops[0].1 }
        if p >= stops[stops.count - 1].0 { return stops[stops.count - 1].1 }
        for i in 1..<stops.count {
            let a = stops[i - 1]
            let b = stops[i]
            if p <= b.0 || i == stops.count - 1 {
                let span = b.0 - a.0
                let raw = span > 0 ? (p - a.0) / span : 1
                let eased = easing.apply(min(max(raw, 0), 1))
                return mix(a.1, b.1, eased)
            }
        }
        return base
    }
}

/// Pure state machine matching `activity-scene.tsx`'s hold (`800ms`), crossfade (`240ms`),
/// and stop wind-down (`600ms`) timings.
public struct ActivitySceneTransitioner: Sendable, Equatable {
    /// Minimum time a scene stays visible before switching (`HOLD_MS = 800`).
    public static let holdDuration: Double = 0.8
    /// Crossfade duration between outgoing and incoming scenes (`FADE_MS = 240`).
    public static let fadeDuration: Double = 0.24
    /// Duration to coast virtual animation rate linearly to 0 when stopping (`WIND_DOWN_MS = 600`).
    public static let windDownDuration: Double = 0.6

    public private(set) var current: ActivitySceneKind
    public private(set) var previous: ActivitySceneKind?
    public private(set) var pending: ActivitySceneKind?
    public private(set) var shownAt: Double
    public private(set) var fadeStartedAt: Double?
    public private(set) var currentClock: Double
    public private(set) var previousClock: Double
    public private(set) var isStopping: Bool
    public private(set) var windDownStartedAt: Double?
    public private(set) var lastTickAt: Double

    public init(initial: ActivitySceneKind, at now: Double = 0) {
        self.current = initial
        self.previous = nil
        self.pending = nil
        self.shownAt = now
        self.fadeStartedAt = nil
        self.currentClock = 0
        self.previousClock = 0
        self.isStopping = false
        self.windDownStartedAt = nil
        self.lastTickAt = now
    }

    public mutating func request(_ kind: ActivitySceneKind, at now: Double) {
        advance(to: now)
        if kind == current {
            pending = nil
            return
        }
        if now - shownAt >= Self.holdDuration {
            commitTransition(to: kind, at: now)
        } else {
            pending = kind
        }
    }

    public mutating func setStopping(_ stopping: Bool, at now: Double) {
        advance(to: now)
        guard stopping != isStopping else { return }
        isStopping = stopping
        windDownStartedAt = stopping ? now : nil
    }

    public mutating func advance(to now: Double) {
        let clampedNow = max(lastTickAt, now)
        let virtualDelta = integratedVirtualDelta(from: lastTickAt, to: clampedNow)
        currentClock += virtualDelta
        if previous != nil {
            previousClock += virtualDelta
        }
        lastTickAt = clampedNow

        if let fadeStart = fadeStartedAt, clampedNow - fadeStart >= Self.fadeDuration {
            previous = nil
            fadeStartedAt = nil
        }

        if let nextKind = pending, clampedNow - shownAt >= Self.holdDuration {
            let transitionAt = shownAt + Self.holdDuration
            if nextKind == current {
                pending = nil
            } else {
                // Advance crossfade age accurately if `now` overshot the hold boundary.
                commitTransition(to: nextKind, at: transitionAt)
                if let fadeStart = fadeStartedAt, clampedNow - fadeStart >= Self.fadeDuration {
                    previous = nil
                    fadeStartedAt = nil
                }
            }
        }
    }

    /// Playback speed in `0...1` at wall time `now`.
    public func playbackRate(at now: Double) -> Double {
        guard isStopping, let start = windDownStartedAt else { return 1 }
        return max(0, 1 - max(0, now - start) / Self.windDownDuration)
    }

    /// Opacity `0...1` of the incoming `current` layer at wall time `now`.
    public func currentOpacity(at now: Double) -> Double {
        guard let fadeStart = fadeStartedAt else { return 1 }
        let p = min(max((now - fadeStart) / Self.fadeDuration, 0), 1)
        return MotionEasing.easeOut.apply(p)
    }

    /// Opacity `0...1` of the outgoing `previous` layer at wall time `now`.
    public func previousOpacity(at now: Double) -> Double {
        guard previous != nil, let fadeStart = fadeStartedAt else { return 0 }
        let p = min(max((now - fadeStart) / Self.fadeDuration, 0), 1)
        return 1 - MotionEasing.easeOut.apply(p)
    }

    private mutating func commitTransition(to nextKind: ActivitySceneKind, at transitionAt: Double) {
        previous = current
        previousClock = currentClock
        current = nextKind
        currentClock = max(0, lastTickAt - transitionAt)
        shownAt = transitionAt
        fadeStartedAt = transitionAt
        pending = nil
    }

    /// Exact integral of `playbackRate(u)` over `[a, b]` so wind-down is frame-rate independent.
    private func integratedVirtualDelta(from a: Double, to b: Double) -> Double {
        guard b > a else { return 0 }
        guard isStopping, let start = windDownStartedAt else { return b - a }
        let end = start + Self.windDownDuration
        if b <= start { return b - a }
        if a >= end { return 0 }
        let pre = max(0, start - a)
        let u0 = max(a, start)
        let u1 = min(b, end)
        let r0 = max(0, 1 - (u0 - start) / Self.windDownDuration)
        let r1 = max(0, 1 - (u1 - start) / Self.windDownDuration)
        let decel = 0.5 * (r0 + r1) * (u1 - u0)
        return pre + decel
    }
}
