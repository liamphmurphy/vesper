import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure CoreImage / pixel helpers shared by the matting pipeline and unit tests.
enum ImageProcessing {
    /// Scales `image` with aspect-fill (Lanczos) and center-crops to `(0, 0, width, height)`.
    static func aspectFillScaleAndCrop(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        // Normalize origin to (0, 0) before scaling.
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        let targetW = CGFloat(width)
        let targetH = CGFloat(height)
        let scale = max(targetW / extent.width, targetH / extent.height)

        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = normalized
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1.0
        let scaled = lanczos.outputImage ?? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let scaledW = extent.width * scale
        let scaledH = extent.height * scale
        let cropX = (scaledW - targetW) / 2.0
        let cropY = (scaledH - targetH) / 2.0
        let cropRect = CGRect(x: cropX, y: cropY, width: targetW, height: targetH)
        return scaled
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
    }

    /// Scales a single-channel Vision mask `CIImage` to match `(0, 0, width, height)`.
    static func scaleMask(_ mask: CIImage, width: Int, height: Int) -> CIImage {
        let extent = mask.extent
        guard extent.width > 0, extent.height > 0 else { return mask }
        let normalized = mask.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        let scaleX = CGFloat(width) / extent.width
        let scaleY = CGFloat(height) / extent.height
        return normalized
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Applies a soft alpha gradient along the bottom edge (`fraction` of total height)
    /// so 3/4-body framing fades cleanly to transparent at y = 0 (CoreImage bottom-left origin).
    static func applyBottomFeather(_ image: CIImage, fraction: Double, width: Int, height: Int) -> CIImage {
        guard fraction > 0 else { return image }
        let clamped = min(max(fraction, 0.0), 0.35)
        let featherHeight = CGFloat(height) * CGFloat(clamped)
        guard featherHeight >= 1.0 else { return image }

        // In CoreImage, y=0 is the bottom edge; y=featherHeight is where full opacity starts.
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        gradient.point1 = CGPoint(x: 0, y: featherHeight)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)

        guard let mask = gradient.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return image
        }

