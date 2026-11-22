import CoreGraphics
import CoreImage
import Testing
@testable import VesperMatte

@Suite("VesperMatte unit tests")
struct VesperMatteTests {
    @Test("CLIOptions parses required and optional flags")
    func parseOptions() throws {
        let opts = try CLIOptions.parse([
            "--input", "/tmp/in.mp4",
            "--out-dir", "/tmp/frames",
            "--fps", "24",
            "--width", "360",
            "--height", "540",
            "--feather-bottom", "0.15",
            "--head-crop", "/tmp/head.png",
            "--head-crop-size", "256",
            "--chroma-despill", "0x3a3d40",
        ])
        #expect(opts.inputPath == "/tmp/in.mp4")
        #expect(opts.outDir == "/tmp/frames")
        #expect(opts.fps == 24.0)
        #expect(opts.width == 360)
        #expect(opts.height == 540)
        #expect(opts.featherBottom == 0.15)
        #expect(opts.headCropPath == "/tmp/head.png")
        #expect(opts.headCropSize == 256)
        #expect(opts.chromaDespill != nil)
        #expect(abs((opts.chromaDespill?.r ?? 0) - Float(0x3a) / 255.0) < 0.001)
    }

    @Test("CLIOptions rejects invalid feather-bottom and missing required flags")
    func rejectInvalidOptions() {
        #expect(throws: CLIError.self) {
            _ = try CLIOptions.parse(["--input", "/tmp/in.mp4"])
        }
        #expect(throws: CLIError.self) {
            _ = try CLIOptions.parse([
                "--input", "/tmp/in.mp4",
                "--out-dir", "/tmp/out",
                "--feather-bottom", "0.5",
            ])
        }
        #expect(throws: CLIError.self) {
            _ = try ChromaColor.parse("not-a-hex")
        }
    }

    @Test("Head crop falls back to upper-center square when no face is detected")
    func headCropFallback() {
        let rect = ImageProcessing.computeHeadCropRect(width: 320, height: 480, faceBoundingBox: nil)
        #expect(rect.width == 320)
        #expect(rect.height == 320)
        #expect(rect.origin.x == 0)
        // CoreImage bottom-left origin: top of 480-tall image starts at y = 160.
        #expect(rect.origin.y == 160)
    }

    @Test("Head crop centers around detected face and stays within bounds")
    func headCropWithFace() {
        let face = CGRect(x: 0.35, y: 0.65, width: 0.3, height: 0.2)
        let rect = ImageProcessing.computeHeadCropRect(width: 320, height: 480, faceBoundingBox: face)
        #expect(rect.width == rect.height)
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= 320)
        #expect(rect.maxY <= 480)
    }

    @Test("Bottom feather fades bottom row to transparent while keeping top opaque")
    func bottomFeatherAlpha() throws {
        let solid = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 100))
        let feathered = ImageProcessing.applyBottomFeather(solid, fraction: 0.25, width: 64, height: 100)

        let ctx = CIContext()
        var pixels = [UInt8](repeating: 0, count: 64 * 100 * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.render(
            feathered,
            toBitmap: &pixels,
            rowBytes: 64 * 4,
            bounds: CGRect(x: 0, y: 0, width: 64, height: 100),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // CIContext.render writes top-down rows: row 0 is top (y=99), row 99 is bottom (y=0).
        let rowBytes = 64 * 4
        let midColOffset = 32 * 4 + 3
        let topAlpha = pixels[midColOffset]
        let bottomAlpha = pixels[99 * rowBytes + midColOffset]
        #expect(topAlpha == 255)
        #expect(bottomAlpha < 20)
    }

    @Test("Chroma despill reduces green spill on semi-transparent edge pixels")
    func chromaDespillGreen() {
        // 2x1 image: pixel 0 is semi-transparent green-fringed edge, pixel 1 is transparent.
        var rgba: [UInt8] = [
            100, 220, 100, 140,
            0, 255, 0, 0,
        ]
        ImageProcessing.applyChromaDespill(
            rgba: &rgba,
            width: 2,
            height: 1,
            chroma: ChromaColor(r: 0, g: 1, b: 0)
        )
        // Green channel should be strongly suppressed toward max(r, b) on the edge pixel.
        #expect(rgba[1] < 160)
        // Fully transparent pixel RGB should be zeroed.
        #expect(rgba[4] == 0 && rgba[5] == 0 && rgba[6] == 0 && rgba[7] == 0)
    }
}
