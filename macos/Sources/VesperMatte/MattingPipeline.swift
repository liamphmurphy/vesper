import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreML
import Foundation
import Metal
import Vision

struct MattingSummary: Codable, Sendable {
    let frames: Int
    let width: Int
    let height: Int
    let fps: Double
    let backend: String
    let headCropFaceDetected: Bool

    enum CodingKeys: String, CodingKey {
        case frames
        case width
        case height
        case fps
        case backend
        case headCropFaceDetected = "head_crop_face_detected"
    }
}

/// Decodes video frames with AVFoundation, produces soft 8-bit alpha mattes with Apple Vision
/// on Apple Silicon Neural Engine / GPU, composites via Metal-backed CoreImage, and writes
/// RGBA PNG frames plus an optional face-aware square head crop.
final class MattingPipeline {
    private let ciContext: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false,
            ])
        } else {
            self.ciContext = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false,
            ])
        }
    }

    func process(options: CLIOptions) async throws -> MattingSummary {
        let inputURL = URL(fileURLWithPath: options.inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.runtime("Input video not found: \(options.inputPath)")
        }

        let outDirURL = URL(fileURLWithPath: options.outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw CLIError.runtime("Input file has no video track: \(options.inputPath)")
        }
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw CLIError.runtime("Cannot attach AVAssetReaderTrackOutput for \(options.inputPath)")
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            let reason = reader.error?.localizedDescription ?? "unknown AVAssetReader error"
            throw CLIError.runtime("Failed to start reading video: \(reason)")
        }

        let frameInterval = 1.0 / options.fps
        var nextEmitTime: Double? = nil
        var frameIndex = 0
        var backendUsed = "vision_foreground"
        var headCropFaceDetected = false

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = pts.isValid && !pts.isIndefinite ? CMTimeGetSeconds(pts) : Double(frameIndex) * frameInterval

            if let target = nextEmitTime, seconds + 1e-4 < target {
                continue
            }
            if nextEmitTime == nil {
                nextEmitTime = seconds
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // Emit this frame (or repeat if source FPS is lower than target FPS).
            var rawImage = CIImage(cvPixelBuffer: pixelBuffer)
            if !preferredTransform.isIdentity {
                rawImage = rawImage.transformed(by: preferredTransform)
            }
            let scaledImage = ImageProcessing.aspectFillScaleAndCrop(
                rawImage,
                width: options.width,
                height: options.height
            )

            let (maskImage, frameBackend) = try generateMatte(for: scaledImage, width: options.width, height: options.height)
            if frameIndex == 0 {
                backendUsed = frameBackend
            }

            let composited = composite(
                foreground: scaledImage,
                mask: maskImage,
                width: options.width,
                height: options.height,
                featherBottom: options.featherBottom
            )

            let renderedCG = try ImageProcessing.renderRGBA(
                composited,
                width: options.width,
                height: options.height,
                context: ciContext,
                chromaDespill: options.chromaDespill
            )

            if frameIndex == 0, let headCropPath = options.headCropPath {
                headCropFaceDetected = try writeHeadCrop(
                    sourceImage: scaledImage,
                    mattedCG: renderedCG,
                    width: options.width,
                    height: options.height,
                    cropSize: options.headCropSize,
                    to: URL(fileURLWithPath: headCropPath)
                )
            }

            // Advance emit clock; if source frame covers multiple target intervals, emit once per interval.
            repeat {
                frameIndex += 1
                let filename = String(format: "frame_%05d.png", frameIndex)
                let frameURL = outDirURL.appendingPathComponent(filename)
                try ImageProcessing.writePNG(renderedCG, to: frameURL)
                nextEmitTime = (nextEmitTime ?? seconds) + frameInterval
            } while (nextEmitTime ?? 0) <= seconds + 1e-4
        }

        if reader.status == .failed {
            let reason = reader.error?.localizedDescription ?? "unknown AVAssetReader failure"
            throw CLIError.runtime("Video decoding failed: \(reason)")
        }
        guard frameIndex > 0 else {
            throw CLIError.runtime("No video frames decoded from \(options.inputPath)")
        }

        return MattingSummary(
            frames: frameIndex,
            width: options.width,
            height: options.height,
            fps: options.fps,
            backend: backendUsed,
            headCropFaceDetected: headCropFaceDetected
        )
    }

    /// Generates a soft 8-bit alpha matte using `VNGenerateForegroundInstanceMaskRequest`
    /// with fallback to `VNGeneratePersonSegmentationRequest` (`.accurate`).
    private func generateMatte(for image: CIImage, width: Int, height: Int) throws -> (CIImage, String) {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])

        // Primary: VNGenerateForegroundInstanceMaskRequest (macOS 14+, Apple Silicon ANE/GPU).
        do {
            let fgRequest = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([fgRequest])
            if let observation = fgRequest.results?.first, !observation.allInstances.isEmpty {
                let maskBuffer = try observation.generateScaledMaskForImage(
                    forInstances: observation.allInstances,
                    from: handler
                )
                let maskCI = ImageProcessing.scaleMask(CIImage(cvPixelBuffer: maskBuffer), width: width, height: height)
                return (maskCI, "vision_foreground")
            }
        } catch {
            // Fall through to person segmentation below (e.g. virtualized VM without ANE).
        }

        // Fallback: VNGeneratePersonSegmentationRequest (.accurate).
        if let personMask = try runPersonSegmentation(handler: handler, cpuOnly: false, width: width, height: height) {
            return (personMask, "vision_person")
        }
        if let personMaskCPU = try runPersonSegmentation(handler: handler, cpuOnly: true, width: width, height: height) {
            return (personMaskCPU, "vision_person_cpu")
        }

        throw CLIError.runtime("Vision matting produced no foreground or person mask")
    }

    private func runPersonSegmentation(
        handler: VNImageRequestHandler,
        cpuOnly: Bool,
        width: Int,
        height: Int
    ) throws -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if cpuOnly,
           let stageDevices = try? request.supportedComputeStageDevices,
           let devices = stageDevices[.main],
           let cpuDevice = devices.first(where: { device in
               if case .cpu = device { return true }
               return false
           })
        {
            request.setComputeDevice(cpuDevice, for: .main)
        }
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let maskCI = ImageProcessing.scaleMask(
                CIImage(cvPixelBuffer: observation.pixelBuffer),
                width: width,
                height: height
            )
            return maskCI
        } catch {
            if cpuOnly {
                throw CLIError.runtime("Vision person segmentation failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Applies the soft alpha mask to `foreground` over transparent background and optionally
    /// feathers the bottom edge.
    private func composite(
        foreground: CIImage,
        mask: CIImage,
        width: Int,
        height: Int,
        featherBottom: Double
    ) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = CIImage.clear.cropped(to: bounds)
        blend.maskImage = mask

        var result = blend.outputImage?.cropped(to: bounds) ?? foreground
        if featherBottom > 0 {
            result = ImageProcessing.applyBottomFeather(result, fraction: featherBottom, width: width, height: height)
        }
        return result
    }

    /// Detects the largest face on frame 0 using `VNDetectFaceRectanglesRequest`, crops the
    /// matted frame to a centered square around the head (or upper-center fallback), scales
    /// to `cropSize x cropSize`, and writes PNG.
    private func writeHeadCrop(
        sourceImage: CIImage,
        mattedCG: CGImage,
        width: Int,
        height: Int,
        cropSize: Int,
        to url: URL
    ) throws -> Bool {
        var faceBox: CGRect? = nil
        do {
            let handler = VNImageRequestHandler(ciImage: sourceImage, options: [:])
            let faceReq = VNDetectFaceRectanglesRequest()
            try handler.perform([faceReq])
            if let faces = faceReq.results, !faces.isEmpty {
                let largest = faces.max(by: {
                    ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
                })
                faceBox = largest?.boundingBox
            }
        } catch {
            // Fall back to upper-center crop if face detection fails.
            faceBox = nil
        }

        let cropRect = ImageProcessing.computeHeadCropRect(
            width: width,
            height: height,
            faceBoundingBox: faceBox
        )

        let mattedCI = CIImage(cgImage: mattedCG)
        let cropped = mattedCI
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        let resized = ImageProcessing.aspectFillScaleAndCrop(cropped, width: cropSize, height: cropSize)
        let cropCG = try ImageProcessing.renderRGBA(
            resized,
            width: cropSize,
            height: cropSize,
            context: ciContext,
            chromaDespill: nil
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ImageProcessing.writePNG(cropCG, to: url)
        return faceBox != nil
    }
}
