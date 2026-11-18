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
            dependencies: ["VesperCore"],
            path: "Sources/Vesper"
        ),
        .testTarget(
            name: "VesperCoreTests",
            dependencies: ["VesperCore"],
            path: "Tests/VesperCoreTests"
        ),
    ]
)
