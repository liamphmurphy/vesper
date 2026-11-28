import Foundation

/// Decides when character and activity animations should tick and at what periodic cadence.
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

    /// Periodic tick interval for `HarnessCharacterView`. Using `.periodic` instead of `.animation`
    /// avoids attaching a 120Hz ProMotion DisplayLink just to throttle it down.
    public static func harnessTickInterval(working: Bool) -> TimeInterval {
        working ? (1.0 / 24.0) : (1.0 / 10.0)
    }

    /// Nominal target frame interval for `ActivitySceneView` (60 fps normally, 30 fps in Low Power Mode).
    public static func activitySceneTickInterval(lowPowerMode: Bool = false) -> TimeInterval {
        lowPowerMode ? (1.0 / 30.0) : (1.0 / 60.0)
    }

    /// Default nominal frame interval for `ActivitySceneView` (60 fps).
    public static let activitySceneTickInterval: TimeInterval = 1.0 / 60.0

    /// Display-link `minimumInterval` for `TimelineView(.animation(minimumInterval:))` in `ActivitySceneView`.
    ///
    /// Subtracting a 10% VSync jitter margin (15ms for 60fps, 30ms for 30fps) keeps display-synced ticks
    /// locked to every VSync on 60Hz panels and every 2nd/4th VSync on 120Hz ProMotion panels instead of
    /// dropping to 30/40fps when a refresh arrives a fraction of a millisecond early.
    public static func activitySceneDisplayLinkMinimumInterval(lowPowerMode: Bool = false) -> TimeInterval {
        activitySceneTickInterval(lowPowerMode: lowPowerMode) * 0.9
    }

    /// Whether an animation should tick in the given visibility and power context.
    public static func shouldAnimate(working: Bool, context: Context) -> Bool {
        guard !context.reduceMotion, context.windowVisible else { return false }
        if working { return true }
        return context.appActive && !context.lowPowerMode
    }
}