        // SourceIn keeps the image's RGB and multiplies its alpha by the gradient's alpha.
        let sourceIn = CIFilter.sourceInCompositing()
        sourceIn.inputImage = image
        sourceIn.backgroundImage = mask
        return sourceIn.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) ?? image
    }

    /// Computes a square crop rectangle in CoreImage bottom-left pixel coordinates.
    /// When `faceBoundingBox` (Vision normalized 0..1, bottom-left origin) is provided,
    /// centers horizontally on the face with headroom for hair and shoulders; otherwise
    /// falls back to an upper-center square crop.
    static func computeHeadCropRect(width: Int, height: Int, faceBoundingBox: CGRect?) -> CGRect {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let maxSide = min(w, h)

        guard let face = faceBoundingBox, face.width > 0, face.height > 0 else {
            // Upper-center square crop in CoreImage bottom-left coordinates.
            let x = floor((w - maxSide) / 2.0)
            let y = h - maxSide
            return CGRect(x: x, y: y, width: maxSide, height: maxSide)
        }

        let faceX = face.origin.x * w
        let faceY = face.origin.y * h
        let faceW = face.size.width * w
        let faceH = face.size.height * h
        let faceMidX = faceX + faceW * 0.5
        // Shift center slightly upward (in bottom-left coords, +Y is up) to include hair.
        let faceMidY = faceY + faceH * 0.58

        let desiredSide = max(faceW, faceH) * 2.15
        let side = min(maxSide, max(1, round(max(desiredSide, min(maxSide, max(faceW, faceH) * 1.4)))))

        let cropX = min(max(0, round(faceMidX - side * 0.5)), w - side)
        let cropY = min(max(0, round(faceMidY - side * 0.5)), h - side)

        return CGRect(x: cropX, y: cropY, width: side, height: side)
    }

    /// Performs subtle edge decontamination / spill suppression on straight-RGBA pixels
    /// (`width * height * 4` bytes, non-premultiplied RGBA8) against a known chroma backdrop.
    ///
    /// Semi-transparent boundary pixels (`0 < a < 255`) often carry blended backdrop color
    /// from camera/renderer anti-aliasing: `C_obs = a * C_fg + (1 - a) * C_bg`.
    /// This subtracts a conservative fraction of the estimated backdrop contribution and
    /// suppresses green/blue channel spill when the backdrop is strongly green or blue.
    static func applyChromaDespill(
        rgba: inout [UInt8],
        width: Int,
        height: Int,
        chroma: ChromaColor
    ) {
        let pixelCount = width * height
        guard rgba.count >= pixelCount * 4 else { return }

        let bgR = chroma.r
        let bgG = chroma.g
        let bgB = chroma.b
        let isGreenBackdrop = bgG > bgR + 0.15 && bgG > bgB + 0.15
        let isBlueBackdrop = bgB > bgR + 0.15 && bgB > bgG + 0.15

        for idx in 0..<pixelCount {
            let off = idx * 4
            let aByte = rgba[off + 3]
            if aByte == 0 {
                rgba[off] = 0
                rgba[off + 1] = 0
                rgba[off + 2] = 0
                continue
            }

            var r = Float(rgba[off]) / 255.0
            var g = Float(rgba[off + 1]) / 255.0
            var b = Float(rgba[off + 2]) / 255.0

            if aByte < 250 {
                let alpha = Float(aByte) / 255.0
                // Edge decontamination: remove estimated (1 - alpha) * bg contribution.
                // Limit boost factor so near-zero alpha noise does not explode.
                let invAlpha = min(1.0 / max(alpha, 0.12), 4.0)
                let bgWeight = (1.0 - alpha) * 0.75
                r = clamp01((r - bgWeight * bgR) * invAlpha * alpha + r * (1.0 - alpha))
                g = clamp01((g - bgWeight * bgG) * invAlpha * alpha + g * (1.0 - alpha))
                b = clamp01((b - bgWeight * bgB) * invAlpha * alpha + b * (1.0 - alpha))
            }

            // Classic green/blue spill suppression on semi-transparent edges and fringes.
            if isGreenBackdrop {
                let limit = max(r, b)
                if g > limit {
                    let spill = (g - limit) * (aByte < 245 ? 0.85 : 0.45)
                    g = clamp01(g - spill)
                }
            } else if isBlueBackdrop {
                let limit = max(r, g)
                if b > limit {
                    let spill = (b - limit) * (aByte < 245 ? 0.85 : 0.45)
                    b = clamp01(b - spill)
                }
            }

            rgba[off] = UInt8(clamp01(r) * 255.0 + 0.5)
            rgba[off + 1] = UInt8(clamp01(g) * 255.0 + 0.5)
            rgba[off + 2] = UInt8(clamp01(b) * 255.0 + 0.5)
        }
    }

    /// Renders a `CIImage` into a straight (non-premultiplied) RGBA8 byte buffer,
    /// applies optional chroma despill, and returns a `CGImage`.
    static func renderRGBA(
        _ image: CIImage,
        width: Int,
        height: Int,
        context: CIContext,
        chromaDespill: ChromaColor?
    ) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let chromaDespill else {
            guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
                throw CLIError.runtime("Failed to render RGBA CGImage")
            }
            return cg
        }

        let bytesPerRow = width * 4
        var premul = [UInt8](repeating: 0, count: bytesPerRow * height)
        context.render(
            image,
            toBitmap: &premul,
            rowBytes: bytesPerRow,
            bounds: rect,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        // CoreImage renders premultiplied RGBA8; unpremultiply before despill, then re-premultiply for CGImage.
        var straight = [UInt8](repeating: 0, count: premul.count)
        for i in stride(from: 0, to: premul.count, by: 4) {
            let a = premul[i + 3]
            straight[i + 3] = a
            if a == 255 {
                straight[i] = premul[i]
                straight[i + 1] = premul[i + 1]
                straight[i + 2] = premul[i + 2]
            } else if a > 0 {
                let scale = 255.0 / Float(a)
                straight[i] = UInt8(min(255.0, Float(premul[i]) * scale + 0.5))
                straight[i + 1] = UInt8(min(255.0, Float(premul[i + 1]) * scale + 0.5))
                straight[i + 2] = UInt8(min(255.0, Float(premul[i + 2]) * scale + 0.5))
            }
        }

        applyChromaDespill(rgba: &straight, width: width, height: height, chroma: chromaDespill)

        for i in stride(from: 0, to: straight.count, by: 4) {
            let a = Float(straight[i + 3]) / 255.0
            premul[i] = UInt8(Float(straight[i]) * a + 0.5)
            premul[i + 1] = UInt8(Float(straight[i + 1]) * a + 0.5)
            premul[i + 2] = UInt8(Float(straight[i + 2]) * a + 0.5)
            premul[i + 3] = straight[i + 3]
        }

        let data = Data(premul)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw CLIError.runtime("Failed to construct despill CGImage")
        }
        return cg
    }

    /// Writes `cgImage` as a PNG file to `url`.
    static func writePNG(_ cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.runtime("Failed to create PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CLIError.runtime("Failed to write PNG to \(url.path)")
        }
    }

    @inline(__always)
    private static func clamp01(_ v: Float) -> Float {
        min(max(v, 0.0), 1.0)
    }
}
