import CoreGraphics
import Foundation
import Testing
@testable import VesperCore

struct CanvasScrollLogicTests {
    @Test func commandScrollZoomsAroundPointer() {
        let zoomIn = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: 40,
            hasPreciseDeltas: true,
            command: true,
            locationX: 320,
            locationY: 180
        ))
        guard case .zoom(let factorIn, let ax, let ay) = zoomIn else {
            Issue.record("Expected zoom action, got \(zoomIn)")
            return
        }
        #expect(factorIn > 1.0)
        #expect(ax == 320)
        #expect(ay == 180)

        let zoomOut = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: -40,
            hasPreciseDeltas: true,
            command: true,
            locationX: 100,
            locationY: 200
        ))
        guard case .zoom(let factorOut, _, _) = zoomOut else {
            Issue.record("Expected zoom action, got \(zoomOut)")
            return
        }
        #expect(factorOut < 1.0)
        #expect(abs(factorIn * factorOut - 1.0) < 1e-9)
    }

    @Test func controlScrollZoomsAndIgnoresMomentumTail() {
        let ctrlZoom = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: 2,
            hasPreciseDeltas: false,
            control: true,
            locationX: 50,
            locationY: 60
        ))
        guard case .zoom(let factor, let ax, let ay) = ctrlZoom else {
            Issue.record("Expected zoom action for Ctrl+wheel")
            return
        }
        #expect(factor > 1.1)
        #expect(ax == 50 && ay == 60)

        let momentum = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: 25,
            hasPreciseDeltas: true,
            isMomentum: true,
            command: true,
            locationX: 50,
            locationY: 60
        ))
        #expect(momentum == .ignore)
    }

    @Test func extremeZoomDeltaIsClamped() {
        let huge = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: 10_000,
            hasPreciseDeltas: true,
            command: true
        ))
        guard case .zoom(let factor, _, _) = huge else {
            Issue.record("Expected zoom action")
            return
        }
        #expect(abs(factor - exp(CanvasScrollLogic.maxExponentMagnitude)) < 1e-9)
    }

    @Test func plainScrollPansAndShiftScrollPansHorizontally() {
        let pan = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 12,
            deltaY: -8,
            hasPreciseDeltas: true
        ))
        #expect(pan == .pan(dx: 12, dy: -8))

        let shiftPan = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: -3,
            hasPreciseDeltas: false,
            shift: true
        ))
        #expect(shiftPan == .pan(dx: -48, dy: 0))

        let zero = CanvasScrollLogic.interpret(CanvasScrollInput(
            deltaX: 0,
            deltaY: 0,
            hasPreciseDeltas: true
        ))
        #expect(zero == .ignore)
    }

    @Test func designBackdropFallsBackToThemeSurfaceSunken() {
        #expect(CanvasBackdropLogic.resolveDesignBackdrop(pageBackgroundHex: nil) == .themeSurfaceSunken)
        #expect(CanvasBackdropLogic.resolveDesignBackdrop(pageBackgroundHex: "   ") == .themeSurfaceSunken)
        #expect(CanvasBackdropLogic.resolveDesignBackdrop(pageBackgroundHex: "#18181F") == .explicitHex("#18181F"))

        #expect(CanvasBackdropLogic.isHexDark("#110F19"))
        #expect(CanvasBackdropLogic.isHexDark("#000"))
        #expect(!CanvasBackdropLogic.isHexDark("#FFFFFF"))
        #expect(!CanvasBackdropLogic.isHexDark("#F6F5FA"))
    }

    @Test func designCameraZoomKeepsAnchorStationaryAndPansInScreenSpace() {
        let cam = DesignCamera(x: 100, y: 50, z: 1.5)
        let anchor = CGPoint(x: 420, y: 260)
        let worldBefore = cam.screenToWorld(anchor)

        let zoomed = cam.zoomed(by: 1.4, around: anchor)
        #expect(abs(zoomed.z - 2.1) < 1e-9)
        let screenAfter = zoomed.worldToScreen(worldBefore)
        #expect(abs(screenAfter.x - anchor.x) < 1e-6)
        #expect(abs(screenAfter.y - anchor.y) < 1e-6)

        // Clamping bounds
        #expect(cam.zoomed(by: 1000, around: anchor).z == DesignCamera.maxZoom)
        #expect(cam.zoomed(by: 0.0001, around: anchor).z == DesignCamera.minZoom)

        // Screen-space pan
        let panned = cam.panned(dx: 30, dy: -45)
        let ptBefore = cam.worldToScreen(CGPoint(x: 200, y: 120))
        let ptAfter = panned.worldToScreen(CGPoint(x: 200, y: 120))
        #expect(abs((ptAfter.x - ptBefore.x) - 30) < 1e-6)
        #expect(abs((ptAfter.y - ptBefore.y) - (-45)) < 1e-6)
    }

    @Test func knowledgeGraphViewportZoomAroundPointerKeepsWorldPointFixed() {
        let bounds = KnowledgeGraphBounds(x: -200, y: -100, width: 400, height: 200)
        let vp = KnowledgeGraphViewport(panX: 15, panY: -10, scale: 1.2)
        let anchorX = 640.0
        let anchorY = 180.0
        let beforeWorld = vp.screenToWorld(
            x: anchorX,
            y: anchorY,
            bounds: bounds,
            canvasWidth: 900,
            canvasHeight: 600
        )

        let zoomed = vp.zoomed(
            by: 1.5,
            aroundX: anchorX,
            aroundY: anchorY,
            bounds: bounds,
            canvasWidth: 900,
            canvasHeight: 600
        )
        let afterScreen = zoomed.worldToScreen(
            x: beforeWorld.x,
            y: beforeWorld.y,
            bounds: bounds,
            canvasWidth: 900,
            canvasHeight: 600
        )
        #expect(abs(afterScreen.x - anchorX) < 1e-6)
        #expect(abs(afterScreen.y - anchorY) < 1e-6)
        #expect(abs(zoomed.scale - 1.8) < 1e-9)
    }
}
