import CoreGraphics
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

    @Test func reviewAndMergeTolerateDuplicateSlideAndElementIDs() {
        let dupElA = SlideElement.shape(SlideShapeElement(id: "e_dup", frame: .init(x: 0, y: 0, w: 100, h: 100), shape: .rect))
        let dupElB = SlideElement.shape(SlideShapeElement(id: "e_dup", frame: .init(x: 20, y: 20, w: 100, h: 100), shape: .ellipse))
        let s1 = Slide(id: "s_dup", layout: .blank, elements: [dupElA, dupElB])
        let s2 = Slide(id: "s_dup", layout: .blank, notes: "Second copy", elements: [dupElA])
        let base = SlideDeck(slides: [s1, s2])
        var head = base
        head.slides[1].notes = "Edited copy"

        let changes = SlideReviewLogic.deckChanges(base: base, head: head)
        #expect(!changes.isEmpty)

        var mine = base
        mine.slides.append(Slide(id: "s_new", layout: .blank, elements: []))
        var theirs = base
        theirs.slides.append(Slide(id: "s_other", layout: .blank, elements: []))
        let merged = SlideReviewLogic.mergeDecks(base: base, mine: mine, theirs: theirs)
        #expect(merged != nil)
        #expect(merged?.slides.contains(where: { $0.id == "s_new" }) == true)
        #expect(merged?.slides.contains(where: { $0.id == "s_other" }) == true)
        // Conflicting edit on duplicate slide ID reports conflict (nil) instead of trapping
        #expect(SlideReviewLogic.mergeDecks(base: base, mine: mine, theirs: head) == nil)
    }

    @Test func applyingPlainTextHandlesEmptyParagraphs() {
        let emptyBox = SlideTextBox(paragraphs: [], valign: "top")
        let next = SlideArrangeLogic.applyingPlainText("Line 1\nLine 2", to: emptyBox)
        #expect(next.count == 2)
        #expect(next[0].runs.first?.text == "Line 1")
        #expect(next[1].runs.first?.text == "Line 2")
    }

    @Test func imageSourceAndExportersHandleDegenerateGeometryWithoutTrapping() {
        let zeroFrameImg = SlideImageElement(id: "e_img", frame: SlideFrame(x: 0, y: 0, w: 0, h: 100), asset: "a1")
        let srcZero = SlideLayoutEngine.imageSource(for: zeroFrameImg, asset: SlideAsset(mime: "image/png", w: 800, h: 600))
        #expect(srcZero.x.isFinite && srcZero.y.isFinite && srcZero.w.isFinite && srcZero.h.isFinite)

        let zeroAsset = SlideLayoutEngine.imageSource(for: zeroFrameImg, asset: SlideAsset(mime: "image/png", w: 0, h: 0))
        #expect(zeroAsset == SlideFrame(x: 0, y: 0, w: 0, h: 0))

        // Rounded rect path with negative/zero/oversized/NaN radii must not abort CoreGraphics
        let negPath = SlideCGDrawer.safeRoundedRectPath(CGRect(x: 0, y: 0, width: -20, height: 10), cornerWidth: 50, cornerHeight: 50)
        #expect(!negPath.isEmpty)
        let nanPath = SlideCGDrawer.safeRoundedRectPath(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), cornerWidth: 5, cornerHeight: 5)
        #expect(nanPath.boundingBox == .zero)

        // Exporters tolerate degenerate shapes and non-finite coordinates without Int(NaN) or CG traps
        let weirdShape = SlideElement.shape(SlideShapeElement(
            id: "e_weird",
            frame: SlideFrame(x: 10, y: 10, w: -40, h: 0.0001),
            shape: .roundRect,
            fill: .solid("accent"),
            radius: 100
        ))
        let nanShape = SlideElement.shape(SlideShapeElement(
            id: "e_nan",
            frame: SlideFrame(x: .nan, y: .infinity, w: 100, h: 100),
            shape: .rect,
            fill: .solid("accent")
        ))
        let deck = SlideDeck(size: SlideDeckSize(w: 0, h: -10), slides: [Slide(id: "s_1", layout: .blank, elements: [weirdShape, nanShape])])
        let pdf = SlideExporters.exportPDF(deck: deck, images: [:])
        #expect(String(decoding: pdf.prefix(5), as: UTF8.self) == "%PDF-")
        let pptx = SlideExporters.exportPPTX(deck: deck, assetBytes: [:])
        #expect(pptx.count > 200)
    }
}
