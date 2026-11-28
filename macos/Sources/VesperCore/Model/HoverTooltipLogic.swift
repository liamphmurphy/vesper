import Foundation

/// Screen-coordinate geometry primitives for pure tooltip placement math in `VesperCore`.
/// Uses macOS screen coordinates where `minY` is the bottom edge and `maxY` is the top edge.
public struct TooltipPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TooltipSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct TooltipRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var midX: Double { x + width / 2 }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var midY: Double { y + height / 2 }
    public var maxY: Double { y + height }
}

public enum TooltipPlacement: Sendable, Equatable {
    /// Centered below the anchor (flipping above near the bottom edge).
    case below
    /// To the leading (left) side of the anchor, vertically centered (for the trailing right rail).
    case leading
}

/// Pure positioning and hover-delay policy for floating AppKit hover tooltips.
public enum HoverTooltipLogic: Sendable {
    /// Delay before showing the first tooltip from a cold hover.
    public static let coldDelayMs = 240
    /// Short delay when moving between icons while a tooltip is already visible or just dismissed.
    public static let warmDelayMs = 60
    /// Grace window after a tooltip dismisses during which the next hover uses `warmDelayMs`.
    public static let warmWindowMs = 350

    public static func delayMs(isCurrentlyVisible: Bool, elapsedSinceDismissMs: Int?) -> Int {
        if isCurrentlyVisible {
            return warmDelayMs
        }
        if let elapsed = elapsedSinceDismissMs, elapsed >= 0, elapsed <= warmWindowMs {
            return warmDelayMs
        }
        return coldDelayMs
    }

    /// Places a tooltip relative to `anchor` in bottom-up screen coordinates, clamping cleanly to
    /// `visibleFrame` and flipping to the opposite side when the preferred side runs out of space.
    public static func origin(
        anchor: TooltipRect,
        tooltipSize: TooltipSize,
        visibleFrame: TooltipRect,
        gap: Double = 6,
        edgePadding: Double = 6,
        placement: TooltipPlacement = .below
    ) -> TooltipPoint {
        let minAllowedX = visibleFrame.minX + edgePadding
        let maxAllowedX = visibleFrame.maxX - edgePadding - tooltipSize.width
        let minAllowedY = visibleFrame.minY + edgePadding
        let maxAllowedY = visibleFrame.maxY - edgePadding - tooltipSize.height

        switch placement {
        case .below:
            let centeredX = anchor.midX - tooltipSize.width / 2
            let clampedX: Double
            if maxAllowedX < minAllowedX {
                clampedX = minAllowedX
            } else {
                clampedX = min(max(centeredX, minAllowedX), maxAllowedX)
            }

            let belowY = anchor.minY - gap - tooltipSize.height
            let chosenY: Double
            if belowY >= minAllowedY {
                chosenY = belowY
            } else {
                let aboveY = anchor.maxY + gap
                if maxAllowedY < minAllowedY {
                    chosenY = minAllowedY
                } else {
                    chosenY = min(max(aboveY, minAllowedY), maxAllowedY)
                }
            }
            return TooltipPoint(x: clampedX.rounded(), y: chosenY.rounded())

        case .leading:
            let leadingX = anchor.minX - gap - tooltipSize.width
            let chosenX: Double
            if leadingX >= minAllowedX {
                chosenX = leadingX
            } else {
                let trailingX = anchor.maxX + gap
                if maxAllowedX < minAllowedX {
                    chosenX = minAllowedX
                } else {
                    chosenX = min(max(trailingX, minAllowedX), maxAllowedX)
                }
            }

            let centeredY = anchor.midY - tooltipSize.height / 2
            let clampedY: Double
            if maxAllowedY < minAllowedY {
                clampedY = minAllowedY
            } else {
                clampedY = min(max(centeredY, minAllowedY), maxAllowedY)
            }
            return TooltipPoint(x: chosenX.rounded(), y: clampedY.rounded())
        }
    }
}
