import Testing
@testable import VesperCore

@Suite("CitationBubblePlacement")
struct CitationBubblePlacementTests {
    private let screen = TooltipRect(x: 0, y: 0, width: 1440, height: 900)
    private let bubble = TooltipSize(width: 300, height: 132)

    @Test("places bubble above anchor by default with bottom-edge animation origin")
    func placesAboveByDefault() {
        let anchor = TooltipRect(x: 600, y: 400, width: 18, height: 16)
        let placement = CitationBubblePlacement.place(anchor: anchor, bubbleSize: bubble, visibleFrame: screen)

        #expect(placement.placedAbove)
        #expect(placement.origin.y == 424) // 400 + 16 + 8
        #expect(placement.origin.x == 459) // 609 - 150
        #expect(abs(placement.anchorUnitX - 0.5) < 0.01)
        #expect(placement.anchorUnitY == 1.0)
    }

    @Test("flips below anchor near the top of the screen with top-edge animation origin")
    func flipsBelowNearTopEdge() {
        let anchor = TooltipRect(x: 600, y: 840, width: 18, height: 16)
        let placement = CitationBubblePlacement.place(anchor: anchor, bubbleSize: bubble, visibleFrame: screen)

        #expect(!placement.placedAbove)
        #expect(placement.origin.y == 700) // 840 - 8 - 132
        #expect(placement.anchorUnitY == 0.0)
    }

    @Test("clamps horizontally inside visible frame and shifts animation origin toward badge")
    func clampsHorizontallyAndShiftsOrigin() {
        let anchor = TooltipRect(x: 24, y: 400, width: 16, height: 16)
        let placement = CitationBubblePlacement.place(anchor: anchor, bubbleSize: bubble, visibleFrame: screen)

        #expect(placement.origin.x == 10)
        #expect(placement.anchorUnitX >= 0.12)
        #expect(placement.anchorUnitX < 0.25)
    }

    @Test("resolves display title, destination label, and actionable destination for web and knowledge sources")
    func resolvesDisplayMetadata() {
        let web = ChatListedSource(title: "Swift Docs", url: "https://www.swift.org/documentation", number: 1)
        #expect(CitationBubblePlacement.displayTitle(source: web, previewTitle: nil) == "Swift Docs")
        #expect(CitationBubblePlacement.displayTitle(source: web, previewTitle: "The Swift Programming Language") == "The Swift Programming Language")
        #expect(CitationBubblePlacement.displayDestination(source: web, previewSite: nil) == "swift.org")
        #expect(CitationBubblePlacement.destination(source: web) == .external("https://www.swift.org/documentation"))

        let wiki = ChatListedSource(title: "", url: "", number: 2, ref: "Architecture/ADR 175")
        #expect(CitationBubblePlacement.displayTitle(source: wiki, previewTitle: nil) == "Architecture/ADR 175")
        #expect(CitationBubblePlacement.displayDestination(source: wiki, previewSite: nil) == "Architecture/ADR 175")
        #expect(CitationBubblePlacement.destination(source: wiki) == .knowledgePath("/wiki/Architecture/ADR%20175"))
    }
}
