import Foundation

/// RGB color in 0...1 range used for optional chroma-edge decontamination.
struct ChromaColor: Equatable, Sendable {
    let r: Float
    let g: Float
    let b: Float

    /// Parses hex strings in `0xRRGGBB`, `#RRGGBB`, or `RRGGBB` format.
    static func parse(_ raw: String) throws -> ChromaColor {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        } else if hex.hasPrefix("#") {
            hex = String(hex.dropFirst(1))
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            throw CLIError.invalidArgument("Invalid hex color '\(raw)': expected 0xRRGGBB or #RRGGBB")
        }
        let r = Float((value >> 16) & 0xFF) / 255.0
        let g = Float((value >> 8) & 0xFF) / 255.0
        let b = Float(value & 0xFF) / 255.0
        return ChromaColor(r: r, g: g, b: b)
    }
}

struct CLIOptions: Equatable, Sendable {
    var inputPath: String = ""
    var outDir: String = ""
    var fps: Double = 20.0
    var width: Int = 320
    var height: Int = 480
    var featherBottom: Double = 0.0
    var headCropPath: String? = nil
    var headCropSize: Int = 256
    var chromaDespill: ChromaColor? = nil
    var showHelp: Bool = false

    static let usage = """
    Usage: vesper-matte --input <video.mp4> --out-dir <dir> [options]

    Apple Silicon Vision + CoreImage video matting CLI.

    Options:
      --input <path>            Input MP4 video file (required)
      --out-dir <path>          Output directory for RGBA PNG sequence (required)
      --fps <number>            Target frame rate (default: 20)
      --width <int>             Target width in pixels (default: 320)
      --height <int>            Target height in pixels (default: 480)
      --feather-bottom <float>  Bottom-edge alpha feather fraction 0..0.35 (default: 0)
      --head-crop <path>        Optional PNG output path for face-aware square head crop
      --head-crop-size <int>    Square head-crop dimension in pixels (default: 256)
      --chroma-despill <hex>    Optional backdrop hex color (e.g. 0x3a3d40) for edge decontamination
      -h, --help                Show this help message
    """

    static func parse(_ args: [String]) throws -> CLIOptions {
        var opts = CLIOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                opts.showHelp = true
                return opts
            case "--input":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgument("--input requires a path") }
                opts.inputPath = args[i]
            case "--out-dir":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgument("--out-dir requires a path") }
                opts.outDir = args[i]
            case "--fps":
                i += 1
                guard i < args.count, let v = Double(args[i]), v > 0, v <= 120 else {
                    throw CLIError.invalidArgument("--fps must be a number in (0, 120]")
                }
                opts.fps = v
            case "--width":
                i += 1
                guard i < args.count, let v = Int(args[i]), v > 0, v <= 4096 else {
                    throw CLIError.invalidArgument("--width must be an integer in [1, 4096]")
                }
                opts.width = v
            case "--height":
                i += 1
                guard i < args.count, let v = Int(args[i]), v > 0, v <= 4096 else {
                    throw CLIError.invalidArgument("--height must be an integer in [1, 4096]")
                }
                opts.height = v
            case "--feather-bottom":
                i += 1
                guard i < args.count, let v = Double(args[i]), v >= 0.0, v <= 0.35 else {
                    throw CLIError.invalidArgument("--feather-bottom must be a number in [0.0, 0.35]")
                }
                opts.featherBottom = v
            case "--head-crop":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgument("--head-crop requires a path") }
                let val = args[i].trimmingCharacters(in: .whitespacesAndNewlines)
                opts.headCropPath = val.isEmpty ? nil : val
            case "--head-crop-size":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 16, v <= 2048 else {
                    throw CLIError.invalidArgument("--head-crop-size must be an integer in [16, 2048]")
                }
                opts.headCropSize = v
            case "--chroma-despill":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgument("--chroma-despill requires a hex color") }
                let raw = args[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    opts.chromaDespill = try ChromaColor.parse(raw)
                }
            default:
                throw CLIError.invalidArgument("Unknown argument: \(arg)")
            }
            i += 1
        }

        if opts.inputPath.isEmpty {
            throw CLIError.invalidArgument("--input is required")
        }
        if opts.outDir.isEmpty {
            throw CLIError.invalidArgument("--out-dir is required")
        }
        return opts
    }
}

enum CLIError: Error, LocalizedError {
    case invalidArgument(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let msg): return msg
        case .runtime(let msg): return msg
        }
    }

    var exitCode: Int32 {
        switch self {
        case .invalidArgument: return 2
        case .runtime: return 1
        }
    }
}

@main
struct VesperMatteCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try CLIOptions.parse(args)
            if options.showHelp {
                print(CLIOptions.usage)
                Foundation.exit(0)
            }
            let pipeline = MattingPipeline()
            let summary = try await pipeline.process(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(summary)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
            Foundation.exit(0)
        } catch let err as CLIError {
            fputs("vesper-matte: \(err.localizedDescription)\n", stderr)
            if case .invalidArgument = err {
                fputs("\n\(CLIOptions.usage)\n", stderr)
            }
            Foundation.exit(err.exitCode)
        } catch {
            fputs("vesper-matte: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
