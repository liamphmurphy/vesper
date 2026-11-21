// swift-tools-version: 6.0
// The native macOS shell for Vesper. See docs/dev/native-mac-app.md.
import PackageDescription

let package = Package(
    name: "Vesper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Vesper", targets: ["Vesper"]),
    ],
    targets: [
        // Logic with no AppKit UI, unit-tested.
        .target(
            name: "VesperCore",
            path: "Sources/VesperCore"
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
    ]
)
