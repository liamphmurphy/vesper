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
            // elkjs for offline node graph layout, built by scripts/build-elk-bundle.mjs (NodeGraph/ELKLayoutEngine.swift);
            // adblock starter filter lists for the internal browser's Wipr/uBO-style content blocker.
            resources: [.copy("Resources/shiki"), .copy("Resources/elk"), .copy("Resources/designs"), .copy("Resources/adblock")]
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
            dependencies: ["VesperCore", "SwiftTerm"],
            path: "Sources/Vesper"
        ),
        // The Dev workspace's terminal emulator, vendored from migueldeicaza/SwiftTerm
        // (Vendor/SwiftTerm/README.md) so the build fetches nothing. Swift 5 mode, as upstream builds it.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm/Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VesperCoreTests",
            dependencies: ["VesperCore"],
            path: "Tests/VesperCoreTests"
        ),
        .testTarget(
            name: "VesperTests",
            dependencies: ["Vesper", "VesperCore"],
            path: "Tests/VesperTests"
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
