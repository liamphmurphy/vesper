import Foundation
import Testing
@testable import VesperCore

struct SlidesLogicTests {
    @Test func schemaRoundTripsAllElementTypesAndThemes() throws {
        var slide = SlideSchema.newSlide(layout: .titleBody)
        slide.elements.append(.shape(SlideShapeElement(
            id: "e_shape12345",
            frame: SlideFrame(x: 100, y: 100, w: 300, h: 200),
            shape: .star5,
            fill: .gradient(SlideGradient(angle: 135, stops: ["accent", "accent2"])),
            stroke: "heading",
            strokeWidth: 4,
            dash: .dash
        )))
        slide.elements.append(.line(SlideLineElement(
            id: "e_line123456",
            frame: SlideFrame(x: 50, y: 50, w: 400, h: 0),
            stroke: "accent",
            strokeWidth: 6,
            endArrow: true
        )))
        let deck = SlideDeck(slides: [slide])
        let json = try SlideSchema.encodeDeck(deck)
        let decoded = try SlideSchema.parseDeck(json)
        #expect(decoded == deck)
        #expect(SlideSchema.builtInThemes.count == 10)
    }

    @Test func all21PresetShapesProduceValidGeometryAndPaths() {
        let frame = SlideFrame(x: 100, y: 200, w: 400, h: 300)
        for kind in SlideShapeKind.allCases {
            let geom = SlideShapeGeometry.geometry(for: kind, in: frame)
            #expect(!geom.segs.isEmpty)
            #expect(geom.text.w > 0 && geom.text.h > 0)
            let path = SlideShapeGeometry.cgPath(from: geom.segs)
            #expect(!path.isEmpty)
            #expect(!SlideShapeGeometry.svgPath(from: geom.segs).isEmpty)
        }
    }

    @Test func layoutSlideWrapsTextAndDetectsOverflow() {
        let longText = Array(repeating: "presentation", count: 40).joined(separator: " ")
        let el = SlideElement.text(SlideTextElement(
            id: "e_overflow12",
            frame: SlideFrame(x: 0, y: 0, w: 200, h: 80),
            paragraphs: [SlideParagraph(runs: [SlideRun(text: longText, size: 48)])],
            valign: "top"
        ))
        let deck = SlideDeck(slides: [Slide(id: "s_1", layout: .blank, elements: [el])])
        let laid = SlideLayoutEngine.layoutSlide(deck: deck, slide: deck.slides[0])
        #expect(laid.overflow.contains("e_overflow12"))
        #expect(laid.ops.count > 2)
    }

    @Test func arrangeAlignDistributeSnapAndGroupWork() {
        let a = SlideElement.shape(SlideShapeElement(id: "e_a", frame: .init(x: 0, y: 0, w: 100, h: 100), shape: .rect))
        let b = SlideElement.shape(SlideShapeElement(id: "e_b", frame: .init(x: 500, y: 200, w: 100, h: 100), shape: .ellipse))
        let c = SlideElement.shape(SlideShapeElement(id: "e_c", frame: .init(x: 100, y: 0, w: 100, h: 100), shape: .diamond))

        let dist = SlideArrangeLogic.distribute(["e_a": a.frame, "e_c": c.frame, "e_b": b.frame], horizontal: true)
        #expect(dist["e_c"]?.x == 250)

        let grouped = SlideArrangeLogic.groupElements([a, b], ids: ["e_a", "e_b"])
        #expect(grouped != nil)
        #expect(grouped?.elements.count == 1)
        if let g = grouped {
            let ungrouped = SlideArrangeLogic.ungroupElements(g.elements, ids: [g.id])
            #expect(ungrouped.elements.count == 2)
            #expect(ungrouped.ids == ["e_a", "e_b"])
        }

        let snapped = SlideArrangeLogic.snapMove(box: SlideBox(l: 956, t: 0, r: 1056, b: 100), slideWidth: 1920, slideHeight: 1080, others: [])
        #expect(snapped.dx == 4) // snaps left edge to center 960
    }

    @Test func mergeDecksMergesDisjointSlideEditsAndDetectsConflicts() {
        let s1 = Slide(id: "s_1", layout: .blank, elements: [])
        let s2 = Slide(id: "s_2", layout: .blank, elements: [])
        let base = SlideDeck(slides: [s1, s2])

        var mine = base
        mine.slides[0].notes = "My note"
        var theirs = base
        theirs.slides[1].notes = "Persona note"

        let merged = SlideReviewLogic.mergeDecks(base: base, mine: mine, theirs: theirs)
        #expect(merged != nil)
        #expect(merged?.slides[0].notes == "My note")
        #expect(merged?.slides[1].notes == "Persona note")

        // Same slide edited differently -> conflict (nil)
        var theirsConflict = base
        theirsConflict.slides[0].notes = "Conflicting note"
        #expect(SlideReviewLogic.mergeDecks(base: base, mine: mine, theirs: theirsConflict) == nil)
    }

    @Test func pdfAndPptxExportersProduceValidFiles() {
        let deck = SlideDeck(slides: [SlideSchema.newSlide(layout: .title), SlideSchema.newSlide(layout: .twoColumn)])
        let pdf = SlideExporters.exportPDF(deck: deck, images: [:])
        #expect(pdf.count > 200)
        #expect(String(decoding: pdf.prefix(5), as: UTF8.self) == "%PDF-")

        let pptx = SlideExporters.exportPPTX(deck: deck, assetBytes: [:])
        #expect(pptx.count > 400)
        #expect(pptx[0] == 0x50 && pptx[1] == 0x4B && pptx[2] == 0x03 && pptx[3] == 0x04)
        let ascii = String(decoding: pptx, as: UTF8.self)
        #expect(ascii.contains("ppt/presentation.xml"))
        #expect(ascii.contains("ppt/slides/slide1.xml"))
        #expect(ascii.contains("ppt/slides/slide2.xml"))
    }

    @Test func slidesRoutesResolveToNativeScreens() {
        let reg = NativeRouteRegistry.standard(debug: false)
        let edit = reg.resolve("/apps/slides/01deck")
        #expect(edit?.screen == .slidesEditor)
        #expect(edit?.params["id"] == "01deck")

        let pres = reg.resolve("/present/slides/01deck?slide=3")
        #expect(pres?.screen == .slidesPresent)
        #expect(pres?.params["id"] == "01deck")
        #expect(pres?.query["slide"] == "3")
    }
}
