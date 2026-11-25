// swift-tools-version: 6.2
// The native macOS shell for Vesper. See docs/dev/native-mac-app.md.
import PackageDescription

let package = Package(
    name: "Vesper",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "VesperCore", targets: ["VesperCore"]),
        .executable(name: "Vesper", targets: ["Vesper"]),
        .executable(name: "vesper-matte", targets: ["VesperMatte"]),
    ],
    targets: [
        // Logic with no AppKit UI, unit-tested.
        .target(
            name: "VesperCore",
            dependencies: ["cmark-gfm", "cmark-gfm-extensions", "SwiftMath"],
            path: "Sources/VesperCore",
            // Shiki for code blocks, built by scripts/build-shiki-bundle.mjs (Markdown/CodeHighlighter.swift);
            // mermaid and KaTeX for chat embeds, built by scripts/build-embeds-bundle.mjs (ChatEmbeds/);
            // elkjs for offline node graph layout, built by scripts/build-elk-bundle.mjs (NodeGraph/ELKLayoutEngine.swift).
            resources: [.copy("Resources/shiki"), .copy("Resources/embeds"), .copy("Resources/elk"), .copy("Resources/designs")]
        ),
        // The markdown parser, vendored from swiftlang/swift-cmark (Vendor/cmark-gfm/README.md) so the
        // build fetches nothing.
        .target(
            name: "cmark-gfm",
            path: "Vendor/cmark-gfm/src"
        ),
        .target(
            name: "cmark-gfm-extensions",
            dependencies: ["cmark-gfm"],
            path: "Vendor/cmark-gfm/extensions"
        ),
        // TeX layout for chat math (ChatEmbeds/NativeMath.swift), vendored from mgriebling/SwiftMath
        // (Vendor/SwiftMath/README.md) so the build fetches nothing. Only the Latin Modern font ships.
        // Swift 5 mode, as upstream builds it.
        .target(
            name: "SwiftMath",
            path: "Vendor/SwiftMath/Sources",
            resources: [.copy("mathFonts.bundle")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app: AppKit windows, SwiftUI views, WKWebView.
        .executableTarget(
            name: "Vesper",
            dependencies: ["VesperCore", "VesperSafariBridge", "SwiftTerm"],
            path: "Sources/Vesper"
        ),
        // The Dev workspace's terminal emulator, vendored from migueldeicaza/SwiftTerm
        // (Vendor/SwiftTerm/README.md) so the build fetches nothing. Swift 5 mode, as upstream builds it.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Vesper for Safari's native half, shared by the app (writes the connection file) and the
        // extension (scripts/build-app.sh compiles it into PlugIns/VesperSafari.appex with
        // SafariExtension/Handler). Swift 5 mode: it passes [String: Any] messages through callbacks.
        .target(
            name: "VesperSafariBridge",
            path: "SafariExtension/Bridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VesperCoreTests",
            dependencies: ["VesperCore"],
            path: "Tests/VesperCoreTests"
        ),
        .testTarget(
            name: "VesperSafariBridgeTests",
            dependencies: ["VesperSafariBridge"],
            path: "SafariExtension/BridgeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Apple Silicon Vision + CoreImage video matting helper invoked by the Go server.
        .executableTarget(
            name: "VesperMatte",
            path: "Sources/VesperMatte"
        ),
        .testTarget(
            name: "VesperMatteTests",
            dependencies: ["VesperMatte"],
            path: "Tests/VesperMatteTests"
        ),
    ]
)
