import Testing
import VesperCore

@Suite("HoverTooltipLogic")
struct HoverTooltipLogicTests {
    private let screen = TooltipRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("centers tooltip below anchor when within screen bounds")
    func centersBelowAnchor() {
        let anchor = TooltipRect(x: 100, y: 800, width: 22, height: 22)
        let origin = HoverTooltipLogic.origin(
            anchor: anchor,
            tooltipSize: TooltipSize(width: 100, height: 24),
            visibleFrame: screen
        )
        #expect(origin == TooltipPoint(x: 61, y: 770))
    }

    @Test("clamps horizontally to left and right edges of visible frame")
    func clampsHorizontally() {
        let nearLeft = TooltipRect(x: 4, y: 800, width: 22, height: 22)
        let leftOrigin = HoverTooltipLogic.origin(
            anchor: nearLeft,
            tooltipSize: TooltipSize(width: 140, height: 24),
            visibleFrame: screen
        )
        #expect(leftOrigin.x == 6)

        let nearRight = TooltipRect(x: 1410, y: 800, width: 22, height: 22)
        let rightOrigin = HoverTooltipLogic.origin(
            anchor: nearRight,
            tooltipSize: TooltipSize(width: 140, height: 24),
            visibleFrame: screen
        )
        #expect(rightOrigin.x == 1440 - 6 - 140)
    }

    @Test("flips above anchor when too close to bottom of visible frame")
    func flipsAboveAnchorNearBottom() {
        let nearBottom = TooltipRect(x: 100, y: 12, width: 22, height: 22)
        let origin = HoverTooltipLogic.origin(
            anchor: nearBottom,
            tooltipSize: TooltipSize(width: 100, height: 24),
            visibleFrame: screen
        )
        #expect(origin.y == 12 + 22 + 6)
    }

    @Test("uses warm delay while visible or shortly after dismiss and cold delay otherwise")
    func hoverDelayPolicy() {
        #expect(HoverTooltipLogic.delayMs(isCurrentlyVisible: false, elapsedSinceDismissMs: nil) == HoverTooltipLogic.coldDelayMs)
        #expect(HoverTooltipLogic.delayMs(isCurrentlyVisible: true, elapsedSinceDismissMs: nil) == HoverTooltipLogic.warmDelayMs)
        #expect(HoverTooltipLogic.delayMs(isCurrentlyVisible: false, elapsedSinceDismissMs: 120) == HoverTooltipLogic.warmDelayMs)
        #expect(HoverTooltipLogic.delayMs(isCurrentlyVisible: false, elapsedSinceDismissMs: HoverTooltipLogic.warmWindowMs + 1) == HoverTooltipLogic.coldDelayMs)
    }

    @Test("places leading tooltips to the left of right-rail anchors and flips near left screen edge")
    func leadingPlacementForRightRail() {
        let railButton = TooltipRect(x: 1400, y: 500, width: 32, height: 32)
        let origin = HoverTooltipLogic.origin(
            anchor: railButton,
            tooltipSize: TooltipSize(width: 110, height: 24),
            visibleFrame: screen,
            gap: 8,
            placement: .leading
        )
        #expect(origin == TooltipPoint(x: 1282, y: 504))

        // Near left screen edge flips to trailing side and clamps vertically.
        let nearLeft = TooltipRect(x: 4, y: 2, width: 32, height: 32)
        let flipped = HoverTooltipLogic.origin(
            anchor: nearLeft,
            tooltipSize: TooltipSize(width: 110, height: 24),
            visibleFrame: screen,
            gap: 8,
            placement: .leading
        )
        #expect(flipped.x == 44)
        #expect(flipped.y == 6)
    }
}
