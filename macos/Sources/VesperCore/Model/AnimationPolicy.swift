import Foundation

/// Decides when character and activity animations should tick and what display-link refresh rate
/// range they should request from macOS ProMotion / VRR displays.
///
/// Active/working animations stay live whenever the window is visible (even side-by-side behind
/// another focused app). Idle animations pause when the host view is hidden or occluded, when
/// Vesper is in the background, or when macOS Low Power Mode is on.
public enum AnimationPolicy {
    /// Visibility and power conditions that govern whether character and activity animations tick.
    public struct Context: Equatable, Sendable {
        public var reduceMotion: Bool
        public var windowVisible: Bool
        public var appActive: Bool
        public var lowPowerMode: Bool

        public init(
            reduceMotion: Bool = false,
            windowVisible: Bool = true,
            appActive: Bool = true,
            lowPowerMode: Bool = false
        ) {
            self.reduceMotion = reduceMotion
            self.windowVisible = windowVisible
            self.appActive = appActive
            self.lowPowerMode = lowPowerMode
        }
    }

    /// Pure-Swift mirror of `CAFrameRateRange` (in frames per second) so refresh-rate policy
    /// stays unit-testable inside `VesperCore` without QuartzCore/AppKit dependencies.
    public struct FrameRateProfile: Equatable, Sendable {
        public var minimum: Float
        public var maximum: Float
        public var preferred: Float

        public init(minimum: Float, maximum: Float, preferred: Float) {
            self.minimum = minimum
            self.maximum = maximum
            self.preferred = preferred
        }

        /// Clamps this profile to the hardware refresh rate of the screen hosting the window
        /// (e.g. 60 Hz external monitor vs 120 Hz ProMotion panel) while preserving valid bounds.
        public func clamped(toScreenMaxFPS screenMaxFPS: Int) -> FrameRateProfile {
            let cap = Float(max(screenMaxFPS, 30))
            let clampedMax = min(maximum, cap)
            let clampedMin = min(minimum, clampedMax)
            let clampedPreferred = min(max(preferred, clampedMin), clampedMax)
            return FrameRateProfile(
                minimum: clampedMin,
                maximum: clampedMax,
                preferred: clampedPreferred
            )
        }
    }

    /// Target `CADisplayLink` frame-rate profile for continuous vector canvases (`ActivitySceneView`,
    /// `HarnessCharacterView`, `PersonaCharacterView`).
    ///
    /// - Normal power, working: requests 80–120 Hz (preferred 120 Hz) so ProMotion ramps cleanly to
    ///   120 Hz and resists VRR step-downs on small canvases while still clamping to 60 Hz on 60 Hz panels.
    /// - Normal power, idle (foreground & visible): requests 60–120 Hz (preferred 120 Hz) for smooth
    ///   ambient motion alongside 120 Hz UI transitions, pausing completely when hidden/backgrounded.
    /// - Low Power Mode: caps to 30–60 Hz (preferred 30 Hz) to preserve battery.
    public static func displayLinkFrameRate(working: Bool, lowPowerMode: Bool = false) -> FrameRateProfile {
        if lowPowerMode {
            return FrameRateProfile(minimum: 30, maximum: 60, preferred: 30)
        }
        if working {
            return FrameRateProfile(minimum: 80, maximum: 120, preferred: 120)
        }
        return FrameRateProfile(minimum: 60, maximum: 120, preferred: 120)
    }

    /// Target `CADisplayLink` frame-rate profile for authored frame-based loops (Animated WebP/GIF)
    /// whose native cadence is slower than 120 Hz, keeping frame swaps phase-locked to VSync
    /// without beat judder or wasted intermediate wakeups.
    public static func displayLinkFrameRate(forTargetFPS targetFPS: Double, lowPowerMode: Bool = false) -> FrameRateProfile {
        let cap: Float = lowPowerMode ? 30 : 60
        let preferred = min(max(Float(targetFPS.rounded()), 15), cap)
        let minimum = min(preferred, 15)
        return FrameRateProfile(minimum: minimum, maximum: cap, preferred: preferred)
    }

    /// Whether an animation should tick in the given visibility and power context.
    public static func shouldAnimate(working: Bool, context: Context) -> Bool {
        guard !context.reduceMotion, context.windowVisible else { return false }
        if working { return true }
        return context.appActive && !context.lowPowerMode
    }
}
