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
    public var maxY: Double { y + height }
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

    /// Places a tooltip centered below `anchor` in bottom-up screen coordinates, clamping horizontally
    /// to `visibleFrame` and flipping above `anchor` when there isn't enough room below.
    public static func origin(
        anchor: TooltipRect,
        tooltipSize: TooltipSize,
        visibleFrame: TooltipRect,
        gap: Double = 6,
        edgePadding: Double = 6
    ) -> TooltipPoint {
        let minAllowedX = visibleFrame.minX + edgePadding
        let maxAllowedX = visibleFrame.maxX - edgePadding - tooltipSize.width
        let centeredX = anchor.midX - tooltipSize.width / 2
        let clampedX: Double
        if maxAllowedX < minAllowedX {
            clampedX = minAllowedX
        } else {
            clampedX = min(max(centeredX, minAllowedX), maxAllowedX)
        }

        let minAllowedY = visibleFrame.minY + edgePadding
        let maxAllowedY = visibleFrame.maxY - edgePadding - tooltipSize.height
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
    }
}
