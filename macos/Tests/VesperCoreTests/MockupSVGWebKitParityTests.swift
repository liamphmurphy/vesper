import AppKit
import WebKit
import XCTest
@testable import VesperCore

/// The native renderer against WebKit: every conforming corpus file and render fixture is drawn
/// both ways at 2x on white and compared pixel by pixel. A person approves the native picture
/// while agents author against browsers, so the two must agree.
///
/// WebKit's side is an on-screen snapshot of the SVG in an <img> at 2x.
///
/// Needs a GUI session, like the other WebKit tests: `VESPER_WEBKIT_TESTS=1 swift test --filter
/// MockupSVGWebKitParityTests` (the macOS VM has one). Failing files write native, WebKit and diff
/// PNGs to `.build/mockup-parity/`.
@MainActor
final class MockupSVGWebKitParityTests: XCTestCase {
    private var window: NSWindow?
    private var view: WKWebView?

    /// Two engines antialias the same edge slightly differently; a real difference moves a
    /// channel much further than this.
    static let channelTolerance = 24

    /// The share of pixels allowed to differ. Shapes, gradients, masks and patterns match exactly
    /// at this tolerance (0.0–0.2% when last measured); text is drawn by CoreText in both engines,
    /// but rotated or mixed-font runs land on slightly different subpixel positions (0.34%).
    static let thresholds: [String: Double] = [
        "text-features.svg": 0.01,
    ]
    static let defaultThreshold = 0.005

    func testNativeMatchesWebKit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VESPER_WEBKIT_TESTS"] == "1", "set VESPER_WEBKIT_TESTS=1 to run")
        let files = try MockupSVGProfileTests.files("valid") + MockupSVGProfileTests.files("render")
        var report: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let doc = try MockupSVGDocument(source: source)
            let native = try XCTUnwrap(MockupSVGRenderer.makeImage(doc, scale: 2, options: .init(background: CGColor(gray: 1, alpha: 1))))
            let webkit = try await webKitImage(source, size: doc.intrinsicSize)
            let (fraction, diff) = Self.compare(native, webkit)
            let name = file.lastPathComponent
            // A negative control: both sides drew something, so agreement isn't two blank pages.
            let blank = try XCTUnwrap(Self.blank(width: native.width, height: native.height))
            XCTAssertGreaterThan(Self.compare(native, blank).0, 0.005, "\(name): native drew nothing")
            XCTAssertGreaterThan(Self.compare(webkit, blank).0, 0.005, "\(name): WebKit drew nothing")
            if ProcessInfo.processInfo.environment["VESPER_PARITY_WRITE"] == "1" { Self.write(native, webkit, diff, name: name) }
            let limit = Self.thresholds[name] ?? Self.defaultThreshold
            report.append(String(format: "%@ %.3f%% (limit %.1f%%)", name, fraction * 100, limit * 100))
            if fraction > limit {
                Self.write(native, webkit, diff, name: name)
                XCTFail(String(format: "%@: %.2f%% of pixels differ from WebKit (limit %.1f%%)", name, fraction * 100, limit * 100))
            }
        }
        print("mockup parity:\n" + report.joined(separator: "\n"))
    }

    // MARK: WebKit

    private func webKitImage(_ source: String, size: CGSize) async throws -> CGImage {
        let view = try page(size: size)
        let b64 = Data(source.utf8).base64EncodedString()
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:#fff}img{display:block}</style></head>
        <body><img id="m" width="\(size.width)" height="\(size.height)" src="data:image/svg+xml;base64,\(b64)"></body></html>
        """
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        _ = try await view.callAsyncJavaScript("await document.getElementById('m').decode(); return true", arguments: [:], in: nil, contentWorld: .page)
        withExtendedLifetime(delegate) {}
        // A snapshot is what the page shows; WebKit's PDF export flattens gradient alpha.
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.snapshotWidth = NSNumber(value: Double(size.width * 2))
        config.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: config)
        var rect = CGRect(origin: .zero, size: image.size)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    private func page(size: CGSize) throws -> WKWebView {
        _ = NSApplication.shared
        let frame = CGRect(origin: .zero, size: CGSize(width: max(size.width, 64), height: max(size.height, 64)))
        if let view, view.frame.size == frame.size { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: frame, configuration: config)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: frame.width, height: frame.height), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = v
        window = w
        view = v
        return v
    }

    // MARK: Pixels

    static func blank(width: Int, height: Int) -> CGImage? {
        guard let ctx = MockupSVGRenderer.bitmapContext(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buf
    }

    /// The share of pixels where any channel differs by more than the tolerance, and a diff image.
    static func compare(_ a: CGImage, _ b: CGImage) -> (Double, CGImage?) {
        let w = a.width, h = a.height
        let pa = pixels(a, width: w, height: h), pb = pixels(b, width: w, height: h)
        var diff = [UInt8](repeating: 255, count: w * h * 4)
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i + 1]) - Int(pb[i + 1])), abs(Int(pa[i + 2]) - Int(pb[i + 2])))
            if d > channelTolerance {
                differing += 1
                diff[i] = 255; diff[i + 1] = 0; diff[i + 2] = 0
            } else {
                let g = UInt8(200 + Int(pa[i + 1]) * 55 / 255)
                diff[i] = g; diff[i + 1] = g; diff[i + 2] = g
            }
        }
        let image = diff.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return (Double(differing) / Double(max(w * h, 1)), image)
    }

    static func write(_ native: CGImage, _ webkit: CGImage, _ diff: CGImage?, name: String) {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mockup-parity")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: ".svg", with: "")
        for (suffix, image) in [("native", native), ("webkit", webkit), ("diff", diff)] {
            guard let image else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(base)-\(suffix).png"))
        }
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
