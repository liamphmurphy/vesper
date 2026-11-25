import AppKit
import WebKit
import XCTest
@testable import VesperCore

/// Native persona characters against the WebKit page they replaced (`PersonaCharacterSanitizer
/// .renderHTML`, the sanitizer's CSS keyframes): every character, in every state, at several
/// moments of its loops, drawn both ways at 4x over white and compared pixel by pixel. The
/// animations have to look exactly as they did, so the WebKit page stays here as the reference.
///
/// WebKit's side pauses every CSS animation at `t` with the Web Animations API, so both sides draw
/// the same instant. Needs a GUI session: `VESPER_WEBKIT_TESTS=1 swift test --filter
/// PersonaCharacterWebKitParityTests` (the macOS VM has one). Failures write native, WebKit and
/// diff PNGs to `.build/mockup-parity/`.
@MainActor
final class PersonaCharacterWebKitParityTests: XCTestCase {
    private var window: NSWindow?
    private var view: WKWebView?

    static let scale = 4
    /// Antialiasing of a 64-unit drawing at 4x differs by a few edge pixels between engines; a
    /// wrong pose (a part shifted half a unit, a missed rotation, a hidden layer shown) moves
    /// hundreds.
    static let threshold = 0.012
    static let times: [TimeInterval] = [0, 0.31, 0.9, 1.45, 2.2, 3.05]

    static let characters: [(name: String, svg: String)] = [
        ("seeded", PersonaCharacterAnimatorTests.seededExample),
        // Motions on elements that also carry a transform attribute, and implicit 0%/100% stops
        // (breathe, float, tap, orbit, shadow): where CSS's underlying value matters.
        ("transformed", """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
          <ellipse data-motion="shadow" data-pivot="32 58" cx="32" cy="58" rx="14" ry="3" fill="#000" opacity="0.25"/>
          <g transform="translate(2 1)" data-motion-idle="breathe" data-motion-thinking="float" data-motion-coding="tap" data-pivot="32 36">
            <rect x="18" y="22" width="28" height="28" rx="8" fill="currentColor"/>
            <rect x="24" y="30" width="5" height="5" rx="1" fill="#111"/><rect x="35" y="30" width="5" height="5" rx="1" fill="#111"/>
          </g>
          <g transform="rotate(10 50 14)" data-motion="orbit" data-pivot="50 14" data-delay="-0.4">
            <circle cx="56" cy="14" r="2.5" fill="#f5b041"/>
          </g>
          <rect x="8" y="10" width="6" height="12" rx="2" fill="#5dade2" data-motion="pulse" data-speed="1.5" data-show="reading needs-you"/>
        </svg>
        """),
    ]

    func testNativeMatchesWebKit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VESPER_WEBKIT_TESTS"] == "1", "set VESPER_WEBKIT_TESTS=1 to run")
        var report: [String] = []
        var worst = 0.0
        let blank = try XCTUnwrap(MockupSVGWebKitParityTests.blank(width: 64 * Self.scale, height: 64 * Self.scale))
        for character in Self.characters {
            let rig = try XCTUnwrap(PersonaCharacterRig(svg: character.svg, color: "#d97757"), character.name)
            for state in CharacterState.allCases {
                let html = try XCTUnwrap(PersonaCharacterSanitizer.renderHTML(svg: character.svg, color: "#d97757", state: state))
                try await load(html)
                var firstNative: CGImage?, moved = false
                for t in Self.times {
                    let webkit = try await webKitFrame(at: t)
                    let native = try XCTUnwrap(Self.nativeFrame(rig, state: state, at: t))
                    // Negative controls: both sides drew the character, so agreement isn't two
                    // blank squares, and an animated state really moves between instants.
                    XCTAssertGreaterThan(MockupSVGWebKitParityTests.compare(native, blank).0, 0.02, "\(character.name) \(state) \(t): native drew nothing")
                    XCTAssertGreaterThan(MockupSVGWebKitParityTests.compare(webkit, blank).0, 0.02, "\(character.name) \(state) \(t): WebKit drew nothing")
                    if let first = firstNative { moved = moved || MockupSVGWebKitParityTests.compare(first, native).0 > 0 } else { firstNative = native }
                    let (fraction, diff) = MockupSVGWebKitParityTests.compare(native, webkit)
                    worst = max(worst, fraction)
                    let name = "persona-\(character.name)-\(state.rawValue)-\(t)"
                    report.append(String(format: "%@ %.3f%%", name, fraction * 100))
                    if fraction > Self.threshold || ProcessInfo.processInfo.environment["VESPER_PARITY_WRITE"] == "1" {
                        MockupSVGWebKitParityTests.write(native, webkit, diff, name: name)
                    }
                    if fraction > Self.threshold {
                        XCTFail(String(format: "%@: %.2f%% of pixels differ from WebKit (limit %.1f%%)", name, fraction * 100, Self.threshold * 100))
                    }
                }
                if rig.animates(in: state) { XCTAssertTrue(moved, "\(character.name) \(state): animated but every sampled frame is the same") }
            }
        }
        print(String(format: "persona parity (worst %.3f%%):\n", worst * 100) + report.joined(separator: "\n"))
    }

    // MARK: Native

    static func nativeFrame(_ rig: PersonaCharacterRig, state: CharacterState, at t: TimeInterval) -> CGImage? {
        let size = 64 * scale
        guard let ctx = MockupSVGRenderer.bitmapContext(width: size, height: size) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)
        rig.draw(state: state, at: t, in: ctx, rect: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    // MARK: WebKit

    private func load(_ html: String) async throws {
        let view = page()
        // requestAnimationFrame never fires in a window that's never on screen, so nothing here
        // waits for a frame; the snapshot's afterScreenUpdates does. The page's CSP allows no script; ours runs from the client world, which CSP doesn't
        // govern, and only reads and pauses the page's own CSS animations.
        let white = html.replacingOccurrences(of: "background: transparent;", with: "background: #fff;")
        let loaded = expectation(description: "loaded")
        let delegate = ParityLoadDelegate { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(white, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        withExtendedLifetime(delegate) {}
    }

    private func webKitFrame(at t: TimeInterval) async throws -> CGImage {
        let view = page()
        _ = try await view.callAsyncJavaScript(
            """
            for (const a of document.getAnimations()) { a.pause(); a.currentTime = ms; }
            return document.getAnimations().length
            """,
            arguments: ["ms": t * 1000], in: nil, contentWorld: .defaultClient
        )
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        config.snapshotWidth = NSNumber(value: 64 * Self.scale)
        config.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: config)
        var rect = CGRect(origin: .zero, size: image.size)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    private func page() -> WKWebView {
        if let view { return view }
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: config)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 64, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = v
        window = w
        view = v
        return v
    }
}

private final class ParityLoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
